package main

// Integration tests against a real PostgreSQL:
//   docker compose up -d postgres
//   SIEGEL_TEST_DATABASE_URL=postgres://postgres:siegel@localhost:55432/siegel go test ./...

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

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
	if _, err := db.Exec(ctx, "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"+schema); err != nil {
		t.Fatal(err)
	}
	seed := make([]byte, 32)
	rand.Read(seed)
	cfg := config{
		pepper: seed, asKey: ed25519.NewKeyFromSeed(seed),
		otpTTL: 600e9, otpAttempts: 5, otpPerNumber: 3, otpPerIP: 1000, smsDailyCap: 1000,
		denyPrefixes: []string{"+882"},
		userMin:      4, userMax: 32, userChangeDay: 30, userQuarDay: 30,
		lockAttempts: 3, lockLockout: 3600e9, lockLapseDay: 7,
	}
	e := &env_{t: t, sms: map[string]string{}, ctx: ctx, asPub: cfg.asKey.Public().(ed25519.PublicKey)}
	e.s = newServer(cfg, db)
	e.s.attest = func(context.Context, string) error { return nil }
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
	if !ed25519.Verify(e.asPub, msg, res.AsSignature) || res.ExistingAccount {
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
	want(t, e.setUsername(old.DeviceToken, "owner"), "")
	_, acct := e.clients(old.DeviceToken)
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
	want(t, e.setUsername(old.DeviceToken, "x_old"), "unauthenticated") // old device revoked
	u, _ := e.clients(nw.DeviceToken)
	if _, err := u.Lookup(e.ctx, connect.NewRequest(&siegelv1.UsernameServiceLookupRequest{Username: "owner"})); err != nil {
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
