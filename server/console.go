package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io/fs"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/jackc/pgx/v5"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
)

// M7 part 5: the moderation console. A separate listener that compose publishes on the host's
// 127.0.0.1 only: operators reach it through an SSH tunnel (docs/deploy.md) and log in with a
// passkey. Reports are decrypted in the browser with the moderators' key, which the server never
// sees. Every action goes through the same functions as siegel-admin, so it's audited the same way.

//go:embed console/*.html
var consoleFiles embed.FS

//go:embed console/static
var consoleStatic embed.FS

var consolePages = template.Must(template.New("").Funcs(template.FuncMap{
	"category": categoryName,
	"short":    func(b []byte) string { return shortHex(b) },
	"day":      func(t time.Time) string { return t.UTC().Format("2006-01-02 15:04") },
}).ParseFS(consoleFiles, "console/*.html"))

const (
	consoleOrigin = "http://localhost:9443"
	sessionCookie = "siegel_console"
	sessionTTL    = 12 * time.Hour
	enrolmentTTL  = 30 * time.Minute
	rpID          = "localhost"
)

func categoryName(c int16) string {
	n := siegelv1.ReportCategory_name[int32(c)]
	return strings.ToLower(strings.TrimPrefix(n, "REPORT_CATEGORY_"))
}

func shortHex(b []byte) string {
	h := hex.EncodeToString(b)
	if len(h) > 12 {
		return h[:12]
	}
	return h
}

func hashToken(t string) []byte { h := sha256.Sum256([]byte(t)); return h[:] }

func randomToken() string {
	b := make([]byte, 32)
	rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

// operator is a console user for go-webauthn.
type operator struct {
	id    []byte
	name  string
	creds []webauthn.Credential
}

func (o *operator) WebAuthnID() []byte                         { return o.id }
func (o *operator) WebAuthnName() string                       { return o.name }
func (o *operator) WebAuthnDisplayName() string                { return o.name }
func (o *operator) WebAuthnCredentials() []webauthn.Credential { return o.creds }

type console struct {
	*server
	wa       *webauthn.WebAuthn
	mu       sync.Mutex
	pending  map[string]*webauthn.SessionData // ceremonies in progress, by a cookie
	enrolled map[string]*operator             // a registration's operator, by the same cookie
}

func newConsole(s *server) (*console, error) {
	wa, err := webauthn.New(&webauthn.Config{RPID: rpID, RPDisplayName: "Siegel moderation", RPOrigins: []string{consoleOrigin}})
	if err != nil {
		return nil, err
	}
	return &console{server: s, wa: wa, pending: map[string]*webauthn.SessionData{}, enrolled: map[string]*operator{}}, nil
}

// enrolLink is siegel-admin console-enrol: a single-use link to add a passkey for name.
func (s *server) enrolLink(ctx context.Context, name string) (string, error) {
	if name == "" {
		return "", errors.New("a name is required")
	}
	t := randomToken()
	_, err := s.db.Exec(ctx, `INSERT INTO console_enrolments (token_hash, name, expires_at) VALUES ($1, $2, $3)`,
		hashToken(t), name, time.Now().Add(enrolmentTTL))
	return consoleOrigin + "/enrol?t=" + t, err
}

func (c *console) routes() http.Handler {
	mux := http.NewServeMux()
	static, _ := fs.Sub(consoleStatic, "console")
	mux.Handle("GET /static/", http.FileServerFS(static))
	mux.HandleFunc("GET /enrol", c.page("enrol", false))
	mux.HandleFunc("POST /enrol/begin", c.enrolBegin)
	mux.HandleFunc("POST /enrol/finish", c.enrolFinish)
	mux.HandleFunc("GET /login", c.page("login", false))
	mux.HandleFunc("POST /login/begin", c.loginBegin)
	mux.HandleFunc("POST /login/finish", c.loginFinish)
	mux.HandleFunc("POST /logout", c.logout)
	mux.HandleFunc("GET /{$}", c.authed(c.queue))
	mux.HandleFunc("GET /report/{id}", c.authed(c.report))
	mux.HandleFunc("GET /account/{id}", c.authed(c.account))
	mux.HandleFunc("GET /audit", c.authed(c.auditPage))
	mux.HandleFunc("POST /action", c.authed(c.action))
	return c.headers(mux)
}

// headers: nothing loads from elsewhere, nothing frames us, and a POST must come from the page.
func (c *console) headers(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Security-Policy", "default-src 'self'; img-src 'self' blob: data:; media-src blob:; "+
			"style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Cache-Control", "no-store")
		if r.Method == http.MethodPost && r.Header.Get("Origin") != consoleOrigin {
			http.Error(w, "bad origin", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

type consoleData struct {
	Operator string
	Data     any
	Error    string
}

func (c *console) render(w http.ResponseWriter, name string, d consoleData) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := consolePages.ExecuteTemplate(w, name, d); err != nil {
		slog.Error("console page", "name", name, "err", err)
	}
}

func (c *console) page(name string, _ bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) { c.render(w, name, consoleData{}) }
}

// session returns the logged-in operator, or nil.
func (c *console) session(r *http.Request) *operator {
	ck, err := r.Cookie(sessionCookie)
	if err != nil {
		return nil
	}
	o := &operator{}
	err = c.db.QueryRow(r.Context(), `SELECT o.id, o.name FROM console_sessions s JOIN console_operators o ON o.id = s.operator_id
		WHERE s.token_hash = $1 AND s.expires_at > now()`, hashToken(ck.Value)).Scan(&o.id, &o.name)
	if err != nil {
		return nil
	}
	return o
}

func (c *console) authed(h func(http.ResponseWriter, *http.Request, *operator)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		o := c.session(r)
		if o == nil {
			http.Redirect(w, r, "/login", http.StatusSeeOther)
			return
		}
		h(w, r, o)
	}
}

func (c *console) startSession(w http.ResponseWriter, ctx context.Context, op []byte) error {
	t := randomToken()
	if _, err := c.db.Exec(ctx, `INSERT INTO console_sessions (token_hash, operator_id, expires_at) VALUES ($1, $2, $3)`,
		hashToken(t), op, time.Now().Add(sessionTTL)); err != nil {
		return err
	}
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: t, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode,
		MaxAge: int(sessionTTL.Seconds())})
	return nil
}

func (c *console) logout(w http.ResponseWriter, r *http.Request) {
	if ck, err := r.Cookie(sessionCookie); err == nil {
		c.db.Exec(r.Context(), `DELETE FROM console_sessions WHERE token_hash = $1`, hashToken(ck.Value))
	}
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Path: "/", MaxAge: -1})
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

// ceremony keeps WebAuthn session data between begin and finish, keyed by a short-lived cookie.
func (c *console) keep(w http.ResponseWriter, sd *webauthn.SessionData, o *operator) {
	k := randomToken()
	c.mu.Lock()
	c.pending[k] = sd
	if o != nil {
		c.enrolled[k] = o
	}
	c.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: "siegel_ceremony", Value: k, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode, MaxAge: 300})
}

func (c *console) take(r *http.Request) (*webauthn.SessionData, *operator) {
	ck, err := r.Cookie("siegel_ceremony")
	if err != nil {
		return nil, nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	sd, o := c.pending[ck.Value], c.enrolled[ck.Value]
	delete(c.pending, ck.Value)
	delete(c.enrolled, ck.Value)
	return sd, o
}

func (c *console) enrolBegin(w http.ResponseWriter, r *http.Request) {
	var name string
	err := c.db.QueryRow(r.Context(), `DELETE FROM console_enrolments WHERE token_hash = $1 AND expires_at > now() RETURNING name`,
		hashToken(r.URL.Query().Get("t"))).Scan(&name)
	if err != nil {
		http.Error(w, "this enrolment link is used up or expired", http.StatusForbidden)
		return
	}
	o := &operator{name: name}
	if err := c.db.QueryRow(r.Context(), `SELECT id FROM console_operators WHERE name = $1`, name).Scan(&o.id); errors.Is(err, pgx.ErrNoRows) {
		o.id = []byte(randomToken())[:32]
	} else if err != nil {
		http.Error(w, "internal", http.StatusInternalServerError)
		return
	}
	creation, sd, err := c.wa.BeginRegistration(o)
	if err != nil {
		http.Error(w, "internal", http.StatusInternalServerError)
		return
	}
	c.keep(w, sd, o)
	writeJSON(w, creation)
}

func (c *console) enrolFinish(w http.ResponseWriter, r *http.Request) {
	sd, o := c.take(r)
	if sd == nil || o == nil {
		http.Error(w, "start again", http.StatusBadRequest)
		return
	}
	cred, err := c.wa.FinishRegistration(o, *sd, r)
	if err != nil {
		http.Error(w, "the passkey wasn't accepted", http.StatusBadRequest)
		return
	}
	b, _ := json.Marshal(cred)
	if _, err := c.db.Exec(r.Context(), `INSERT INTO console_operators (id, name, credentials) VALUES ($1, $2, jsonb_build_array($3::jsonb))
		ON CONFLICT (name) DO UPDATE SET credentials = console_operators.credentials || jsonb_build_array($3::jsonb)`,
		o.id, o.name, string(b)); err != nil {
		http.Error(w, "internal", http.StatusInternalServerError)
		return
	}
	if err := c.startSession(w, r.Context(), o.id); err != nil {
		http.Error(w, "internal", http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]string{"ok": "enrolled"})
}

func (c *console) loadOperator(ctx context.Context, id []byte) (*operator, error) {
	o := &operator{id: id}
	var raw []byte
	if err := c.db.QueryRow(ctx, `SELECT name, credentials FROM console_operators WHERE id = $1`, id).Scan(&o.name, &raw); err != nil {
		return nil, err
	}
	return o, json.Unmarshal(raw, &o.creds)
}

func (c *console) loginBegin(w http.ResponseWriter, r *http.Request) {
	assertion, sd, err := c.wa.BeginDiscoverableLogin()
	if err != nil {
		http.Error(w, "internal", http.StatusInternalServerError)
		return
	}
	c.keep(w, sd, nil)
	writeJSON(w, assertion)
}

func (c *console) loginFinish(w http.ResponseWriter, r *http.Request) {
	sd, _ := c.take(r)
	if sd == nil {
		http.Error(w, "start again", http.StatusBadRequest)
		return
	}
	user, cred, err := c.wa.FinishPasskeyLogin(func(_, handle []byte) (webauthn.User, error) {
		return c.loadOperator(r.Context(), handle)
	}, *sd, r)
	if err != nil {
		http.Error(w, "not recognised", http.StatusForbidden)
		return
	}
	o := user.(*operator)
	for i := range o.creds { // keep the signature counter current (cloned-key detection)
		if string(o.creds[i].ID) == string(cred.ID) {
			o.creds[i].Authenticator.SignCount = cred.Authenticator.SignCount
		}
	}
	if b, err := json.Marshal(o.creds); err == nil {
		c.db.Exec(r.Context(), `UPDATE console_operators SET credentials = $2 WHERE id = $1`, o.id, string(b))
	}
	if err := c.startSession(w, r.Context(), o.id); err != nil {
		http.Error(w, "internal", http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]string{"ok": "logged in"})
}

type queueReport struct {
	ID       int64
	Category int16
	Reported []byte
	Created  time.Time
	Reports  int // open reports about the same account
}

type queueFlag struct {
	Name, Why string
	Account   []byte
	Created   time.Time
}

// queue is D1 order: child safety first, then threats, then everything else, oldest first.
func (c *console) queue(w http.ResponseWriter, r *http.Request, o *operator) {
	ctx := r.Context()
	rows, err := c.db.Query(ctx, `SELECT id, category, reported, created_at,
		(SELECT count(*) FROM reports x WHERE x.reported = r.reported AND x.resolved_at IS NULL)
		FROM reports r WHERE resolved_at IS NULL
		ORDER BY CASE category WHEN 4 THEN 0 WHEN 2 THEN 1 ELSE 2 END, created_at LIMIT 200`)
	if err != nil {
		c.render(w, "queue", consoleData{Operator: o.name, Error: err.Error()}) // the page shows it
		return
	}
	reports, _ := pgx.CollectRows(rows, func(row pgx.CollectableRow) (queueReport, error) {
		var q queueReport
		var reported *[16]byte
		err := row.Scan(&q.ID, &q.Category, &reported, &q.Created, &q.Reports)
		if reported != nil {
			q.Reported = reported[:]
		}
		return q, err
	})
	rows, err = c.db.Query(ctx, `SELECT name, why, account_id, created_at FROM username_flags WHERE resolved_at IS NULL ORDER BY created_at LIMIT 200`)
	var flags []queueFlag
	if err == nil {
		flags, _ = pgx.CollectRows(rows, func(row pgx.CollectableRow) (queueFlag, error) {
			var f queueFlag
			var acct *[16]byte
			err := row.Scan(&f.Name, &f.Why, &acct, &f.Created)
			if acct != nil {
				f.Account = acct[:]
			}
			return f, err
		})
	}
	c.render(w, "queue", consoleData{Operator: o.name, Data: map[string]any{"Reports": reports, "Flags": flags}, Error: r.URL.Query().Get("error")})
}

type reportPage struct {
	ID       int64
	Category int16
	Reported []byte
	Reporter []byte
	Created  time.Time
	Resolved *time.Time
	Outcome  string
	Sealed   string // base64, for the browser to decrypt
	Signals  *accountSignals
}

func (c *console) report(w http.ResponseWriter, r *http.Request, o *operator) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	var p reportPage
	var reported *[16]byte
	var reporter [16]byte
	var sealed []byte
	var outcome *string
	err := c.db.QueryRow(r.Context(), `SELECT id, category, reported, reporter, created_at, resolved_at, outcome, sealed FROM reports WHERE id = $1`, id).
		Scan(&p.ID, &p.Category, &reported, &reporter, &p.Created, &p.Resolved, &outcome, &sealed)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	p.Reporter, p.Sealed, p.Outcome = reporter[:], base64.StdEncoding.EncodeToString(sealed), derefS(outcome)
	if reported != nil {
		p.Reported = reported[:]
		if g, err := c.signals(r.Context(), *reported); err == nil {
			p.Signals = &g
		}
	}
	c.render(w, "report", consoleData{Operator: o.name, Data: p, Error: r.URL.Query().Get("error")})
}

type accountPage struct {
	ID        []byte
	Username  string
	Created   string
	Suspended *time.Time
	Minor     bool
	Exists    bool
	Signals   accountSignals
	Reports   []queueReport
}

func (c *console) account(w http.ResponseWriter, r *http.Request, o *operator) {
	b, err := hex.DecodeString(r.PathValue("id"))
	if err != nil || len(b) != 16 {
		http.NotFound(w, r)
		return
	}
	acct := [16]byte(b)
	p := accountPage{ID: b}
	var name *string
	if err := c.db.QueryRow(r.Context(), `SELECT created_day::text, suspended_until, minor,
		(SELECT name FROM usernames WHERE account_id = a.id AND quarantined_until IS NULL) FROM accounts a WHERE id = $1`, acct).
		Scan(&p.Created, &p.Suspended, &p.Minor, &name); err == nil {
		p.Exists, p.Username = true, derefS(name)
	}
	p.Signals, _ = c.signals(r.Context(), acct)
	if rows, err := c.db.Query(r.Context(), `SELECT id, category, created_at FROM reports WHERE reported = $1 ORDER BY id DESC LIMIT 50`, acct); err == nil {
		p.Reports, _ = pgx.CollectRows(rows, func(row pgx.CollectableRow) (queueReport, error) {
			var q queueReport
			return q, row.Scan(&q.ID, &q.Category, &q.Created)
		})
	}
	c.render(w, "account", consoleData{Operator: o.name, Data: p, Error: r.URL.Query().Get("error")})
}

type auditRow struct {
	ID                            int64
	At                            time.Time
	Operator, Action, Target, Why string
}

func (c *console) auditPage(w http.ResponseWriter, r *http.Request, o *operator) {
	bad, err := c.auditVerify(r.Context())
	rows, err2 := c.db.Query(r.Context(), `SELECT id, at, operator, action, target, reason FROM audit_log ORDER BY id DESC LIMIT 200`)
	var list []auditRow
	if err2 == nil {
		list, _ = pgx.CollectRows(rows, pgx.RowToStructByPos[auditRow])
	}
	status := "intact"
	if err != nil {
		status = "could not check: " + err.Error()
	} else if bad != 0 {
		status = fmt.Sprintf("BROKEN at row %d", bad)
	}
	c.render(w, "audit", consoleData{Operator: o.name, Data: map[string]any{"Rows": list, "Status": status}, Error: r.URL.Query().Get("error")})
}

// action runs one moderator action from a form, as this operator, then goes back.
func (c *console) action(w http.ResponseWriter, r *http.Request, o *operator) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	f := r.PostForm.Get
	a := act{operator: o.name, reason: strings.TrimSpace(f("reason"))}
	if v, ok := siegelv1.ReportCategory_value["REPORT_CATEGORY_"+strings.ToUpper(f("rule"))]; ok {
		a.rule = siegelv1.ReportCategory(v)
	}
	days, _ := strconv.Atoi(f("days"))
	ctx := r.Context()
	var err error
	acct := func() ([16]byte, error) { return c.resolve(ctx, f("target")) }
	switch f("kind") {
	case "suspend":
		var id [16]byte
		if id, err = acct(); err == nil {
			if days <= 0 {
				err = errors.New("how many days?")
			} else if a.rule == 0 {
				err = errors.New("which rule?")
			} else {
				err = c.suspend(ctx, id, time.Now().Add(time.Duration(days)*24*time.Hour), a)
			}
		}
	case "unsuspend":
		var id [16]byte
		if id, err = acct(); err == nil {
			err = c.unsuspend(ctx, id, a)
		}
	case "ban":
		var id [16]byte
		if id, err = acct(); err == nil {
			var until *time.Time
			if days > 0 {
				t := time.Now().Add(time.Duration(days) * 24 * time.Hour)
				until = &t
			}
			if a.rule == 0 {
				err = errors.New("which rule?")
			} else {
				err = c.ban(ctx, id, until, a)
			}
		}
	case "remove-username":
		if a.rule == 0 {
			err = errors.New("which rule?")
		} else {
			err = c.removeUsername(ctx, strings.TrimPrefix(strings.ToLower(f("target")), "@"), a)
		}
	case "remove-link", "remove-blob":
		var id []byte
		if id, err = hex.DecodeString(f("target")); err == nil {
			if f("kind") == "remove-link" {
				err = c.removeLink(ctx, id, a)
			} else {
				err = c.removeBlob(ctx, id, a)
			}
		}
	case "resolve-report":
		err = c.resolveReport(ctx, f("target"), f("outcome"), a)
	case "resolve-flag":
		err = c.resolveFlag(ctx, f("target"), f("outcome"), a)
	default:
		err = errors.New("unknown action")
	}
	back := f("back")
	if !strings.HasPrefix(back, "/") || strings.HasPrefix(back, "//") {
		back = "/"
	}
	if err != nil {
		http.Redirect(w, r, back+"?error="+template.URLQueryEscaper(err.Error()), http.StatusSeeOther)
		return
	}
	http.Redirect(w, r, back, http.StatusSeeOther)
}

// resolveReport closes a report with an outcome; the reporter's app is then told it was reviewed.
func (s *server) resolveReport(ctx context.Context, id, outcome string, a act) error {
	n, err := strconv.ParseInt(id, 10, 64)
	if err != nil || outcome == "" {
		return errors.New("which report, and what outcome?")
	}
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		var reporter [16]byte
		err := tx.QueryRow(ctx, `UPDATE reports SET resolved_at = now(), outcome = $2 WHERE id = $1 AND resolved_at IS NULL RETURNING reporter`,
			n, outcome).Scan(&reporter)
		if errors.Is(err, pgx.ErrNoRows) {
			return errNotFound
		} else if err != nil {
			return err
		}
		if err := audit(ctx, tx, a, "resolve report: "+outcome, "report "+id); err != nil {
			return err
		}
		return wakeAccount(ctx, tx, reporter)
	})
}

func (s *server) resolveFlag(ctx context.Context, name, outcome string, a act) error {
	if outcome == "" {
		return errors.New("what outcome?")
	}
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE username_flags SET resolved_at = now(), outcome = $2 WHERE name = $1 AND resolved_at IS NULL`,
			strings.TrimPrefix(name, "@"), outcome)
		if err != nil {
			return err
		} else if tag.RowsAffected() == 0 {
			return errNotFound
		}
		return audit(ctx, tx, a, "resolve username flag: "+outcome, "@"+strings.TrimPrefix(name, "@"))
	})
}
