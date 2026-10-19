package main

// Integration tests against a real PostgreSQL:
//   docker compose up -d postgres
//   SIEGEL_TEST_DATABASE_URL=postgres://postgres:siegel@localhost:55432/postgres go test ./...
// The tests DROP the public schema: never point this at a database holding real data.

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/jackc/pgx/v5/pgxpool"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
	"github.com/bjornaer/siegel-messenger/server/gen/siegel/v1/siegelv1connect"
)

type env_ struct {
	t     *testing.T
	s     *server
	sms   map[string]string
	reg   siegelv1connect.RegistrationServiceClient
	url   string
	ctx   context.Context
	asPub ed25519.PublicKey
}

func setup(t *testing.T) *env_ {
	dbURL := os.Getenv("SIEGEL_TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("SIEGEL_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	db, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	if _, err := db.Exec(ctx, "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"); err != nil {
		t.Fatal(err)
	}
	if err := migrate(ctx, db); err != nil {
		t.Fatal(err)
	}
	seed := make([]byte, 32)
	rand.Read(seed)
	asKey := ed25519.NewKeyFromSeed(seed)
	cfg := config{
		discInitial: 5, discDaily: 2, discPeriod: 90 * 24 * time.Hour, discBucketMin: 256,
		otpTTL: 600e9, otpAttempts: 5, otpPerNumber: 3, otpPerDay: 100, otpPerIP: 1000, verifyPerIP: 1000, lookupPerDay: 1000, claimPerDay: 1000, sealedPerIP: 1000, newChatPerDay: 1000, smsDailyCap: 1000,
		denyPrefixes: []string{"+882"},
		userMin:      4, userMax: 32, userChangeDay: 30, userQuarDay: 30,
		lockAttempts: 3, lockLockout: 3600e9, lockLapseDay: 7, inactiveDays: 180,
	}
	e := &env_{t: t, sms: map[string]string{}, ctx: ctx, asPub: asKey.Public().(ed25519.PublicKey)}
	e.s = newServer(cfg, db)
	e.s.attest = func(context.Context, siegelv1.Platform, string, string) error { return nil }
	e.s.hmacPhone = func(_ context.Context, p string) ([]byte, error) {
		m := hmac.New(sha256.New, seed)
		m.Write([]byte(p))
		return m.Sum(nil), nil
	}
	e.s.signAS = func(_ context.Context, msg []byte) ([]byte, error) { return ed25519.Sign(asKey, msg), nil }
	e.s.fetchASPublic = func(context.Context) ([]byte, error) { return e.asPub, nil }
	e.s.disc.derive = func(_ context.Context, label string) ([]byte, error) {
		h := sha512.Sum512(append(seed, label...))
		return h[:], nil
	}
	lctx, stop := context.WithCancel(ctx)
	t.Cleanup(stop)
	go e.s.listen(lctx)
	e.s.sendSMS = func(_ context.Context, phone, code string) error { e.sms[phone] = code; return nil }
	srv := httptest.NewServer(e.s.routes())
	t.Cleanup(srv.Close)
	e.url = srv.URL
	e.reg = siegelv1connect.NewRegistrationServiceClient(http.DefaultClient, srv.URL)
	return e
}

func errMsg(err error) string {
	if ce := new(connect.Error); err != nil && errors.As(err, &ce) {
		return ce.Message()
	}
	if err != nil {
		return err.Error()
	}
	return ""
}

func (e *env_) otp(phone string) error {
	_, err := e.reg.RequestOtp(e.ctx, connect.NewRequest(&siegelv1.RequestOtpRequest{PhoneE164: phone}))
	return err
}

func (e *env_) verify(phone, code, pin string) (*siegelv1.VerifyResponse, ed25519.PublicKey, error) {
	pub, _, _ := ed25519.GenerateKey(nil)
	res, err := e.reg.Verify(e.ctx, connect.NewRequest(&siegelv1.VerifyRequest{
		PhoneE164: phone, Otp: code, IdentityPub: pub, RegistrationLockPin: pin, Platform: siegelv1.Platform_PLATFORM_IOS}))
	if err != nil {
		return nil, nil, err
	}
	return res.Msg, pub, nil
}

// register runs RequestOtp + Verify and returns a bearer token.
func (e *env_) register(phone, pin string) (*siegelv1.VerifyResponse, error) {
	if err := e.otp(phone); err != nil {
		return nil, err
	}
	res, _, err := e.verify(phone, e.sms[phone], pin)
	return res, err
}

func (e *env_) clients(token string) (siegelv1connect.UsernameServiceClient, siegelv1connect.AccountServiceClient) {
	auth := connect.WithInterceptors(connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, r connect.AnyRequest) (connect.AnyResponse, error) {
			r.Header().Set("Authorization", "Bearer "+token)
			return next(ctx, r)
		}
	}))
	return siegelv1connect.NewUsernameServiceClient(http.DefaultClient, e.url, auth),
		siegelv1connect.NewAccountServiceClient(http.DefaultClient, e.url, auth)
}

func (e *env_) setUsername(token, name string) string {
	u, _ := e.clients(token)
	_, err := u.Set(e.ctx, connect.NewRequest(&siegelv1.UsernameServiceSetRequest{Username: name}))
	return errMsg(err)
}

func want(t *testing.T, got, want string) {
	t.Helper()
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestRegistration(t *testing.T) { // ID-01..ID-05, CRY-08
	e := setup(t)
	want(t, errMsg(e.otp("0034600000001")), "phone_invalid")
	want(t, errMsg(e.otp("+882123456789")), "phone_region_blocked")

	phone := "+34600000001"
	if err := e.otp(phone); err != nil {
		t.Fatal(err)
	}
	_, _, err := e.verify(phone, "000000x", "")
	want(t, errMsg(err), "otp_invalid")
	res, pub, err := e.verify(phone, e.sms[phone], "")
	if err != nil {
		t.Fatal(err)
	}
	msg := append(append([]byte("siegel-as-v1"), res.AccountId...), pub...)
	if !ed25519.Verify(e.asPub, msg, res.AsSignature) || res.ExistingAccount || !bytes.Equal(res.AsPublicKey, e.asPub) {
		t.Fatal("bad AS signature or existing flag")
	}
	_, _, err = e.verify(phone, e.sms[phone], "") // OTP is single-use
	want(t, errMsg(err), "otp_invalid")

	// 5 attempts per code (ID-03), 3 requests per number per hour (ID-04).
	p2 := "+34600000002"
	e.otp(p2)
	for range 5 {
		e.verify(p2, "999999x", "")
	}
	_, _, err = e.verify(p2, e.sms[p2], "")
	want(t, errMsg(err), "otp_invalid")
	e.otp(p2)
	e.otp(p2)
	want(t, errMsg(e.otp(p2)), "rate_limited")

	// The store review number gets its fixed code and no SMS.
	e.s.cfg.reviewPhone, e.s.cfg.reviewCode = "+34600000099", "424242"
	if err := e.otp("+34600000099"); err != nil {
		t.Fatal(err)
	}
	if _, sent := e.sms["+34600000099"]; sent {
		t.Fatal("review number got an SMS")
	}
	if _, _, err := e.verify("+34600000099", "424242", ""); err != nil {
		t.Fatal(err)
	}

	var l ipLimiter
	for range 10 {
		l.allow("1.2.3.4", 10)
	}
	if l.allow("1.2.3.4", 10) || !l.allow("5.6.7.8", 10) {
		t.Fatal("ip limiter")
	}
}

func TestUsernames(t *testing.T) { // ID-06..ID-08
	e := setup(t)
	a, _ := e.register("+34600000011", "")
	b, _ := e.register("+34600000012", "")
	for _, bad := range []string{"abc", "1abc", "ab-cd", "admin", "ñandu", "a234567890123456789012345678901234"} {
		want(t, e.setUsername(a.DeviceToken, bad), "username_invalid")
	}
	want(t, e.setUsername(a.DeviceToken, "Ana.B_1"), "")
	want(t, e.setUsername(b.DeviceToken, "ana.b_1"), "username_taken")

	u, _ := e.clients(b.DeviceToken)
	res, err := u.Lookup(e.ctx, connect.NewRequest(&siegelv1.UsernameServiceLookupRequest{Username: "ANA.B_1"}))
	if err != nil || string(res.Msg.AccountId) != string(a.AccountId) {
		t.Fatal("lookup", err)
	}
	_, err = u.Lookup(e.ctx, connect.NewRequest(&siegelv1.UsernameServiceLookupRequest{Username: "ana."}))
	want(t, errMsg(err), "username_not_found")

	want(t, e.setUsername(a.DeviceToken, "ana_new"), "username_change_too_soon")
	e.s.cfg.userChangeDay = 0
	want(t, e.setUsername(a.DeviceToken, "ana_new"), "")
	want(t, e.setUsername(b.DeviceToken, "ana.b_1"), "username_taken") // quarantined
	want(t, e.setUsername(a.DeviceToken, "ana.b_1"), "")               // owner reclaims
}

func TestRegistrationLockAndRevocation(t *testing.T) { // ID-09, ID-10, ID-16
	e := setup(t)
	e.s.cfg.otpPerNumber = 100
	phone := "+34600000021"
	old, _ := e.register(phone, "")
	want(t, e.setUsername(old.DeviceToken, "carmen"), "")
	_, acct := e.clients(old.DeviceToken)
	for _, bad := range []string{"123", "12345", "12a4", "١٢٣٤"} {
		_, err := acct.SetRegistrationLock(e.ctx, connect.NewRequest(&siegelv1.SetRegistrationLockRequest{Pin: bad}))
		want(t, errMsg(err), "pin_invalid")
	}
	if _, err := acct.SetRegistrationLock(e.ctx, connect.NewRequest(&siegelv1.SetRegistrationLockRequest{Pin: "4321"})); err != nil {
		t.Fatal(err)
	}

	_, err := e.register(phone, "")
	want(t, errMsg(err), "registration_lock_required")
	e.otp(phone)
	code := e.sms[phone]
	_, _, err = e.verify(phone, code, "1111")
	want(t, errMsg(err), "registration_lock_invalid")
	_, _, err = e.verify(phone, code, "1111")
	want(t, errMsg(err), "registration_lock_invalid")
	_, _, err = e.verify(phone, code, "1111") // 3rd failure locks (test config)
	want(t, errMsg(err), "registration_lock_invalid")
	_, _, err = e.verify(phone, code, "4321")
	want(t, errMsg(err), "registration_lock_locked")

	e.s.db.Exec(e.ctx, `UPDATE accounts SET reg_lock_locked_until = NULL`)
	nw, err := e.register(phone, "4321")
	if err != nil || !nw.ExistingAccount || string(nw.AccountId) != string(old.AccountId) {
		t.Fatal("re-register with PIN", err)
	}
	if nw.Username != "carmen" || !nw.RegistrationLock {
		t.Fatal("re-registration must report the username and the lock", nw.Username, nw.RegistrationLock)
	}
	want(t, e.setUsername(old.DeviceToken, "x_old"), "unauthenticated") // old device revoked
	u, _ := e.clients(nw.DeviceToken)
	if _, err := u.Lookup(e.ctx, connect.NewRequest(&siegelv1.UsernameServiceLookupRequest{Username: "carmen"})); err != nil {
		t.Fatal("username must stay with account", err)
	}

	// Lock lapses after 7 inactive days.
	e.s.db.Exec(e.ctx, `UPDATE devices SET last_seen_day = current_date - 8`)
	if _, err := e.register(phone, ""); err != nil {
		t.Fatal("lapsed lock", err)
	}

	// Account deletion quarantines the username.
	last, _ := e.register("+34600000022", "")
	want(t, e.setUsername(last.DeviceToken, "leaver"), "")
	_, acct = e.clients(last.DeviceToken)
	if _, err := acct.Delete(e.ctx, connect.NewRequest(&siegelv1.AccountServiceDeleteRequest{})); err != nil {
		t.Fatal(err)
	}
	other, _ := e.register("+34600000023", "")
	want(t, e.setUsername(other.DeviceToken, "leaver"), "username_taken")
	want(t, e.setUsername(last.DeviceToken, "leaver2"), "unauthenticated")
}

func TestChangeNumber(t *testing.T) { // docs/change-number.md
	e := setup(t)
	e.s.cfg.otpPerNumber = 100
	a, _ := e.register("+34600000031", "")
	b, _ := e.register("+34600000032", "") // holds the number A is about to prove
	_, acctA := e.clients(a.DeviceToken)
	if _, err := acctA.SetRegistrationLock(e.ctx, connect.NewRequest(&siegelv1.SetRegistrationLockRequest{Pin: "1234"})); err != nil {
		t.Fatal(err)
	}
	change := func(acct siegelv1connect.AccountServiceClient, phone, otp, pin string) string {
		_, err := acct.ChangeNumber(e.ctx, connect.NewRequest(&siegelv1.ChangeNumberRequest{PhoneE164: phone, Otp: otp, RegistrationLockPin: pin}))
		return errMsg(err)
	}
	conn, _, err := dial(e, b.DeviceToken)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()

	e.otp("+34600000032")
	code := e.sms["+34600000032"]
	want(t, change(acctA, "+34600000032", "000000", "1234"), "otp_invalid")
	want(t, change(acctA, "+34600000032", code, ""), "registration_lock_required")
	want(t, change(acctA, "+34600000032", code, "1234"), "")
	want(t, change(acctA, "+34600000033", code, "1234"), "number_change_too_soon")

	// B keeps its account, without a number, and is told at once.
	if f := next(t, conn); f.GetNumberRemoved() == nil {
		t.Fatal("B must be told its number went", f)
	}
	var bHmac []byte
	var removed bool
	e.s.db.QueryRow(e.ctx, `SELECT phone_hmac, number_removed FROM accounts WHERE id = $1`, b.AccountId).Scan(&bHmac, &removed)
	if bHmac != nil || !removed {
		t.Fatal("B must be numberless", bHmac, removed)
	}
	// The number now leads to A: re-registering it needs A's PIN.
	_, err = e.register("+34600000032", "")
	want(t, errMsg(err), "registration_lock_required")

	e.s.db.Exec(e.ctx, `UPDATE accounts SET number_changed_at = NULL`)
	e.otp("+34600000032")
	want(t, change(acctA, "+34600000032", e.sms["+34600000032"], "1234"), "number_same")

	// A numberless account adds a number the same way.
	_, acctB := e.clients(b.DeviceToken)
	e.otp("+34600000034")
	want(t, change(acctB, "+34600000034", e.sms["+34600000034"], ""), "")
	e.s.db.QueryRow(e.ctx, `SELECT number_removed FROM accounts WHERE id = $1`, b.AccountId).Scan(&removed)
	if removed {
		t.Fatal("B has a number again")
	}
}

func TestOtpCompletionAlert(t *testing.T) { // ID-04, SEC-04
	e := setup(t)
	var alerts []string
	hook := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		alerts = append(alerts, string(b))
	}))
	defer hook.Close()
	e.s.cfg.alertURL, e.s.cfg.otpAlertRate, e.s.cfg.otpAlertMin = hook.URL, 0.5, 3

	e.register("+34600000031", "")
	e.otp("+34600000032")
	e.s.checkOtpRate(e.ctx) // 2 sent: below the minimum volume
	e.otp("+34600000033")
	e.register("+34600000034", "")
	e.s.checkOtpRate(e.ctx) // 4 sent, 2 verified = 50%: not below
	if len(alerts) != 0 {
		t.Fatal("alerted too early", alerts)
	}
	e.otp("+34600000035")
	e.s.checkOtpRate(e.ctx) // 5 sent, 2 verified = 40%
	e.s.checkOtpRate(e.ctx) // once a day only
	if len(alerts) != 1 || !strings.Contains(alerts[0], "OTP completion 40%") {
		t.Fatal("want one 40% alert", alerts)
	}
}

func TestAbuseLimits(t *testing.T) { // request size, Verify per IP, Lookup per account
	e := setup(t)
	big := strings.Repeat("x", 70<<10)
	_, err := e.reg.RequestOtp(e.ctx, connect.NewRequest(&siegelv1.RequestOtpRequest{PhoneE164: big}))
	if connect.CodeOf(err) != connect.CodeResourceExhausted {
		t.Fatal("oversized request must be refused", err)
	}

	a, _ := e.register("+34600000041", "")
	e.s.cfg.lookupPerDay = 2
	u, _ := e.clients(a.DeviceToken)
	for range 2 {
		u.Lookup(e.ctx, connect.NewRequest(&siegelv1.UsernameServiceLookupRequest{Username: "nobody"}))
	}
	_, err = u.Lookup(e.ctx, connect.NewRequest(&siegelv1.UsernameServiceLookupRequest{Username: "nobody"}))
	want(t, errMsg(err), "rate_limited")

	e.s.cfg.verifyPerIP = 2
	e.s.ipHits = ipLimiter{} // the registration above already used Verify from this IP
	for range 2 {
		e.verify("+34600000042", "000000", "")
	}
	_, _, err = e.verify("+34600000042", "000000", "")
	want(t, errMsg(err), "rate_limited")
}

func TestHTTPErrorLogHasNoIPs(t *testing.T) { // SEC-03
	var b bytes.Buffer
	r := redactAddrs{&b}
	r.Write([]byte("http: TLS handshake error from 205.210.31.161:61904: tls: bad\n"))
	r.Write([]byte("http: panic serving [2001:db8::1]:443: boom\n"))
	if strings.Contains(b.String(), "205.210") || strings.Contains(b.String(), "2001:db8") || !strings.Contains(b.String(), "from [ip]: tls: bad") {
		t.Fatal(b.String())
	}
}

func TestPublicPages(t *testing.T) { // CMP-07
	e := setup(t)
	for path, want := range map[string]string{"/privacy": "Privacy policy", "/delete-account": "Settings → Delete account", "/terms": "Terms of service", "/guidelines": "Sexual content involving a minor"} {
		res, err := http.Get(e.url + path)
		if err != nil {
			t.Fatal(err)
		}
		b, _ := io.ReadAll(res.Body)
		res.Body.Close()
		if res.StatusCode != 200 || !strings.Contains(string(b), want) {
			t.Fatalf("%s: %d", path, res.StatusCode)
		}
	}
	e.s.cfg.contactEmail = "privacy@example.org"
	res, _ := http.Get(e.url + "/delete-account")
	b, _ := io.ReadAll(res.Body)
	if !strings.Contains(string(b), "mailto:privacy@example.org") {
		t.Fatal("contact email not shown")
	}
}

func TestOtpResend(t *testing.T) { // ID-04: resend waits double each time; hourly and daily caps
	e := setup(t)
	e.s.cfg.otpResendWait = 30 * time.Second
	e.s.cfg.otpPerNumber, e.s.cfg.otpPerDay = 10, 3
	phone := "+34600000061"
	send := func() (uint32, string) {
		res, err := e.reg.RequestOtp(e.ctx, connect.NewRequest(&siegelv1.RequestOtpRequest{PhoneE164: phone}))
		if err != nil {
			return 0, errMsg(err)
		}
		return res.Msg.ResendAfterSeconds, ""
	}
	backdate := func(d time.Duration) {
		e.s.db.Exec(e.ctx, `UPDATE otps SET last_sent_at = now() - $1::interval`, fmt.Sprintf("%d seconds", int(d.Seconds())))
	}
	wait, err := send()
	if err != "" || wait != 30 {
		t.Fatal(wait, err)
	}
	first := e.sms[phone]
	if _, err := send(); err != "resend_too_soon" {
		t.Fatal("resend before the wait:", err)
	}
	backdate(31 * time.Second)
	if wait, err := send(); err != "" || wait != 60 || e.sms[phone] != first {
		t.Fatal("second send waits 60 s and repeats the code", wait, err)
	}
	backdate(61 * time.Second)
	if wait, err := send(); err != "" || wait != 120 {
		t.Fatal(wait, err)
	}
	backdate(121 * time.Second)
	if _, err := send(); err != "rate_limited" {
		t.Fatal("daily cap reached:", err)
	}
	if _, _, err := e.verify(phone, first, ""); err != nil {
		t.Fatal("the resent code still works", err)
	}
}

func TestAppVersion(t *testing.T) {
	e := setup(t)
	e.s.cfg.androidLatest, e.s.cfg.androidMin = 9, 5
	res, err := e.reg.AppVersion(e.ctx, connect.NewRequest(&siegelv1.AppVersionRequest{Platform: siegelv1.Platform_PLATFORM_ANDROID}))
	if err != nil || res.Msg.Latest != 9 || res.Msg.Minimum != 5 {
		t.Fatal(res, err)
	}
}

func TestContactPageAndAssetLinks(t *testing.T) { // DISC-08
	e := setup(t)
	e.s.cfg.androidCerts = []string{"AA:BB"}
	res, _ := http.Get(e.url + "/u/Ana.B")
	b, _ := io.ReadAll(res.Body)
	if res.StatusCode != 200 || !strings.Contains(string(b), "@ana.b") {
		t.Fatal(res.StatusCode)
	}
	if res, _ := http.Get(e.url + "/u/%3Cscript%3E"); res.StatusCode != 404 {
		t.Fatal("bad usernames must 404")
	}
	res, _ = http.Get(e.url + "/.well-known/assetlinks.json")
	b, _ = io.ReadAll(res.Body)
	if !strings.Contains(string(b), `"in.schlk.siegel"`) || !strings.Contains(string(b), "AA:BB") {
		t.Fatal(string(b))
	}
}

func TestExport(t *testing.T) { // CMP-06, RM-01
	e := setup(t)
	a, _ := e.register("+34600000041", "")
	_, acct := e.clients(a.DeviceToken)
	want(t, e.setUsername(a.DeviceToken, "exported"), "")
	acct.SetRegistrationLock(e.ctx, connect.NewRequest(&siegelv1.SetRegistrationLockRequest{Pin: "1234"}))
	acct.SetPushToken(e.ctx, connect.NewRequest(&siegelv1.SetPushTokenRequest{PushToken: "tok"}))
	res, err := acct.Export(e.ctx, connect.NewRequest(&siegelv1.AccountServiceExportRequest{}))
	if err != nil {
		t.Fatal(err)
	}
	r := res.Msg
	if r.Username != "exported" || !r.RegistrationLock || len(r.PhoneHmac) != 32 || r.CreatedDay == "" || r.Discoverable ||
		len(r.Devices) != 1 || !r.Devices[0].ThisDevice || !r.Devices[0].PushToken || r.Devices[0].Platform != siegelv1.Platform_PLATFORM_IOS {
		t.Fatalf("export: %+v", r)
	}
	if strings.Contains(r.String(), "34600000041") {
		t.Fatal("export must not hold the number")
	}
}

func TestMigrateExistingDatabase(t *testing.T) { // prod had the schema before migrations
	e := setup(t)
	if _, err := e.s.db.Exec(e.ctx, `DROP TABLE schema_migrations`); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := migrate(e.ctx, e.s.db); err != nil {
			t.Fatal(err)
		}
	}
	var n int
	e.s.db.QueryRow(e.ctx, `SELECT count(*) FROM schema_migrations`).Scan(&n)
	if n != 1 {
		t.Fatal("baseline must be recorded once", n)
	}
}
