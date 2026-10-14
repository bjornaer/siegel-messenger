// Command server is the Siegel Messenger API: Authentication Service,
// Directory and (later) Delivery Service in one stateless Go process.
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	_ "embed"
	"encoding/base64"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/bjornaer/siegel-messenger/server/gen/siegel/v1/siegelv1connect"
)

//go:embed schema.sql
var schema string

// config holds every value the spec marks [default]; each is overridable by env.
type config struct {
	dev           bool
	addr          string
	dbURL         string
	pepper        []byte             // ID-05. ponytail: env var, move to KMS/HSM (SEC-05)
	asKey         ed25519.PrivateKey // CRY-08. ponytail: env var, move to KMS/HSM (SEC-05)
	tlsCert       string
	tlsKey        string
	otpTTL        time.Duration
	otpAttempts   int
	otpPerNumber  int // per hour
	otpPerIP      int // per hour
	smsDailyCap   int
	denyPrefixes  []string
	userMin       int
	userMax       int
	userChangeDay int
	userQuarDay   int
	lockAttempts  int
	lockLockout   time.Duration
	lockLapseDay  int
}

func loadConfig() config {
	c := config{
		dev:           os.Getenv("SIEGEL_DEV") == "1",
		addr:          env("SIEGEL_ADDR", ":8080", ok),
		dbURL:         os.Getenv("SIEGEL_DATABASE_URL"),
		tlsCert:       os.Getenv("SIEGEL_TLS_CERT"),
		tlsKey:        os.Getenv("SIEGEL_TLS_KEY"),
		otpTTL:        env("SIEGEL_OTP_TTL", 10*time.Minute, time.ParseDuration),
		otpAttempts:   env("SIEGEL_OTP_ATTEMPTS", 5, strconv.Atoi),
		otpPerNumber:  env("SIEGEL_OTP_PER_NUMBER_HOUR", 3, strconv.Atoi),
		otpPerIP:      env("SIEGEL_OTP_PER_IP_HOUR", 10, strconv.Atoi),
		smsDailyCap:   env("SIEGEL_SMS_DAILY_CAP", 1000, strconv.Atoi),
		userMin:       env("SIEGEL_USERNAME_MIN", 4, strconv.Atoi),
		userMax:       env("SIEGEL_USERNAME_MAX", 32, strconv.Atoi),
		userChangeDay: env("SIEGEL_USERNAME_CHANGE_DAYS", 30, strconv.Atoi),
		userQuarDay:   env("SIEGEL_USERNAME_QUARANTINE_DAYS", 30, strconv.Atoi),
		lockAttempts:  env("SIEGEL_REGLOCK_ATTEMPTS", 10, strconv.Atoi),
		lockLockout:   env("SIEGEL_REGLOCK_LOCKOUT", 24*time.Hour, time.ParseDuration),
		lockLapseDay:  env("SIEGEL_REGLOCK_LAPSE_DAYS", 7, strconv.Atoi),
	}
	if p := os.Getenv("SIEGEL_DENY_PREFIXES"); p != "" {
		c.denyPrefixes = strings.Split(p, ",")
	}
	c.pepper = secret("SIEGEL_PHONE_PEPPER", c.dev)
	c.asKey = ed25519.NewKeyFromSeed(secret("SIEGEL_AS_SEED", c.dev))
	return c
}

func ok(s string) (string, error) { return s, nil }

func env[T any](key string, def T, parse func(string) (T, error)) T {
	s := os.Getenv(key)
	if s == "" {
		return def
	}
	v, err := parse(s)
	if err != nil {
		fatal("bad config value", "key", key)
	}
	return v
}

// secret reads a base64 32-byte secret; dev mode generates a throwaway one.
func secret(key string, dev bool) []byte {
	b, err := base64.StdEncoding.DecodeString(os.Getenv(key))
	if err == nil && len(b) == 32 {
		return b
	}
	if !dev {
		fatal("missing or invalid secret (base64, 32 bytes)", "key", key)
	}
	slog.Warn("dev: generated throwaway secret", "key", key)
	b = make([]byte, 32)
	rand.Read(b)
	return b
}

func fatal(msg string, args ...any) {
	slog.Error(msg, args...)
	os.Exit(1)
}

func main() {
	cfg := loadConfig()
	ctx := context.Background()
	db, err := pgxpool.New(ctx, cfg.dbURL)
	if err != nil {
		fatal("db", "err", err)
	}
	if _, err := db.Exec(ctx, schema); err != nil {
		fatal("schema", "err", err)
	}
	s := newServer(cfg, db)
	if cfg.dev {
		s.attest = func(context.Context, string) error { return nil }
		s.sendSMS = func(_ context.Context, _, code string) error {
			slog.Info("dev sms stub", "code", code) // never the number (SEC-03)
			return nil
		}
	} else {
		// ponytail: App Attest / Play Integrity and the SMS provider are not wired yet; refuse to run without them.
		fatal("attestation and SMS providers not implemented; set SIEGEL_DEV=1")
	}
	go s.janitor(ctx)

	srv := &http.Server{Addr: cfg.addr, Handler: s.routes(), ReadHeaderTimeout: 10 * time.Second}
	slog.Info("listening", "addr", cfg.addr)
	if cfg.tlsCert != "" {
		srv.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS13} // ARCH-02
		err = srv.ListenAndServeTLS(cfg.tlsCert, cfg.tlsKey)
	} else {
		srv.Protocols = new(http.Protocols)
		srv.Protocols.SetHTTP1(true)
		srv.Protocols.SetUnencryptedHTTP2(true)
		err = srv.ListenAndServe()
	}
	fatal("server stopped", "err", err)
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.Handle(siegelv1connect.NewRegistrationServiceHandler(s))
	mux.Handle(siegelv1connect.NewUsernameServiceHandler(s, s.authed()))
	mux.Handle(siegelv1connect.NewAccountServiceHandler(s, s.authed()))
	return mux
}

// janitor enforces the retention table in section 10.
func (s *server) janitor(ctx context.Context) {
	for {
		for _, q := range []string{
			`DELETE FROM otps WHERE expires_at < now()`,
			`DELETE FROM rate_limits WHERE window_start < now() - interval '24 hours'`,
			`DELETE FROM usernames WHERE quarantined_until < now() AND account_id IS NULL`,
		} {
			if _, err := s.db.Exec(ctx, q); err != nil {
				slog.Error("janitor", "err", err)
			}
		}
		time.Sleep(time.Hour)
	}
}
