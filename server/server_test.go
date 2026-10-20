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
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/gtank/ristretto255"
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
	files, _ := fs.Glob(migrations, "migrations/*.sql")
	if n != len(files) {
		t.Fatal("each migration recorded once", n, len(files))
	}
}

func TestMinorsAreFoundOnlyByTheirNumber(t *testing.T) { // M7 part 2
	e := setup(t)
	kid, _ := e.register("+34600000051", "")
	adult, _ := e.register("+34600000052", "")
	want(t, e.setUsername(kid.DeviceToken, "kiddo"), "")
	users, acct := e.clients(kid.DeviceToken)
	if _, err := acct.SetMinor(e.ctx, connect.NewRequest(&siegelv1.SetMinorRequest{Minor: true})); err != nil {
		t.Fatal(err)
	}
	adultUsers, _ := e.clients(adult.DeviceToken)
	lookup := func(u siegelv1connect.UsernameServiceClient, proof []byte) string {
		_, err := u.Lookup(e.ctx, connect.NewRequest(&siegelv1.UsernameServiceLookupRequest{Username: "kiddo", DiscoveryProof: proof}))
		return errMsg(err)
	}
	want(t, lookup(adultUsers, nil), "username_not_found")
	want(t, lookup(users, nil), "") // themselves

	// With discovery on, the output for their number (what an OPRF evaluation yields) finds them.
	d := siegelv1connect.NewDiscoveryServiceClient(http.DefaultClient, e.url, connect.WithInterceptors(
		connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
			return func(ctx context.Context, r connect.AnyRequest) (connect.AnyResponse, error) {
				r.Header().Set("Authorization", "Bearer "+kid.DeviceToken)
				return next(ctx, r)
			}
		})))
	if _, err := d.SetDiscoverable(e.ctx, connect.NewRequest(&siegelv1.DiscoveryServiceSetDiscoverableRequest{PhoneE164: "+34600000051"})); err != nil {
		t.Fatal(err)
	}
	k, _ := e.s.disc.scalar(e.ctx, fmt.Sprint("period:", e.s.discPeriod(time.Now())))
	out := func(phone string) []byte {
		return discOutput(ristretto255.NewElement().ScalarMult(k, discPoint(phone)))
	}
	want(t, lookup(adultUsers, out("+34600000099")), "username_not_found") // someone else's number
	want(t, lookup(adultUsers, out("+34600000051")), "")

	// Their contact link works for whoever was given it.
	secret := []byte("0123456789abcdef")
	h := sha256.Sum256(secret)
	acct.SetMinor(e.ctx, connect.NewRequest(&siegelv1.SetMinorRequest{Minor: true, LinkSecretHash: h[:]}))
	byLink := func(s []byte) string {
		_, err := adultUsers.Lookup(e.ctx, connect.NewRequest(&siegelv1.UsernameServiceLookupRequest{Username: "kiddo", LinkSecret: s}))
		return errMsg(err)
	}
	want(t, byLink([]byte("wrong")), "username_not_found")
	want(t, byLink(secret), "")

	res, _ := acct.Export(e.ctx, connect.NewRequest(&siegelv1.AccountServiceExportRequest{}))
	if !res.Msg.Minor {
		t.Fatal("export shows the flag")
	}
	acct.SetMinor(e.ctx, connect.NewRequest(&siegelv1.SetMinorRequest{Minor: false}))
	want(t, lookup(adultUsers, nil), "") // 18th birthday
}

func TestReports(t *testing.T) { // CMP-03, M7 part 3
	e := setup(t)
	a, _ := e.register("+34600000061", "")
	b, _ := e.register("+34600000062", "")
	r := siegelv1connect.NewReportServiceClient(http.DefaultClient, e.url, connect.WithInterceptors(
		connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
			return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
				req.Header().Set("Authorization", "Bearer "+a.DeviceToken)
				return next(ctx, req)
			}
		})))
	key, _ := r.Key(e.ctx, connect.NewRequest(&siegelv1.ReportServiceKeyRequest{}))
	if key.Msg.AgeRecipient != "" {
		t.Fatal("no key configured: reporting is off")
	}
	e.s.cfg.reportsKey = "AGE-SECRET-KEY-1XYZ"
	key, _ = r.Key(e.ctx, connect.NewRequest(&siegelv1.ReportServiceKeyRequest{}))
	if key.Msg.AgeRecipient != "" {
		t.Fatal("a secret key is never handed out")
	}
	e.s.cfg.reportsKey = "age1testrecipient"
	key, _ = r.Key(e.ctx, connect.NewRequest(&siegelv1.ReportServiceKeyRequest{}))
	want(t, key.Msg.AgeRecipient, "age1testrecipient")

	submit := func(sealed string) string {
		_, err := r.Submit(e.ctx, connect.NewRequest(&siegelv1.ReportServiceSubmitRequest{
			Category: siegelv1.ReportCategory_REPORT_CATEGORY_CHILD_SAFETY, ReportedAccount: b.AccountId, Sealed: []byte(sealed)}))
		return errMsg(err)
	}
	want(t, submit("plaintext report"), "report_invalid") // only sealed reports are kept
	sealed := "age-encryption.org/v1\n-> X25519 stub\nciphertext"
	want(t, submit(sealed), "")
	var n int
	var stored []byte
	e.s.db.QueryRow(e.ctx, `SELECT count(*), max(sealed) FROM reports WHERE reported = $1 AND category = 4`, b.AccountId).Scan(&n, &stored)
	if n != 1 || string(stored) != sealed {
		t.Fatal("stored as sent", n)
	}
	for range reportsPerDay - 1 {
		submit(sealed)
	}
	want(t, submit(sealed), "rate_limited")
}

func TestEnforcement(t *testing.T) { // M7 part 4
	e := setup(t)
	bad, _ := e.register("+34600000071", "")
	want(t, e.setUsername(bad.DeviceToken, "troll"), "")
	users, acct := e.clients(bad.DeviceToken)
	var id [16]byte
	copy(id[:], bad.AccountId)
	mod := act{operator: "max", rule: siegelv1.ReportCategory_REPORT_CATEGORY_HARASSMENT, reason: "threats to another user"}

	// Every action needs a reason.
	want(t, errMsg(e.s.suspend(e.ctx, id, time.Now().Add(time.Hour), act{operator: "max"})), errNoReason.Error())

	// Suspended: the stream says why and until when, then closes; only Delete still works.
	conn, _, err := dial(e, bad.DeviceToken)
	if err != nil {
		t.Fatal(err)
	}
	if err := e.s.suspend(e.ctx, id, time.Now().Add(48*time.Hour), mod); err != nil {
		t.Fatal(err)
	}
	f := next(t, conn).GetEnforcement()
	if f == nil || f.Kind != siegelv1.Enforcement_KIND_SUSPENDED || f.Reason != mod.reason || f.UntilMs < time.Now().Add(47*time.Hour).UnixMilli() {
		t.Fatal("statement of reasons on the stream", f)
	}
	conn.CloseNow()
	_, err = users.Lookup(e.ctx, connect.NewRequest(&siegelv1.UsernameServiceLookupRequest{Username: "troll"}))
	want(t, errMsg(err), "account_suspended")
	if err := e.s.unsuspend(e.ctx, id, act{operator: "max", reason: "appeal accepted"}); err != nil {
		t.Fatal(err)
	}
	_, err = users.Lookup(e.ctx, connect.NewRequest(&siegelv1.UsernameServiceLookupRequest{Username: "troll"}))
	want(t, errMsg(err), "")

	// Username removed: a notice until they pick a new one; the old name is gone for good.
	if err := e.s.removeUsername(e.ctx, "troll", mod); err != nil {
		t.Fatal(err)
	}
	if n, _ := e.s.enforcement(e.ctx, id); n == nil || n.Kind != siegelv1.Enforcement_KIND_USERNAME_REMOVED {
		t.Fatal("username notice", n)
	}
	want(t, e.setUsername(bad.DeviceToken, "troll"), "username_taken")
	want(t, e.setUsername(bad.DeviceToken, "friendly"), "")
	if n, _ := e.s.enforcement(e.ctx, id); n != nil {
		t.Fatal("notice done once a new name is set", n)
	}

	// Ban: the account is gone and the number can't come back.
	if err := e.s.ban(e.ctx, id, nil, mod); err != nil {
		t.Fatal(err)
	}
	_, err = acct.Export(e.ctx, connect.NewRequest(&siegelv1.AccountServiceExportRequest{}))
	want(t, errMsg(err), "unauthenticated")
	want(t, errMsg(e.otp("+34600000071")), "number_banned")
	other, _ := e.register("+34600000072", "")
	want(t, e.setUsername(other.DeviceToken, "friendly"), "username_taken")

	// The audit log has every action, chained; an edit breaks the chain.
	var n int
	e.s.db.QueryRow(e.ctx, `SELECT count(*) FROM audit_log`).Scan(&n)
	if n != 4 {
		t.Fatal("one row per action", n)
	}
	if bad, err := e.s.auditVerify(e.ctx); err != nil || bad != 0 {
		t.Fatal("chain intact", bad, err)
	}
	e.s.db.Exec(e.ctx, `UPDATE audit_log SET reason = 'nothing to see' WHERE id = (SELECT min(id) + 1 FROM audit_log)`)
	if bad, _ := e.s.auditVerify(e.ctx); bad == 0 {
		t.Fatal("an edited row must break the chain")
	}

	// The CLI runs the same actions.
	var out strings.Builder
	if err := e.s.admin(e.ctx, []string{"suspend", "--days", "1", "--rule", "spam", "--reason", "mass messages", "--by", "max", "@nobody"}, &out); !errors.Is(err, errNotFound) {
		t.Fatal("unknown target", err)
	}
	if err := e.s.admin(e.ctx, []string{"suspend", "--days", "1", "--rule", "spam", "--reason", "mass messages", "@friendly"}, &out); err == nil {
		t.Fatal("banned account's old name no longer resolves")
	}
	if err := e.s.admin(e.ctx, []string{"remove-username", "--rule", "spam", "@x"}, &out); !errors.Is(err, errNoReason) {
		t.Fatal("reason required", err)
	}
}

func TestSignals(t *testing.T) { // M7 part 6
	e := setup(t)
	e.s.cfg.lookupPerDay = 1
	a, _ := e.register("+34600000081", "")
	users, _ := e.clients(a.DeviceToken)
	for range 3 {
		users.Lookup(e.ctx, connect.NewRequest(&siegelv1.UsernameServiceLookupRequest{Username: "nobody"}))
	}
	var id [16]byte
	copy(id[:], a.AccountId)
	e.s.db.Exec(e.ctx, `INSERT INTO reports (reporter, reported, category, sealed) VALUES ($1, $2, 4, 'x'), ($1, $2, 1, 'x')`, id, id)
	g, err := e.s.signals(e.ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if g.LookupLimit != 2 || g.Reports != 2 || g.ChildSafetyReports != 1 || g.CreatedDay == "" {
		t.Fatalf("signals %+v", g)
	}
	var out strings.Builder
	if err := e.s.admin(e.ctx, []string{"signals", hex.EncodeToString(id[:])}, &out); err != nil || !strings.Contains(out.String(), "lookup limit hit 2") {
		t.Fatal(out.String(), err)
	}
}

func TestUsernameScan(t *testing.T) { // M7 part 8
	e := setup(t)
	a, _ := e.register("+34600000091", "")
	b, _ := e.register("+34600000092", "")
	want(t, e.setUsername(a.DeviceToken, "friendly"), "")
	// Names taken before the lists grew: put them in directly.
	e.s.db.Exec(e.ctx, `INSERT INTO usernames (name, account_id) VALUES ('teen.nudes', $1)`, b.AccountId)
	n, err := e.s.scanUsernames(e.ctx)
	if err != nil || n != 1 {
		t.Fatal("one flag", n, err)
	}
	if n, _ := e.s.scanUsernames(e.ctx); n != 0 {
		t.Fatal("never queued twice", n)
	}
	if !e.s.due(e.ctx, "username_scan", 72*time.Hour) || e.s.due(e.ctx, "username_scan", 72*time.Hour) {
		t.Fatal("due once per period")
	}
	var out strings.Builder
	e.s.admin(e.ctx, []string{"flags"}, &out)
	if !strings.Contains(out.String(), "@teen.nudes  contains teen and nude") {
		t.Fatal(out.String())
	}
}

func TestConsole(t *testing.T) { // M7 part 5
	e := setup(t)
	c, err := newConsole(e.s)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(c.routes())
	defer srv.Close()
	noRedirect := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

	res, _ := noRedirect.Get(srv.URL + "/")
	if res.StatusCode != http.StatusSeeOther || res.Header.Get("Location") != "/login" {
		t.Fatal("login first", res.StatusCode)
	}
	res, _ = http.Get(srv.URL + "/static/age.js")
	if res.StatusCode != 200 || !strings.Contains(res.Header.Get("Content-Type"), "javascript") {
		t.Fatal("bundled age served", res.StatusCode, res.Header.Get("Content-Type"))
	}
	if !strings.Contains(res.Header.Get("Content-Security-Policy"), "default-src 'self'") {
		t.Fatal("CSP")
	}

	// Enrolment links are single use.
	link, _ := e.s.enrolLink(e.ctx, "max")
	tok := link[strings.Index(link, "?t=")+3:]
	begin := func(t string) int {
		req, _ := http.NewRequest("POST", srv.URL+"/enrol/begin?t="+t, nil)
		req.Header.Set("Origin", consoleOrigin)
		res, _ := http.DefaultClient.Do(req)
		return res.StatusCode
	}
	want(t, fmt.Sprint(begin(tok)), "200")
	want(t, fmt.Sprint(begin(tok)), "403")

	// A logged-in operator (the passkey ceremony needs a real authenticator; seed the session).
	opID := []byte("operator-id-0123456789abcdef0123")
	e.s.db.Exec(e.ctx, `INSERT INTO console_operators (id, name) VALUES ($1, 'max')`, opID)
	session := "session-token"
	e.s.db.Exec(e.ctx, `INSERT INTO console_sessions (token_hash, operator_id, expires_at) VALUES ($1, $2, now() + interval '1 hour')`,
		hashToken(session), opID)
	reporter, _ := e.register("+34600000101", "")
	bad, _ := e.register("+34600000102", "")
	var rid int64
	e.s.db.QueryRow(e.ctx, `INSERT INTO reports (reporter, reported, category, sealed) VALUES ($1, $2, 4, 'age-encryption.org/v1 x') RETURNING id`,
		reporter.AccountId, bad.AccountId).Scan(&rid)
	get := func(path string) string {
		req, _ := http.NewRequest("GET", srv.URL+path, nil)
		req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		res, _ := http.DefaultClient.Do(req)
		b, _ := io.ReadAll(res.Body)
		return string(b)
	}
	if q := get("/"); !strings.Contains(q, fmt.Sprintf(`href="/report/%d"`, rid)) || !strings.Contains(q, "child_safety") {
		t.Fatal("queue shows the report")
	}
	if p := get(fmt.Sprintf("/report/%d", rid)); !strings.Contains(p, `data-sealed="`) || !strings.Contains(p, "second operator") {
		t.Fatal("report page carries the sealed report and the child-safety reminder")
	}

	post := func(origin string, form url.Values) int {
		req, _ := http.NewRequest("POST", srv.URL+"/action", strings.NewReader(form.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("Origin", origin)
		req.AddCookie(&http.Cookie{Name: sessionCookie, Value: session})
		res, _ := noRedirect.Do(req)
		return res.StatusCode
	}
	resolve := url.Values{"kind": {"resolve-report"}, "target": {fmt.Sprint(rid)}, "outcome": {"action taken"}, "reason": {"banned"}}
	want(t, fmt.Sprint(post("https://evil.example", resolve)), "403")
	want(t, fmt.Sprint(post(consoleOrigin, resolve)), "303")
	var op string
	e.s.db.QueryRow(e.ctx, `SELECT operator FROM audit_log ORDER BY id DESC LIMIT 1`).Scan(&op)
	want(t, op, "max")

	// The reporter's app hears that it was reviewed, once.
	conn, _, err := dial(e, reporter.DeviceToken)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	if f := next(t, conn).GetReportsReviewed(); f == nil || f.Count != 1 {
		t.Fatal("told once", f)
	}
}

func TestRetentionAndTransparency(t *testing.T) { // M7 part 7
	e := setup(t)
	a, _ := e.register("+34600000111", "")
	b, _ := e.register("+34600000112", "")
	want(t, e.setUsername(b.DeviceToken, "rude"), "")
	var id [16]byte
	copy(id[:], b.AccountId)

	// Lawful request: the export is all we hold, as JSON; preserving keeps it 90 days.
	var out strings.Builder
	if err := e.s.admin(e.ctx, []string{"preserve", "--order", "JDO-7/2026", "--reason", "court order", "--by", "max", "@rude"}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), `"username":"rude"`) && !strings.Contains(out.String(), `"username": "rude"`) {
		t.Fatal("export JSON", out.String())
	}
	var n int
	e.s.db.QueryRow(e.ctx, `SELECT count(*) FROM preservations WHERE order_ref = 'JDO-7/2026' AND expires_at > now() + interval '89 days'`).Scan(&n)
	want(t, fmt.Sprint(n), "1")
	for _, args := range [][]string{
		{"request-log", "--kind", "production", "--outcome", "answered", "--order", "JDO-7/2026", "--reason", "sent the export", "--by", "max", "Juzgado 3 Madrid"},
		{"suspend", "--days", "3", "--rule", "harassment", "--reason", "threats", "--by", "max", "@rude"},
		{"appeal", "--outcome", "upheld", "--reason", "evidence clear", "--by", "max", "@rude"},
	} {
		out.Reset()
		if err := e.s.admin(e.ctx, args, &out); err != nil {
			t.Fatal(args[0], err)
		}
	}

	// Retention: old resolved reports go; a legal hold keeps one.
	e.s.db.Exec(e.ctx, `INSERT INTO reports (reporter, reported, category, sealed, created_at, resolved_at) VALUES
		($1, $2, 1, 'x', now() - interval '8 months', now() - interval '7 months'),
		($1, $2, 1, 'x', now() - interval '8 months', now() - interval '7 months'),
		($1, $2, 4, 'x', now() - interval '13 months', NULL),
		($1, $2, 2, 'x', now(), NULL)`, a.AccountId, id)
	var held int64
	e.s.db.QueryRow(e.ctx, `SELECT min(id) FROM reports`).Scan(&held)
	out.Reset()
	if err := e.s.admin(e.ctx, []string{"hold", "--days", "30", "--reason", "court asked", "--by", "max", fmt.Sprint(held)}, &out); err != nil {
		t.Fatal(err)
	}
	e.s.retain(e.ctx)
	e.s.db.QueryRow(e.ctx, `SELECT count(*) FROM reports`).Scan(&n)
	want(t, fmt.Sprint(n), "2") // the held one and the fresh one

	tally(e.ctx, e.s.db, "report:child_safety")
	res, _ := http.Get(e.url + "/transparency")
	page, _ := io.ReadAll(res.Body)
	for _, s := range []string{"child safety", "suspend", "upheld", "production, answered"} {
		if !strings.Contains(string(page), s) {
			t.Fatal("transparency page shows", s)
		}
	}
	if strings.Contains(string(page), "rude") || strings.Contains(string(page), "Juzgado") {
		t.Fatal("numbers only, never who")
	}
}

func TestLinkedDevices(t *testing.T) { // M8 part 1
	e := setup(t)
	a, _ := e.register("+34600000121", "")
	_, acct := e.clients(a.DeviceToken)
	linker := func(token string) siegelv1connect.LinkServiceClient {
		return siegelv1connect.NewLinkServiceClient(http.DefaultClient, e.url, connect.WithInterceptors(
			connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
				return func(ctx context.Context, r connect.AnyRequest) (connect.AnyResponse, error) {
					if token != "" {
						r.Header().Set("Authorization", "Bearer "+token)
					}
					return next(ctx, r)
				}
			})))
	}
	web, phone := linker(""), linker(a.DeviceToken)

	// The new device starts a link; nothing to collect until the phone completes it.
	begun, err := web.Begin(e.ctx, connect.NewRequest(&siegelv1.LinkServiceBeginRequest{AgeRecipient: "age1web"}))
	if err != nil {
		t.Fatal(err)
	}
	id := begun.Msg.LinkId
	got, _ := web.Collect(e.ctx, connect.NewRequest(&siegelv1.LinkServiceCollectRequest{LinkId: id}))
	if len(got.Msg.Sealed) != 0 {
		t.Fatal("nothing yet")
	}
	added, err := acct.AddDevice(e.ctx, connect.NewRequest(&siegelv1.AddDeviceRequest{Name: "Firefox on Linux", Platform: siegelv1.Platform_PLATFORM_WEB}))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := phone.Complete(e.ctx, connect.NewRequest(&siegelv1.LinkServiceCompleteRequest{LinkId: id, Sealed: []byte("sealed bundle")})); err != nil {
		t.Fatal(err)
	}
	got, _ = web.Collect(e.ctx, connect.NewRequest(&siegelv1.LinkServiceCollectRequest{LinkId: id}))
	want(t, string(got.Msg.Sealed), "sealed bundle")
	_, err = web.Collect(e.ctx, connect.NewRequest(&siegelv1.LinkServiceCollectRequest{LinkId: id}))
	want(t, errMsg(err), "link_expired") // collected once

	// The linked device works with its token, but can't link or unlink others.
	_, linkedAcct := e.clients(added.Msg.DeviceToken)
	list, err := linkedAcct.ListDevices(e.ctx, connect.NewRequest(&siegelv1.ListDevicesRequest{}))
	if err != nil || len(list.Msg.Devices) != 2 || !list.Msg.Devices[1].Linked || list.Msg.Devices[1].Name != "Firefox on Linux" {
		t.Fatal("two devices, the linked one named", list, err)
	}
	_, err = linkedAcct.AddDevice(e.ctx, connect.NewRequest(&siegelv1.AddDeviceRequest{Name: "x"}))
	want(t, errMsg(err), "primary_only")

	// At most 4 linked.
	for range 3 {
		if _, err := acct.AddDevice(e.ctx, connect.NewRequest(&siegelv1.AddDeviceRequest{Name: "tab"})); err != nil {
			t.Fatal(err)
		}
	}
	_, err = acct.AddDevice(e.ctx, connect.NewRequest(&siegelv1.AddDeviceRequest{Name: "fifth"}))
	want(t, errMsg(err), "too_many_devices")

	// Claiming our own account's keys skips the device asking.
	keys := siegelv1connect.NewKeysServiceClient(http.DefaultClient, e.url, connect.WithInterceptors(
		connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
			return func(ctx context.Context, r connect.AnyRequest) (connect.AnyResponse, error) {
				r.Header().Set("Authorization", "Bearer "+a.DeviceToken)
				return next(ctx, r)
			}
		})))
	e.s.db.Exec(e.ctx, `INSERT INTO key_packages (account_id, device_id, data) SELECT account_id, device_id, '\x00' FROM devices WHERE account_id = $1`, a.AccountId)
	claimed, _ := keys.Claim(e.ctx, connect.NewRequest(&siegelv1.KeysServiceClaimRequest{AccountId: a.AccountId}))
	for _, k := range claimed.Msg.KeyPackages {
		if string(k.DeviceId) == string(a.DeviceId) {
			t.Fatal("never our own device")
		}
	}
	want(t, fmt.Sprint(len(claimed.Msg.KeyPackages)), "4")

	// Unlinking: the device is gone; the primary can't be removed this way.
	if _, err := acct.RemoveDevice(e.ctx, connect.NewRequest(&siegelv1.RemoveDeviceRequest{DeviceId: added.Msg.DeviceId})); err != nil {
		t.Fatal(err)
	}
	_, err = linkedAcct.ListDevices(e.ctx, connect.NewRequest(&siegelv1.ListDevicesRequest{}))
	want(t, errMsg(err), "unauthenticated")
	_, err = acct.RemoveDevice(e.ctx, connect.NewRequest(&siegelv1.RemoveDeviceRequest{DeviceId: a.DeviceId}))
	want(t, errMsg(err), "device_not_found")
}

func TestIssueCode(t *testing.T) { // SMS didn't arrive: an operator issues the code
	e := setup(t)
	var out strings.Builder
	if err := e.s.admin(e.ctx, []string{"issue-code", "--reason", "SMS not arriving, owner confirmed by call", "--by", "max", "+34600000131"}, &out); err != nil {
		t.Fatal(err)
	}
	code := strings.TrimSuffix(strings.Fields(out.String())[1], ",")
	if _, _, err := e.verify("+34600000131", code, ""); err != nil {
		t.Fatal("the issued code registers", err)
	}
	var action, target string
	e.s.db.QueryRow(e.ctx, `SELECT action, target FROM audit_log ORDER BY id DESC LIMIT 1`).Scan(&action, &target)
	if action != "issue sign-up code" || strings.Contains(target, "600000131") {
		t.Fatal("audited, never with the number", action, target)
	}
	if err := e.s.admin(e.ctx, []string{"issue-code", "--by", "max", "+34600000131"}, &out); !errors.Is(err, errNoReason) {
		t.Fatal("a reason is required", err)
	}
}
