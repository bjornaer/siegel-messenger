package main

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
)

// M7 part 4: what moderators can do. Every action needs a reason, tells the account why
// (a statement of reasons, DSA Art. 17), and writes one audit row in the same transaction.

// act is who did it and why.
type act struct {
	operator string
	rule     siegelv1.ReportCategory
	reason   string
}

var errNoReason = errors.New("every action needs a reason")

// audit appends a row whose hash covers the previous row's, under a lock so the chain stays linear.
func audit(ctx context.Context, tx pgx.Tx, a act, action, target string) error {
	if a.reason == "" || a.operator == "" {
		return errNoReason
	}
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(7352)`); err != nil {
		return err
	}
	prev := make([]byte, sha256.Size)
	if err := tx.QueryRow(ctx, `SELECT hash FROM audit_log ORDER BY id DESC LIMIT 1`).Scan(&prev); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	at := time.Now().UTC().Truncate(time.Microsecond)
	if _, err := tx.Exec(ctx, `INSERT INTO audit_log (at, operator, action, target, reason, prev_hash, hash) VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		at, a.operator, action, target, a.reason, prev, auditHash(prev, at, a.operator, action, target, a.reason)); err != nil {
		return err
	}
	if item := tallyItem(action); item != "" {
		return tally(ctx, tx, item) // the transparency report counts it (M7 part 7)
	}
	return nil
}

// tallyItem is the transparency count an audited action adds to, if any.
func tallyItem(action string) string {
	for _, p := range []struct{ prefix, item string }{
		{"suspend", "action:suspend"}, {"ban", "action:ban"}, {"remove username", "action:remove_username"},
		{"remove link", "action:remove_link"}, {"remove blob", "action:remove_blob"},
		{"appeal: ", "appeal:"}, {"legal request: ", "request:"},
	} {
		if rest, ok := strings.CutPrefix(action, p.prefix); ok {
			if strings.HasSuffix(p.item, ":") {
				return p.item + strings.ReplaceAll(rest, " ", "_")
			}
			return p.item
		}
	}
	return ""
}

func auditHash(prev []byte, at time.Time, fields ...string) []byte {
	h := sha256.New()
	h.Write(prev)
	h.Write(binary.BigEndian.AppendUint64(nil, uint64(at.UnixMicro())))
	for _, f := range fields {
		h.Write(binary.BigEndian.AppendUint32(nil, uint32(len(f))))
		h.Write([]byte(f))
	}
	return h.Sum(nil)
}

// auditVerify walks the chain; it returns the first row that doesn't match, or 0.
func (s *server) auditVerify(ctx context.Context) (int64, error) {
	rows, err := s.db.Query(ctx, `SELECT id, at, operator, action, target, reason, prev_hash, hash FROM audit_log ORDER BY id`)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	prev := make([]byte, sha256.Size)
	for rows.Next() {
		var id int64
		var at time.Time
		var op, action, target, reason string
		var p, h []byte
		if err := rows.Scan(&id, &at, &op, &action, &target, &reason, &p, &h); err != nil {
			return 0, err
		}
		if string(p) != string(prev) || string(h) != string(auditHash(p, at.UTC(), op, action, target, reason)) {
			return id, nil
		}
		prev = h
	}
	return 0, rows.Err()
}

// wakeAccount makes the account's open streams look again, so they get the notice now.
func wakeAccount(ctx context.Context, tx pgx.Tx, acct [16]byte) error {
	_, err := tx.Exec(ctx, `SELECT pg_notify('queue', encode(uuid_send(device_id), 'hex')) FROM devices WHERE account_id = $1`, acct)
	return err
}

func (s *server) suspend(ctx context.Context, acct [16]byte, until time.Time, a act) error {
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE accounts SET suspended_until = $2, suspended_rule = $3, suspended_reason = $4 WHERE id = $1`,
			acct, until, int16(a.rule), a.reason)
		if err != nil {
			return err
		} else if tag.RowsAffected() == 0 {
			return errNotFound
		}
		if err := audit(ctx, tx, a, "suspend until "+until.UTC().Format(time.RFC3339), hex.EncodeToString(acct[:])); err != nil {
			return err
		}
		return wakeAccount(ctx, tx, acct)
	})
}

func (s *server) unsuspend(ctx context.Context, acct [16]byte, a act) error {
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE accounts SET suspended_until = NULL, suspended_rule = NULL, suspended_reason = NULL WHERE id = $1`, acct); err != nil {
			return err
		}
		return audit(ctx, tx, a, "unsuspend", hex.EncodeToString(acct[:]))
	})
}

// ban deletes the account, keeps its number from registering again (until a date, or for good
// when until is nil) and keeps its @username from anyone for good.
func (s *server) ban(ctx context.Context, acct [16]byte, until *time.Time, a act) error {
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		var phone []byte
		if err := tx.QueryRow(ctx, `SELECT phone_hmac FROM accounts WHERE id = $1`, acct).Scan(&phone); errors.Is(err, pgx.ErrNoRows) {
			return errNotFound
		} else if err != nil {
			return err
		}
		if phone != nil {
			if _, err := tx.Exec(ctx, `INSERT INTO banned_numbers (phone_hmac, until, rule, reason) VALUES ($1, $2, $3, $4)
				ON CONFLICT (phone_hmac) DO UPDATE SET until = $2, rule = $3, reason = $4`, phone, until, int16(a.rule), a.reason); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE usernames SET quarantined_until = 'infinity', account_id = NULL
			WHERE account_id = $1`, acct); err != nil {
			return err
		}
		if err := wakeAccount(ctx, tx, acct); err != nil { // their streams find the account gone
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM accounts WHERE id = $1`, acct); err != nil {
			return err
		}
		what := "ban"
		if until != nil {
			what += " until " + until.UTC().Format(time.RFC3339)
		}
		return audit(ctx, tx, a, what, hex.EncodeToString(acct[:]))
	})
}

// banned: may this number register? (RequestOtp, Verify, ChangeNumber)
func (s *server) banned(ctx context.Context, phoneHmac []byte) (bool, error) {
	var b bool
	err := s.db.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM banned_numbers WHERE phone_hmac = $1 AND (until IS NULL OR until > now()))`,
		phoneHmac).Scan(&b)
	return b, err
}

// removeUsername takes a name away for good; its account picks a new one at its next start.
func (s *server) removeUsername(ctx context.Context, name string, a act) error {
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		var acct *[16]byte
		err := tx.QueryRow(ctx, `SELECT account_id FROM usernames WHERE name = $1 AND quarantined_until IS NULL FOR UPDATE`, name).Scan(&acct)
		if errors.Is(err, pgx.ErrNoRows) {
			return errNotFound
		} else if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE usernames SET quarantined_until = 'infinity', account_id = NULL WHERE name = $1`, name); err != nil {
			return err
		}
		if acct != nil {
			if _, err := tx.Exec(ctx, `UPDATE accounts SET username_removed_rule = $2, username_removed_reason = $3 WHERE id = $1`,
				*acct, int16(a.rule), a.reason); err != nil {
				return err
			}
			if err := wakeAccount(ctx, tx, *acct); err != nil {
				return err
			}
		}
		return audit(ctx, tx, a, "remove username", "@"+name)
	})
}

// removeLink deletes a group invite link (GRP-16) by its ID.
func (s *server) removeLink(ctx context.Context, id []byte, a act) error {
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if tag, err := tx.Exec(ctx, `DELETE FROM group_invites WHERE id = $1`, id); err != nil {
			return err
		} else if tag.RowsAffected() == 0 {
			return errNotFound
		}
		return audit(ctx, tx, a, "remove link", hex.EncodeToString(id))
	})
}

// removeBlob deletes an attachment's encrypted blob (a removal order names it by ID).
func (s *server) removeBlob(ctx context.Context, id []byte, a act) error {
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if tag, err := tx.Exec(ctx, `DELETE FROM attachments WHERE blob_id = $1`, id); err != nil {
			return err
		} else if tag.RowsAffected() == 0 {
			return errNotFound
		}
		if err := audit(ctx, tx, a, "remove blob", hex.EncodeToString(id)); err != nil {
			return err
		}
		if s.blobs == nil {
			return nil
		}
		return s.blobs.del(ctx, hex.EncodeToString(id))
	})
}

var errNotFound = fmt.Errorf("not found")

// enforcement is the notice for an account's stream, if any applies now.
func (s *server) enforcement(ctx context.Context, acct [16]byte) (*siegelv1.Enforcement, error) {
	var until *time.Time
	var srule, urule *int16
	var sreason, ureason *string
	var hasName bool
	err := s.db.QueryRow(ctx, `SELECT suspended_until, suspended_rule, suspended_reason, username_removed_rule, username_removed_reason,
		EXISTS (SELECT 1 FROM usernames WHERE account_id = a.id AND quarantined_until IS NULL)
		FROM accounts a WHERE id = $1`, acct).Scan(&until, &srule, &sreason, &urule, &ureason, &hasName)
	if err != nil {
		return nil, err
	}
	if until != nil && until.After(time.Now()) {
		return &siegelv1.Enforcement{Kind: siegelv1.Enforcement_KIND_SUSPENDED, Rule: siegelv1.ReportCategory(deref(srule)),
			Reason: derefS(sreason), UntilMs: until.UnixMilli()}, nil
	}
	if urule != nil {
		if hasName { // they picked a new one: the notice is done
			_, err := s.db.Exec(ctx, `UPDATE accounts SET username_removed_rule = NULL, username_removed_reason = NULL WHERE id = $1`, acct)
			return nil, err
		}
		return &siegelv1.Enforcement{Kind: siegelv1.Enforcement_KIND_USERNAME_REMOVED, Rule: siegelv1.ReportCategory(*urule),
			Reason: derefS(ureason)}, nil
	}
	return nil, nil
}

func deref(p *int16) int16 {
	if p == nil {
		return 0
	}
	return *p
}

func derefS(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}
