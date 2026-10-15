// Command server is the Siegel Messenger API: Authentication Service,
// Directory and (later) Delivery Service in one stateless Go process.
package main

import (
	"context"
	"crypto/tls"
	_ "embed"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"connectrpc.com/connect"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/acme/autocert"

	"github.com/bjornaer/siegel-messenger/server/gen/siegel/v1/siegelv1connect"
)

//go:embed schema.sql
var schema string

// config holds every value the spec marks [default]; each is overridable by env.
type config struct {
	dev           bool   // stubs device attestation (and SMS when no provider token is set)
	domain        string // set: TLS 1.3 on :8443 with Let's Encrypt, ACME + redirect on :8080
	certDir       string
	dbURL         string
	baoAddr       string // OpenBao holds the phone pepper and AS signing key (SEC-05)
	baoToken      string
	smsToken      string // GatewayAPI
	smsURL        string
	smsSender     string
	otpTTL        time.Duration
	otpAttempts   int
	otpPerNumber  int // per hour
	otpPerIP      int // per hour
	verifyPerIP   int // per hour
	lookupPerDay  int // per account
	smsDailyCap   int
	denyPrefixes  []string
	userMin       int
	userMax       int
	userChangeDay int
	userQuarDay   int
	lockAttempts  int
	lockLockout   time.Duration
	lockLapseDay  int
	alertURL      string  // webhook for operator alerts (plain-text POST, e.g. an ntfy.sh topic)
	otpAlertRate  float64 // ID-04: alert below this OTP completion rate over 24 h
	otpAlertMin   int     // ...once at least this many OTPs were sent, to avoid noise
}

func loadConfig() config {
	c := config{
		dev:           os.Getenv("SIEGEL_DEV") == "1",
		domain:        os.Getenv("SIEGEL_DOMAIN"),
		certDir:       env("SIEGEL_CERT_DIR", "/certs", ok),
		dbURL:         os.Getenv("SIEGEL_DATABASE_URL"),
		baoAddr:       os.Getenv("SIEGEL_BAO_ADDR"),
		baoToken:      os.Getenv("SIEGEL_BAO_TOKEN"),
		smsToken:      os.Getenv("SIEGEL_GATEWAYAPI_TOKEN"),
		smsURL:        env("SIEGEL_GATEWAYAPI_URL", "https://messaging.gatewayapi.eu/mobile/single", ok),
		smsSender:     env("SIEGEL_SMS_SENDER", "Siegel", ok),
		otpTTL:        env("SIEGEL_OTP_TTL", 10*time.Minute, time.ParseDuration),
		otpAttempts:   env("SIEGEL_OTP_ATTEMPTS", 5, strconv.Atoi),
		otpPerNumber:  env("SIEGEL_OTP_PER_NUMBER_HOUR", 3, strconv.Atoi),
		otpPerIP:      env("SIEGEL_OTP_PER_IP_HOUR", 10, strconv.Atoi),
		verifyPerIP:   env("SIEGEL_VERIFY_PER_IP_HOUR", 30, strconv.Atoi),
		lookupPerDay:  env("SIEGEL_LOOKUP_PER_DAY", 200, strconv.Atoi),
		smsDailyCap:   env("SIEGEL_SMS_DAILY_CAP", 1000, strconv.Atoi),
		userMin:       env("SIEGEL_USERNAME_MIN", 4, strconv.Atoi),
		userMax:       env("SIEGEL_USERNAME_MAX", 32, strconv.Atoi),
		userChangeDay: env("SIEGEL_USERNAME_CHANGE_DAYS", 30, strconv.Atoi),
		userQuarDay:   env("SIEGEL_USERNAME_QUARANTINE_DAYS", 30, strconv.Atoi),
		lockAttempts:  env("SIEGEL_REGLOCK_ATTEMPTS", 10, strconv.Atoi),
		lockLockout:   env("SIEGEL_REGLOCK_LOCKOUT", 24*time.Hour, time.ParseDuration),
		lockLapseDay:  env("SIEGEL_REGLOCK_LAPSE_DAYS", 7, strconv.Atoi),
		alertURL:      os.Getenv("SIEGEL_ALERT_WEBHOOK"),
		otpAlertRate:  env("SIEGEL_OTP_ALERT_RATE", 0.5, func(s string) (float64, error) { return strconv.ParseFloat(s, 64) }),
		otpAlertMin:   env("SIEGEL_OTP_ALERT_MIN", 20, strconv.Atoi),
	}
	if p := os.Getenv("SIEGEL_DENY_PREFIXES"); p != "" {
		c.denyPrefixes = strings.Split(p, ",")
	}
	if c.baoAddr == "" || c.baoToken == "" {
		fatal("SIEGEL_BAO_ADDR and SIEGEL_BAO_TOKEN are required")
	}
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
	b := bao{addr: cfg.baoAddr, token: cfg.baoToken}
	s.hmacPhone, s.signAS = b.hmacPhone, b.signAS
	switch {
	case cfg.smsToken != "":
		s.sendSMS = gatewayAPI(cfg.smsURL, cfg.smsToken, cfg.smsSender)
	case cfg.dev:
		s.sendSMS = func(_ context.Context, _, code string) error {
			slog.Info("dev sms stub", "code", code) // never the number (SEC-03)
			return nil
		}
	default:
		fatal("SIEGEL_GATEWAYAPI_TOKEN required outside dev mode")
	}
	if !cfg.dev {
		// ponytail: App Attest / Play Integrity not wired yet; refuse to run without them.
		fatal("attestation not implemented; set SIEGEL_DEV=1")
	}
	s.attest = func(context.Context, string) error { return nil }
	go s.janitor(ctx, b)

	// ponytail: whole-request timeouts suit unary RPCs; the M2 WebSocket must manage its own deadlines.
	srv := &http.Server{
		Handler:           s.routes(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
	if cfg.domain == "" {
		srv.Addr = ":8080"
		srv.Protocols = new(http.Protocols)
		srv.Protocols.SetHTTP1(true)
		srv.Protocols.SetUnencryptedHTTP2(true)
		slog.Info("listening without TLS", "addr", srv.Addr)
		fatal("server stopped", "err", srv.ListenAndServe())
	}
	m := &autocert.Manager{
		Prompt:     autocert.AcceptTOS,
		HostPolicy: autocert.HostWhitelist(cfg.domain),
		Cache:      autocert.DirCache(cfg.certDir),
	}
	go func() { fatal("acme listener stopped", "err", http.ListenAndServe(":8080", m.HTTPHandler(nil))) }()
	srv.Addr = ":8443"
	srv.TLSConfig = m.TLSConfig()
	srv.TLSConfig.MinVersion = tls.VersionTLS13 // ARCH-02
	slog.Info("listening with TLS", "addr", srv.Addr, "domain", cfg.domain)
	fatal("server stopped", "err", srv.ListenAndServeTLS("", ""))
}

// routes is the whole public surface: registration is the only unauthenticated service.
func (s *server) routes() http.Handler {
	small := connect.WithReadMaxBytes(64 << 10) // identity messages are tiny
	mux := http.NewServeMux()
	mux.Handle(siegelv1connect.NewRegistrationServiceHandler(s, small))
	mux.Handle(siegelv1connect.NewUsernameServiceHandler(s, s.authed(), small))
	mux.Handle(siegelv1connect.NewAccountServiceHandler(s, s.authed(), small))
	return mux
}

// janitor enforces the retention table in section 10 and keeps the OpenBao token alive.
func (s *server) janitor(ctx context.Context, b bao) {
	for {
		for _, q := range []string{
			`DELETE FROM otps WHERE expires_at < now()`,
			`DELETE FROM rate_limits WHERE window_start < now() - interval '24 hours'`,
			`DELETE FROM usernames WHERE quarantined_until < now() AND account_id IS NULL`,
			`DELETE FROM metrics WHERE hour < now() - interval '30 days'`,
		} {
			if _, err := s.db.Exec(ctx, q); err != nil {
				slog.Error("janitor", "err", err)
			}
		}
		s.checkOtpRate(ctx)
		if err := b.renew(ctx); err != nil {
			slog.Warn("openbao token renew", "err", err) // expected for the non-expiring dev root token
		}
		time.Sleep(time.Hour)
	}
}
