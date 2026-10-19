// Command server is the Siegel Messenger API: Authentication Service,
// Directory and (later) Delivery Service in one stateless Go process.
package main

import (
	"context"
	"crypto/tls"
	_ "embed"
	"encoding/base64"
	"io"
	"log"
	"log/slog"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"connectrpc.com/connect"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/acme/autocert"

	"github.com/bjornaer/siegel-messenger/server/gen/siegel/v1/siegelv1connect"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
)

// config holds every value the spec marks [default]; each is overridable by env.
type config struct {
	dev           bool   // stubs device attestation (and SMS / push when their credentials are unset)
	domain        string // set: TLS 1.3 on :8443 with Let's Encrypt, ACME + redirect on :8080
	certDir       string
	dbURL         string
	baoAddr       string // OpenBao holds the phone pepper and AS signing key (SEC-05)
	baoToken      string
	smsToken      string // GatewayAPI
	smsURL        string
	smsSender     string
	sevenKey      string   // seven.io
	smsProviders  []string // order to try them in; only those with a key are used
	otpTTL        time.Duration
	otpAttempts   int
	otpPerNumber  int           // per hour
	otpPerDay     int           // per number per day: the hard cap on resends
	otpResendWait time.Duration // first resend wait; doubles each time
	otpPerIP      int           // per hour
	verifyPerIP   int           // per hour
	lookupPerDay  int           // per account
	claimPerDay   int           // KeyPackage claims per account
	sealedPerIP   int           // sealed-sender sends per IP per hour
	newChatPerDay int           // CMP-04: new conversations per account per day
	smsDailyCap   int
	denyPrefixes  []string
	userMin       int
	userMax       int
	userChangeDay int
	userQuarDay   int
	lockAttempts  int
	lockLockout   time.Duration
	lockLapseDay  int
	alertURL      string   // webhook for operator alerts (plain-text POST, e.g. an ntfy.sh topic)
	otpAlertRate  float64  // ID-04: alert below this OTP completion rate over 24 h
	otpAlertMin   int      // ...once at least this many OTPs were sent, to avoid noise
	fcmKey        []byte   // Google service account JSON: FCM push (SRV-05) and Play Integrity (ID-02)
	inactiveDays  int      // section 10: accounts with no device seen this long are deleted
	contactEmail  string   // shown on the public privacy and deletion pages
	reportsKey    string   // CMP-03: the moderators' age public key; empty = reporting off
	androidLatest int      // newest Android build in the Play Store (update banner)
	androidMin    int      // Android builds below this must update
	androidCerts  []string // SHA-256 of the app's signing certificates, for App Links
	operator      string   // legal name and postal address for the privacy policy
	reviewPhone   string   // app store review account: this number gets reviewCode, no SMS
	reviewCode    string
	s3            s3            // ARCH-06 attachment store
	blobLife      time.Duration // MED-13
	uploadsPerDay int           // per account
	discInitial   int           // DISC-06: OPRF evaluations per account per key period (first sync)
	discDaily     int           // DISC-06: then per day
	discPeriod    time.Duration // DISC-05: OPRF key rotation
	discBucketMin int           // DISC-05: smallest directory bucket
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
		sevenKey:      os.Getenv("SIEGEL_SEVEN_API_KEY"),
		smsProviders:  strings.Split(env("SIEGEL_SMS_PROVIDERS", "gatewayapi,seven", ok), ","),
		otpTTL:        env("SIEGEL_OTP_TTL", 10*time.Minute, time.ParseDuration),
		otpAttempts:   env("SIEGEL_OTP_ATTEMPTS", 5, strconv.Atoi),
		otpPerNumber:  env("SIEGEL_OTP_PER_NUMBER_HOUR", 3, strconv.Atoi),
		otpPerDay:     env("SIEGEL_OTP_PER_NUMBER_DAY", 5, strconv.Atoi),
		otpResendWait: env("SIEGEL_OTP_RESEND_WAIT", 30*time.Second, time.ParseDuration),
		otpPerIP:      env("SIEGEL_OTP_PER_IP_HOUR", 10, strconv.Atoi),
		verifyPerIP:   env("SIEGEL_VERIFY_PER_IP_HOUR", 30, strconv.Atoi),
		lookupPerDay:  env("SIEGEL_LOOKUP_PER_DAY", 1000, strconv.Atoi), // creating a 256-member group looks up 255
		claimPerDay:   env("SIEGEL_CLAIM_PER_DAY", 1000, strconv.Atoi),  // a 256-member group (GRP-01) needs 255
		sealedPerIP:   env("SIEGEL_SEALED_PER_IP_HOUR", 3000, strconv.Atoi),
		newChatPerDay: env("SIEGEL_NEW_CHATS_PER_DAY", 50, strconv.Atoi),
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
		inactiveDays:  env("SIEGEL_INACTIVE_DAYS", 180, strconv.Atoi),
		contactEmail:  os.Getenv("SIEGEL_CONTACT_EMAIL"),
		reportsKey:    os.Getenv("SIEGEL_REPORTS_AGE_RECIPIENT"),
		androidLatest: env("SIEGEL_ANDROID_LATEST_BUILD", 0, strconv.Atoi),
		androidMin:    env("SIEGEL_ANDROID_MIN_BUILD", 0, strconv.Atoi),
		androidCerts: strings.Split(env("SIEGEL_ANDROID_CERT_SHA256",
			"93:43:99:00:88:1C:CE:F0:BF:39:66:96:C5:E1:5C:BC:B0:90:DF:A1:7C:BA:6A:E9:AF:F2:24:C1:E8:34:3C:08", ok), ","),
		operator: os.Getenv("SIEGEL_OPERATOR"),
		s3: s3{
			endpoint: env("SIEGEL_S3_ENDPOINT", "http://s3:8333", ok),
			bucket:   env("SIEGEL_S3_BUCKET", "siegel-attachments", ok),
			region:   env("SIEGEL_S3_REGION", "us-east-1", ok),
			access:   os.Getenv("SIEGEL_S3_ACCESS_KEY"),
			secret:   os.Getenv("SIEGEL_S3_SECRET_KEY"),
		},
		blobLife:      time.Duration(env("SIEGEL_BLOB_DAYS", 30, strconv.Atoi)) * 24 * time.Hour,
		uploadsPerDay: env("SIEGEL_UPLOADS_PER_DAY", 1000, strconv.Atoi),
		discInitial:   env("SIEGEL_DISCOVERY_INITIAL", 5000, strconv.Atoi),
		discDaily:     env("SIEGEL_DISCOVERY_PER_DAY", 100, strconv.Atoi),
		discPeriod:    time.Duration(env("SIEGEL_DISCOVERY_KEY_DAYS", 90, strconv.Atoi)) * 24 * time.Hour,
		discBucketMin: env("SIEGEL_DISCOVERY_BUCKET_MIN", 256, strconv.Atoi),
	}
	if p := os.Getenv("SIEGEL_DENY_PREFIXES"); p != "" {
		c.denyPrefixes = strings.Split(p, ",")
	}
	if c.reviewPhone, c.reviewCode = os.Getenv("SIEGEL_REVIEW_PHONE"), os.Getenv("SIEGEL_REVIEW_CODE"); c.reviewPhone != "" && !regexp.MustCompile(`^\d{6}$`).MatchString(c.reviewCode) {
		fatal("SIEGEL_REVIEW_CODE must be 6 digits when SIEGEL_REVIEW_PHONE is set")
	}
	if k := os.Getenv("SIEGEL_FCM_CREDENTIALS"); k != "" {
		var err error
		if c.fcmKey, err = base64.StdEncoding.DecodeString(k); err != nil {
			fatal("SIEGEL_FCM_CREDENTIALS must be the service account JSON, base64-encoded")
		}
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
	if err := migrate(ctx, db); err != nil {
		fatal("migrate", "err", err)
	}
	s := newServer(cfg, db)
	b := bao{addr: cfg.baoAddr, token: cfg.baoToken}
	s.hmacPhone, s.signAS = b.hmacPhone, b.signAS
	s.fetchASPublic = b.asPublicKey
	s.disc.derive = b.hmac512
	go s.listen(ctx)
	var sms []smsProvider
	for _, name := range cfg.smsProviders {
		switch strings.TrimSpace(name) {
		case "gatewayapi":
			if cfg.smsToken != "" {
				sms = append(sms, smsProvider{"gatewayapi", gatewayAPI(cfg.smsURL, cfg.smsToken, cfg.smsSender)})
			}
		case "seven":
			if cfg.sevenKey != "" {
				sms = append(sms, smsProvider{"seven", seven(cfg.sevenKey, cfg.smsSender)})
			}
		default:
			fatal("unknown SMS provider in SIEGEL_SMS_PROVIDERS", "name", name)
		}
	}
	switch {
	case len(sms) > 0:
		s.sendSMS = smsChain(sms)
	case cfg.dev:
		s.sendSMS = func(_ context.Context, _, code string) error {
			slog.Info("dev sms stub", "code", code) // never the number (SEC-03)
			return nil
		}
	default:
		fatal("an SMS provider key is required outside dev mode (SIEGEL_GATEWAYAPI_TOKEN or SIEGEL_SEVEN_API_KEY)")
	}
	var google *googleAccount
	if cfg.fcmKey != nil {
		if google, err = googleAuth(cfg.fcmKey); err != nil {
			fatal("google credentials", "err", err)
		}
	}
	switch {
	case google != nil:
		s.sendPush = fcm(google)
	case cfg.dev:
		s.sendPush = func(context.Context, siegelv1.Platform, string) error {
			slog.Info("dev push stub") // never the token
			return nil
		}
	default:
		fatal("SIEGEL_FCM_CREDENTIALS required outside dev mode")
	}
	switch {
	case cfg.dev:
		s.attest = func(context.Context, siegelv1.Platform, string, string) error { return nil }
	case google != nil:
		s.attest = playIntegrity(google) // ID-02, same service account as push
	default:
		fatal("SIEGEL_FCM_CREDENTIALS required outside dev mode (push and attestation)")
	}
	// The store may still be starting (compose starts both together): give it a minute.
	for try := 0; ; try++ {
		err := cfg.s3.makeBucket(ctx)
		if err == nil {
			break
		} else if try == 30 {
			fatal("s3 bucket", "err", err)
		}
		time.Sleep(2 * time.Second)
	}
	s.blobs = cfg.s3
	go s.janitor(ctx, b)

	// ponytail: whole-request timeouts suit unary RPCs; the M2 WebSocket must manage its own deadlines.
	srv := &http.Server{
		Handler:           s.routes(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       2 * time.Minute,
		ErrorLog:          httpErrorLog,
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
	acme := &http.Server{Addr: ":8080", Handler: m.HTTPHandler(nil), ReadHeaderTimeout: 10 * time.Second, ErrorLog: httpErrorLog}
	go func() { fatal("acme listener stopped", "err", acme.ListenAndServe()) }()
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
	mux.Handle(siegelv1connect.NewProfileServiceHandler(profiles{s}, s.authed(), small))
	payload := connect.WithReadMaxBytes(256 << 10) // MLS messages: 64 KiB text (MSG-05) plus padding and overhead
	mux.Handle(siegelv1connect.NewKeysServiceHandler(s, s.authed(), payload))
	mux.Handle(siegelv1connect.NewMessagesServiceHandler(s, s.authed(), payload))
	// A welcome carries the whole member tree: about 270 KB for 256 members (GRP-01).
	// ponytail: every new member gets their own copy of it in the queue; fetch the tree once instead if adds get big.
	mux.Handle(siegelv1connect.NewGroupsServiceHandler(s, s.authed(), connect.WithReadMaxBytes(2<<20)))
	mux.Handle(siegelv1connect.NewInvitesServiceHandler(invites{s}, s.authed(), connect.WithReadMaxBytes(2<<20)))
	mux.Handle(siegelv1connect.NewAttachmentsServiceHandler(attachments{s}, s.authed(), small))
	mux.Handle(siegelv1connect.NewDiscoveryServiceHandler(discovery{s}, s.authed(), connect.WithReadMaxBytes(1<<20)))
	// Reports carry the chosen messages and their media, sealed: up to 32 MB.
	mux.Handle(siegelv1connect.NewReportServiceHandler(reports{s}, s.authed(), connect.WithReadMaxBytes(32<<20)))
	mux.HandleFunc("PUT /v1/blobs/{id}", s.putBlob)
	mux.HandleFunc("GET /v1/blobs/{id}", s.getBlob)
	mux.HandleFunc("GET /v1/stream", s.stream)
	mux.HandleFunc("GET /privacy", s.page("privacy"))
	mux.HandleFunc("GET /terms", s.page("terms"))
	mux.HandleFunc("GET /guidelines", s.page("guidelines"))
	mux.HandleFunc("GET /delete-account", s.page("delete-account"))
	mux.HandleFunc("GET /u/{username}", s.contactPage)
	mux.HandleFunc("GET /g/{id}", s.page("g")) // GRP-16: the server can't tell which group
	mux.HandleFunc("GET /.well-known/assetlinks.json", s.assetLinks)
	return mux
}

// janitor enforces the retention table in section 10 and keeps the OpenBao token alive.
func (s *server) janitor(ctx context.Context, b bao) {
	for {
		for _, q := range []string{
			`DELETE FROM otps WHERE expires_at < now()`,
			// DISC-06 keeps a per-key-period count; everything else is hourly or daily.
			`DELETE FROM rate_limits WHERE window_start < now() - interval '24 hours' AND key NOT LIKE 'disc_period:%'`,
			`DELETE FROM rate_limits WHERE window_start < now() - interval '200 days'`,
			`DELETE FROM usernames WHERE quarantined_until < now() AND account_id IS NULL`,
			`DELETE FROM metrics WHERE hour < now() - interval '30 days'`,
			`DELETE FROM queue WHERE enqueued_at < now() - interval '30 days'`, // MSG-06
			`DELETE FROM group_invites WHERE expires_at < now()`,               // GRP-16
			// MED-15: a deleted account's picture expires with it.
			`UPDATE attachments SET expires_at = now() WHERE expires_at = 'infinity'
				AND blob_id NOT IN (SELECT avatar_blob FROM profiles WHERE avatar_blob IS NOT NULL)`,
		} {
			if _, err := s.db.Exec(ctx, q); err != nil {
				slog.Error("janitor", "err", err)
			}
		}
		s.expireBlobs(ctx)
		s.checkOtpRate(ctx)
		s.expireInactive(ctx)
		if err := b.renew(ctx); err != nil {
			slog.Warn("openbao token renew", "err", err) // expected for the non-expiring dev root token
		}
		time.Sleep(time.Hour)
	}
}

// httpErrorLog is net/http's error log without client addresses: TLS handshake errors and
// panics name the remote IP, which must never reach logs (SEC-03).
var httpErrorLog = log.New(redactAddrs{os.Stderr}, "", log.LstdFlags)

var remoteAddr = regexp.MustCompile(`(from|serving) \S+:`)

type redactAddrs struct{ w io.Writer }

func (r redactAddrs) Write(p []byte) (int, error) {
	if _, err := r.w.Write(remoteAddr.ReplaceAll(p, []byte("$1 [ip]:"))); err != nil {
		return 0, err
	}
	return len(p), nil
}
