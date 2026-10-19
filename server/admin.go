package main

import (
	"context"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/protobuf/encoding/protojson"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
)

// siegel-admin (M7 part 4): moderator actions from a shell on the server, never over the API:
//
//	docker compose exec server /server admin <command> [flags] <target>
//
// Targets are @usernames or 32-hex account IDs. Every action needs --reason and is audited.
const adminUsage = `usage: /server admin <command> [flags] <target>
  suspend --days N --rule R --reason "…" <account>
  unsuspend --reason "…" <account>
  ban [--days N] --rule R --reason "…" <account>       (no --days: for good)
  remove-username --rule R --reason "…" <name>
  remove-link --reason "…" <link id, hex>
  remove-blob --reason "…" <blob id, hex>
  signals <account>                                     (last 30 days)
  flags                                                 (usernames the scan flagged, open ones)
  scan-usernames                                        (run the scan now)
  audit [--verify] [--last N]
  console-enrol <operator name>                         (a single-use link to add a passkey)
lawful requests and appeals (docs/law-enforcement.md):
  export --order REF --reason "…" <account>             (prints what we hold, as JSON)
  preserve --order REF --reason "…" <account>           (keeps that snapshot 90 days)
  hold --days N --reason "…" <report id>                (a court asks to keep a report longer)
  request-log --kind K --outcome O --order REF --reason "…" <authority>
      kinds: production preservation emergency removal other; outcomes: answered nothing_held refused
  appeal --outcome upheld|overturned --reason "…" <account>
rules: spam harassment hate child_safety non_consensual violence impersonation other
every action also takes --by <operator> (default: $SIEGEL_OPERATOR or "operator")`

func adminMain(args []string, out io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(out, adminUsage)
		return 2
	}
	cfg := loadConfig()
	ctx := context.Background()
	db, err := pgxpool.New(ctx, cfg.dbURL)
	if err != nil {
		fmt.Fprintln(out, "db:", err)
		return 1
	}
	defer db.Close()
	s := newServer(cfg, db)
	s.blobs = cfg.s3
	if err := s.admin(ctx, args, out); err != nil {
		fmt.Fprintln(out, "error:", err)
		return 1
	}
	return 0
}

func (s *server) admin(ctx context.Context, args []string, out io.Writer) error {
	cmd, rest := args[0], args[1:]
	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fs.SetOutput(out)
	days := fs.Int("days", 0, "length in days")
	rule := fs.String("rule", "", "the guideline broken")
	reason := fs.String("reason", "", "why, in words the person will read")
	by := fs.String("by", envOr("SIEGEL_OPERATOR", "operator"), "who is acting")
	verify := fs.Bool("verify", false, "check the audit chain")
	last := fs.Int("last", 20, "audit rows to show")
	order := fs.String("order", "", "the order's reference")
	kind := fs.String("kind", "", "kind of request")
	outcome := fs.String("outcome", "", "what came of it")
	if err := fs.Parse(rest); err != nil {
		return err
	}
	target := fs.Arg(0)
	a := act{operator: *by, reason: strings.TrimSpace(*reason)}
	if *rule != "" {
		v, ok := siegelv1.ReportCategory_value["REPORT_CATEGORY_"+strings.ToUpper(*rule)]
		if !ok || v == 0 {
			return fmt.Errorf("unknown rule %q", *rule)
		}
		a.rule = siegelv1.ReportCategory(v)
	}
	needs := func(rule bool) error {
		if target == "" {
			return errors.New("no target")
		} else if a.reason == "" {
			return errNoReason
		} else if rule && a.rule == 0 {
			return errors.New("--rule is required")
		}
		return nil
	}
	switch cmd {
	case "suspend":
		if err := needs(true); err != nil {
			return err
		} else if *days <= 0 {
			return errors.New("--days is required")
		}
		acct, err := s.resolve(ctx, target)
		if err != nil {
			return err
		}
		until := time.Now().Add(time.Duration(*days) * 24 * time.Hour)
		if err := s.suspend(ctx, acct, until, a); err != nil {
			return err
		}
		fmt.Fprintf(out, "suspended %s until %s\n", target, until.UTC().Format(time.RFC3339))
	case "unsuspend":
		if err := needs(false); err != nil {
			return err
		}
		acct, err := s.resolve(ctx, target)
		if err != nil {
			return err
		}
		return s.unsuspend(ctx, acct, a)
	case "ban":
		if err := needs(true); err != nil {
			return err
		}
		acct, err := s.resolve(ctx, target)
		if err != nil {
			return err
		}
		var until *time.Time
		if *days > 0 {
			t := time.Now().Add(time.Duration(*days) * 24 * time.Hour)
			until = &t
		}
		if err := s.ban(ctx, acct, until, a); err != nil {
			return err
		}
		fmt.Fprintln(out, "banned", target)
	case "remove-username":
		if err := needs(true); err != nil {
			return err
		}
		return s.removeUsername(ctx, strings.TrimPrefix(strings.ToLower(target), "@"), a)
	case "remove-link", "remove-blob":
		if err := needs(false); err != nil {
			return err
		}
		id, err := hex.DecodeString(target)
		if err != nil {
			return errors.New("the ID is hex")
		}
		if cmd == "remove-link" {
			return s.removeLink(ctx, id, a)
		}
		return s.removeBlob(ctx, id, a)
	case "export", "preserve":
		if err := needs(false); err != nil {
			return err
		} else if *order == "" {
			return errors.New("--order is required")
		}
		acct, err := s.resolve(ctx, target)
		if err != nil {
			return err
		}
		data, err := s.exportData(ctx, acct, [16]byte{})
		if err != nil {
			return err
		}
		snapshot, err := protojson.Marshal(data)
		if err != nil {
			return err
		}
		if err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
			if cmd == "preserve" {
				if _, err := tx.Exec(ctx, `INSERT INTO preservations (account_id, order_ref, snapshot, expires_at) VALUES ($1, $2, $3, now() + interval '90 days')`,
					acct, *order, snapshot); err != nil {
					return err
				}
			}
			return audit(ctx, tx, a, cmd+" for "+*order, hex.EncodeToString(acct[:]))
		}); err != nil {
			return err
		}
		fmt.Fprintln(out, string(snapshot))
	case "hold":
		if err := needs(false); err != nil {
			return err
		} else if *days <= 0 {
			return errors.New("--days is required")
		}
		return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
			tag, err := tx.Exec(ctx, `UPDATE reports SET hold_until = now() + $2 * interval '1 day' WHERE id = $1`, target, *days)
			if err != nil {
				return err
			} else if tag.RowsAffected() == 0 {
				return errNotFound
			}
			return audit(ctx, tx, a, fmt.Sprintf("legal hold %d days", *days), "report "+target)
		})
	case "request-log":
		if err := needs(false); err != nil {
			return err
		}
		kinds := []string{"production", "preservation", "emergency", "removal", "other"}
		outcomes := []string{"answered", "nothing_held", "refused"}
		if !slices.Contains(kinds, *kind) || !slices.Contains(outcomes, *outcome) || *order == "" {
			return errors.New("--kind, --outcome and --order are required (see usage)")
		}
		return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
			return audit(ctx, tx, a, "legal request: "+*kind+":"+*outcome, target+" "+*order)
		})
	case "appeal":
		if err := needs(false); err != nil {
			return err
		} else if *outcome != "upheld" && *outcome != "overturned" {
			return errors.New("--outcome upheld|overturned")
		}
		return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
			return audit(ctx, tx, a, "appeal: "+*outcome, target)
		})
	case "console-enrol":
		link, err := s.enrolLink(ctx, target)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "Open within 30 minutes, through the SSH tunnel:\n%s\n", link)
	case "scan-usernames":
		n, err := s.scanUsernames(ctx)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "%d new\n", n)
	case "flags":
		rows, err := s.db.Query(ctx, `SELECT name, why, created_at FROM username_flags WHERE resolved_at IS NULL ORDER BY created_at`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var name, why string
			var at time.Time
			if err := rows.Scan(&name, &why, &at); err != nil {
				return err
			}
			fmt.Fprintf(out, "@%s  %s  (%s)\n", name, why, at.UTC().Format("2006-01-02"))
		}
		return rows.Err()
	case "signals":
		if target == "" {
			return errors.New("no target")
		}
		acct, err := s.resolve(ctx, target)
		if err != nil {
			return err
		}
		g, err := s.signals(ctx, acct)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "account since %s\nchats started %d\nnew-chat limit hit %d\nlookup limit hit %d\nreports %d (child safety %d)\n",
			g.CreatedDay, g.NewChats, g.NewChatLimit, g.LookupLimit, g.Reports, g.ChildSafetyReports)
	case "audit":
		if *verify {
			bad, err := s.auditVerify(ctx)
			if err != nil {
				return err
			} else if bad != 0 {
				return fmt.Errorf("audit chain broken at row %d", bad)
			}
			fmt.Fprintln(out, "audit chain intact")
		}
		rows, err := s.db.Query(ctx, `SELECT id, at, operator, action, target, reason FROM audit_log ORDER BY id DESC LIMIT $1`, *last)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var id int64
			var at time.Time
			var op, action, tgt, why string
			if err := rows.Scan(&id, &at, &op, &action, &tgt, &why); err != nil {
				return err
			}
			fmt.Fprintf(out, "%d  %s  %s  %s  %s  %q\n", id, at.UTC().Format(time.RFC3339), op, action, tgt, why)
		}
		return rows.Err()
	default:
		fmt.Fprintln(out, adminUsage)
		return fmt.Errorf("unknown command %q", cmd)
	}
	return nil
}

// resolve turns @username or a hex account ID into the account.
func (s *server) resolve(ctx context.Context, target string) ([16]byte, error) {
	var id [16]byte
	if name, ok := strings.CutPrefix(strings.ToLower(target), "@"); ok {
		err := s.db.QueryRow(ctx, `SELECT account_id FROM usernames WHERE name = $1 AND quarantined_until IS NULL`, name).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			return id, errNotFound
		}
		return id, err
	}
	b, err := hex.DecodeString(strings.ReplaceAll(target, "-", ""))
	if err != nil || len(b) != 16 {
		return id, errors.New("target: @username or a 32-hex account ID")
	}
	return [16]byte(b), nil
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
