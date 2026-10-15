package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"connectrpc.com/connect"
	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/argon2"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
	"github.com/bjornaer/siegel-messenger/server/gen/siegel/v1/siegelv1connect"
)

type callerKey struct{}

// caller is the authenticated account and device.
type caller struct{ account, device [16]byte }

// authenticate resolves an "Authorization: Bearer <token>" header and bumps the coarse
// last-seen day. found is false for a missing or unknown token.
func (s *server) authenticate(ctx context.Context, header string) (c caller, found bool, err error) {
	token, ok := strings.CutPrefix(header, "Bearer ")
	if !ok {
		return c, false, nil
	}
	h := sha256.Sum256([]byte(token))
	err = s.db.QueryRow(ctx, `UPDATE devices SET last_seen_day = current_date
		WHERE token_hash = $1 RETURNING account_id, device_id`, h[:]).Scan(&c.account, &c.device)
	if errors.Is(err, pgx.ErrNoRows) {
		return c, false, nil
	}
	return c, err == nil, err
}

// authed rejects calls without a valid device token.
func (s *server) authed() connect.Option {
	return connect.WithInterceptors(connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			if req.Spec().Procedure == siegelv1connect.MessagesServiceSendSealedProcedure {
				return next(ctx, req) // sealed sender: deliberately anonymous (MSG-10)
			}
			c, found, err := s.authenticate(ctx, req.Header().Get("Authorization"))
			if err != nil {
				return nil, internal(err)
			} else if !found {
				return nil, cerr(connect.CodeUnauthenticated, "unauthenticated")
			}
			return next(context.WithValue(ctx, callerKey{}, c), req)
		}
	}))
}

func who(ctx context.Context) caller       { return ctx.Value(callerKey{}).(caller) }
func account(ctx context.Context) [16]byte { return who(ctx).account }

// ponytail: tiny inline list; product owns the full reserved/offensive list (open question).
var reserved = map[string]bool{"admin": true, "root": true, "siegel": true, "support": true, "system": true, "help": true, "official": true, "security": true}

// validUsername implements ID-06: lowercase a-z, 0-9, '_' and '.', starting with a letter.
func (s *server) validUsername(name string) bool {
	if len(name) < s.cfg.userMin || len(name) > s.cfg.userMax || name[0] < 'a' || name[0] > 'z' || reserved[name] {
		return false
	}
	for _, c := range name {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '.') {
			return false
		}
	}
	return true
}

func (s *server) Set(ctx context.Context, req *connect.Request[siegelv1.UsernameServiceSetRequest]) (*connect.Response[siegelv1.UsernameServiceSetResponse], error) {
	name := strings.ToLower(req.Msg.Username)
	if !s.validUsername(name) {
		return nil, cerr(connect.CodeInvalidArgument, "username_invalid")
	}
	me := account(ctx)
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		var current string
		var recent bool
		err := tx.QueryRow(ctx, `SELECT name, claimed_day > current_date - $2::int FROM usernames
			WHERE account_id = $1 AND quarantined_until IS NULL FOR UPDATE`, me, s.cfg.userChangeDay).Scan(&current, &recent)
		switch {
		case err == nil && current == name:
			return nil
		case err == nil && recent:
			return cerr(connect.CodeFailedPrecondition, "username_change_too_soon") // ID-07
		case err == nil:
			if _, err := tx.Exec(ctx, `UPDATE usernames SET quarantined_until = now() + $2 * interval '1 day' WHERE name = $1`,
				current, s.cfg.userQuarDay); err != nil {
				return err
			}
		case !errors.Is(err, pgx.ErrNoRows):
			return err
		}
		// Free, or released and either out of quarantine or released by me.
		tag, err := tx.Exec(ctx, `INSERT INTO usernames (name, account_id) VALUES ($1, $2)
			ON CONFLICT (name) DO UPDATE SET account_id = $2, claimed_day = current_date, quarantined_until = NULL
			WHERE usernames.quarantined_until IS NOT NULL AND (usernames.quarantined_until < now() OR usernames.account_id = $2)`,
			name, me)
		if err == nil && tag.RowsAffected() == 0 {
			return cerr(connect.CodeAlreadyExists, "username_taken")
		}
		return err
	})
	if err != nil {
		if ce := new(connect.Error); errors.As(err, &ce) {
			return nil, ce
		}
		return nil, internal(err)
	}
	return connect.NewResponse(&siegelv1.UsernameServiceSetResponse{}), nil
}

func (s *server) Lookup(ctx context.Context, req *connect.Request[siegelv1.UsernameServiceLookupRequest]) (*connect.Response[siegelv1.UsernameServiceLookupResponse], error) {
	me := account(ctx)
	if ok, err := s.hit(ctx, fmt.Sprintf("lookup:%x", me), 24*time.Hour, s.cfg.lookupPerDay); err != nil {
		return nil, internal(err)
	} else if !ok {
		return nil, cerr(connect.CodeResourceExhausted, "rate_limited") // ID-08: slows dictionary scans
	}
	var id [16]byte
	res := &siegelv1.UsernameServiceLookupResponse{}
	err := s.db.QueryRow(ctx, `SELECT a.id, a.identity_pub, a.as_signature FROM usernames u JOIN accounts a ON a.id = u.account_id
		WHERE u.name = $1 AND u.quarantined_until IS NULL`, strings.ToLower(req.Msg.Username)).Scan(&id, &res.IdentityPub, &res.AsSignature)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, cerr(connect.CodeNotFound, "username_not_found")
	} else if err != nil {
		return nil, internal(err)
	}
	res.AccountId = id[:]
	return connect.NewResponse(res), nil
}

var fourDigits = regexp.MustCompile(`^[0-9]{4}$`)

// Argon2id per RFC 9106 second recommended option. ponytail: params pending a server benchmark (ID-10).
const argonTime, argonMem, argonThreads = 3, 64 * 1024, 4

func hashPin(pin string) string {
	salt := make([]byte, 16)
	rand.Read(salt)
	key := argon2.IDKey([]byte(pin), salt, argonTime, argonMem, argonThreads, 32)
	b := base64.RawStdEncoding
	return fmt.Sprintf("$argon2id$v=19$m=%d,t=%d,p=%d$%s$%s", argonMem, argonTime, argonThreads, b.EncodeToString(salt), b.EncodeToString(key))
}

func pinMatches(encoded, pin string) bool {
	var m, t uint32
	var p uint8
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 {
		return false
	}
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &m, &t, &p); err != nil {
		return false
	}
	salt, err1 := base64.RawStdEncoding.DecodeString(parts[4])
	want, err2 := base64.RawStdEncoding.DecodeString(parts[5])
	if err1 != nil || err2 != nil {
		return false
	}
	got := argon2.IDKey([]byte(pin), salt, t, m, p, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1
}

func (s *server) SetRegistrationLock(ctx context.Context, req *connect.Request[siegelv1.SetRegistrationLockRequest]) (*connect.Response[siegelv1.SetRegistrationLockResponse], error) {
	var hash *string
	if pin := req.Msg.Pin; pin != "" && !fourDigits.MatchString(pin) {
		return nil, cerr(connect.CodeInvalidArgument, "pin_invalid")
	} else if pin != "" {
		h := hashPin(req.Msg.Pin)
		hash = &h
	}
	if _, err := s.db.Exec(ctx, `UPDATE accounts SET reg_lock_hash = $2, reg_lock_attempts = 0, reg_lock_locked_until = NULL
		WHERE id = $1`, account(ctx), hash); err != nil {
		return nil, internal(err)
	}
	return connect.NewResponse(&siegelv1.SetRegistrationLockResponse{}), nil
}

// Delete removes the account synchronously, well inside the 24-hour bound of ID-16.
func (s *server) Delete(ctx context.Context, _ *connect.Request[siegelv1.AccountServiceDeleteRequest]) (*connect.Response[siegelv1.AccountServiceDeleteResponse], error) {
	me := account(ctx)
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE usernames SET quarantined_until = now() + $2 * interval '1 day'
			WHERE account_id = $1 AND quarantined_until IS NULL`, me, s.cfg.userQuarDay); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `DELETE FROM accounts WHERE id = $1`, me) // devices cascade; usernames.account_id -> NULL
		return err
	})
	if err != nil {
		return nil, internal(err)
	}
	return connect.NewResponse(&siegelv1.AccountServiceDeleteResponse{}), nil
}
