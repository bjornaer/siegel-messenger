package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"net"
	"regexp"
	"strings"
	"sync"
	"time"

	"connectrpc.com/connect"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
)

type server struct {
	cfg       config
	db        *pgxpool.Pool
	attest    func(ctx context.Context, platform siegelv1.Platform, phone, token string) error
	sendSMS   func(ctx context.Context, phone, code string) error
	hmacPhone func(ctx context.Context, phone string) ([]byte, error)
	signAS    func(ctx context.Context, msg []byte) ([]byte, error)
	hub       *hub
	sendPush  func(ctx context.Context, platform siegelv1.Platform, token string) error
	pushes    pushes
	blobs     blobStore
	disc      discKeys

	fetchASPublic func(ctx context.Context) ([]byte, error)
	asMu          sync.Mutex
	asPublic      []byte // AS public key, handed to clients at registration (CRY-08)
	ipHits        ipLimiter
	lastAlert     time.Time // janitor goroutine only
}

func newServer(cfg config, db *pgxpool.Pool) *server {
	return &server{cfg: cfg, db: db, hub: newHub()}
}

var e164 = regexp.MustCompile(`^\+[1-9][0-9]{6,14}$`)

func cerr(code connect.Code, msg string) error { return connect.NewError(code, errors.New(msg)) }

// internal logs the real error and hands the client a generic one.
func internal(err error) error {
	slog.Error("internal", "err", err)
	return cerr(connect.CodeInternal, "internal")
}

func newUUID() [16]byte {
	var u [16]byte
	rand.Read(u[:])
	u[6] = u[6]&0x0f | 0x40
	u[8] = u[8]&0x3f | 0x80
	return u
}

// hit counts one event in a fixed window stored in PostgreSQL (SRV-04) and reports whether it is within max.
// ponytail: fixed windows allow a 2x burst at the boundary; use sliding windows if that gets abused.
func (s *server) hit(ctx context.Context, key string, window time.Duration, max int) (bool, error) {
	var n int
	err := s.db.QueryRow(ctx, `INSERT INTO rate_limits VALUES ($1, $2, 1)
		ON CONFLICT (key, window_start) DO UPDATE SET count = rate_limits.count + 1 RETURNING count`,
		key, time.Now().UTC().Truncate(window)).Scan(&n)
	return n <= max, err
}

// ipLimiter counts per-IP requests for the current hour in memory only; IPs never reach the DB (SEC-03).
type ipLimiter struct {
	mu     sync.Mutex
	window time.Time
	counts map[string]int
}

func (l *ipLimiter) allow(ip string, max int) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if w := time.Now().Truncate(time.Hour); !w.Equal(l.window) {
		l.window, l.counts = w, map[string]int{}
	}
	l.counts[ip]++
	return l.counts[ip] <= max
}

// asPublicKey is fetched lazily so the server starts while OpenBao is still sealed.
func (s *server) asPublicKey(ctx context.Context) ([]byte, error) {
	s.asMu.Lock()
	defer s.asMu.Unlock()
	if s.asPublic == nil {
		k, err := s.fetchASPublic(ctx)
		if err != nil {
			return nil, err
		}
		s.asPublic = k
	}
	return s.asPublic, nil
}

// peerIP is the direct peer. ponytail: read X-Forwarded-For once a trusted load balancer sits in front.
func peerIP(p connect.Peer) string {
	ip, _, _ := net.SplitHostPort(p.Addr)
	return ip
}

func (s *server) RequestOtp(ctx context.Context, req *connect.Request[siegelv1.RequestOtpRequest]) (*connect.Response[siegelv1.RequestOtpResponse], error) {
	phone := req.Msg.PhoneE164
	if !e164.MatchString(phone) {
		return nil, cerr(connect.CodeInvalidArgument, "phone_invalid")
	}
	if err := s.attest(ctx, req.Msg.Platform, phone, req.Msg.AttestationToken); err != nil {
		slog.Info("attestation rejected", "err", err) // reasons only: no number, token or IP
		return nil, cerr(connect.CodePermissionDenied, "attestation_failed")
	}
	for _, p := range s.cfg.denyPrefixes {
		if strings.HasPrefix(phone, p) {
			return nil, cerr(connect.CodePermissionDenied, "phone_region_blocked")
		}
	}
	if !s.ipHits.allow("otp|"+peerIP(req.Peer()), s.cfg.otpPerIP) {
		return nil, cerr(connect.CodeResourceExhausted, "rate_limited")
	}
	h, err := s.hmacPhone(ctx, phone)
	if err != nil {
		return nil, internal(err)
	}
	// A resend of a still-valid code waits 30 s, then 60 s, 120 s... (ID-04). The wait is
	// checked before the hourly and daily caps, so tapping early costs nothing.
	var sends, attempts int
	var pending, lastSent = "", time.Time{}
	err = s.db.QueryRow(ctx, `SELECT code, sends, last_sent_at, attempts FROM otps WHERE phone_hmac = $1 AND expires_at > now()`, h).
		Scan(&pending, &sends, &lastSent, &attempts)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, internal(err)
	}
	if pending != "" && time.Since(lastSent) < s.resendWait(sends) {
		return nil, cerr(connect.CodeResourceExhausted, "resend_too_soon")
	}
	if ok, err := s.hit(ctx, fmt.Sprintf("otp:%x", h), time.Hour, s.cfg.otpPerNumber); err != nil {
		return nil, internal(err)
	} else if !ok {
		return nil, cerr(connect.CodeResourceExhausted, "rate_limited")
	}
	if ok, err := s.hit(ctx, fmt.Sprintf("otpday:%x", h), 24*time.Hour, s.cfg.otpPerDay); err != nil {
		return nil, internal(err)
	} else if !ok {
		return nil, cerr(connect.CodeResourceExhausted, "rate_limited") // the hard cap on resends
	}
	review := s.cfg.reviewPhone != "" && phone == s.cfg.reviewPhone
	// ponytail: caps SMS count, not spend; switch to per-country cost once the provider is chosen (Q2, Q9).
	if review {
		// App store reviewers can't receive our SMS: their number has a fixed code instead.
	} else if ok, err := s.hit(ctx, "sms:global", 24*time.Hour, s.cfg.smsDailyCap); err != nil {
		return nil, internal(err)
	} else if !ok {
		slog.Error("global daily SMS cap reached")
		return nil, cerr(connect.CodeUnavailable, "sms_unavailable")
	}
	// A resend repeats the pending code, so whichever SMS arrives first works, and its guesses
	// carry on (ID-03). A code with no guesses left is replaced.
	code, sends := pending, sends+1
	if attempts >= s.cfg.otpAttempts {
		code = ""
	}
	if code == "" {
		n, _ := rand.Int(rand.Reader, big.NewInt(1_000_000))
		code, sends = fmt.Sprintf("%06d", n), 1
	}
	if review {
		code = s.cfg.reviewCode
	}
	if _, err := s.db.Exec(ctx, `INSERT INTO otps (phone_hmac, code, expires_at, sends, last_sent_at) VALUES ($1, $2, $3, $4, now())
		ON CONFLICT (phone_hmac) DO UPDATE SET code = $2, expires_at = $3, sends = $4, last_sent_at = now(),
		attempts = CASE WHEN otps.code = $2 THEN otps.attempts ELSE 0 END`,
		h, code, time.Now().Add(s.cfg.otpTTL), sends); err != nil {
		return nil, internal(err)
	}
	res := connect.NewResponse(&siegelv1.RequestOtpResponse{ResendAfterSeconds: uint32(s.resendWait(sends).Seconds())})
	if review {
		return res, nil
	}
	if err := s.sendSMS(ctx, phone, code); err != nil {
		return nil, internal(err)
	}
	s.count(ctx, "otp_sent")
	return res, nil
}

// resendWait is how long after the n-th SMS for a code the next may go: 30 s, 60 s, 120 s...
func (s *server) resendWait(sent int) time.Duration {
	return s.cfg.otpResendWait << min(max(sent-1, 0), 10)
}

func (s *server) Verify(ctx context.Context, req *connect.Request[siegelv1.VerifyRequest]) (*connect.Response[siegelv1.VerifyResponse], error) {
	m := req.Msg
	if !s.ipHits.allow("verify|"+peerIP(req.Peer()), s.cfg.verifyPerIP) {
		return nil, cerr(connect.CodeResourceExhausted, "rate_limited")
	}
	if len(m.IdentityPub) != ed25519.PublicKeySize {
		return nil, cerr(connect.CodeInvalidArgument, "identity_pub_invalid")
	}
	h, err := s.hmacPhone(ctx, m.PhoneE164)
	if err != nil {
		return nil, internal(err)
	}

	if err := s.checkOtp(ctx, h, m.Otp); err != nil {
		return nil, err
	}

	// Registration Lock (ID-10). Lapses once no device has been seen for lockLapseDay days.
	var (
		accountID   [16]byte
		lockHash    *string
		lockedUntil *time.Time
		lapsed      bool
	)
	err = s.db.QueryRow(ctx, `SELECT id, reg_lock_hash, reg_lock_locked_until,
		NOT EXISTS (SELECT 1 FROM devices d WHERE d.account_id = a.id AND d.last_seen_day > current_date - $2::int)
		FROM accounts a WHERE phone_hmac = $1`, h, s.cfg.lockLapseDay).Scan(&accountID, &lockHash, &lockedUntil, &lapsed)
	existing := err == nil
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, internal(err)
	}
	if existing && !lapsed {
		if err := s.checkLock(ctx, accountID, lockHash, lockedUntil, m.RegistrationLockPin); err != nil {
			return nil, err
		}
	}

	if !existing {
		accountID = newUUID()
	}
	asPub, err := s.asPublicKey(ctx)
	if err != nil {
		return nil, internal(err)
	}
	sig, err := s.signAS(ctx, append(append([]byte("siegel-as-v1"), accountID[:]...), m.IdentityPub...))
	if err != nil {
		return nil, internal(err)
	}
	deviceID := newUUID()
	token := rand.Text()
	tokenHash := sha256.Sum256([]byte(token))

	err = pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if existing {
			// ID-09: new identity key, every old device revoked. ponytail: queue, KeyPackages and push
			// token go with the device row via ON DELETE CASCADE once those tables exist (M2).
			// Open question: a lapsed lock is cleared so the new owner is not locked out by a PIN they never set.
			// Wake the old devices' open streams so they get `deregistered` now (ID-12).
			if _, err := tx.Exec(ctx, `SELECT pg_notify('queue', encode(uuid_send(device_id), 'hex'))
				FROM devices WHERE account_id = $1`, accountID); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `DELETE FROM devices WHERE account_id = $1`, accountID); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `UPDATE accounts SET identity_pub = $2, as_signature = $3, reg_lock_attempts = 0,
				reg_lock_hash = CASE WHEN $4 THEN NULL ELSE reg_lock_hash END WHERE id = $1`,
				accountID, m.IdentityPub, sig, lapsed)
			if err != nil {
				return err
			}
		} else if _, err := tx.Exec(ctx, `INSERT INTO accounts (id, phone_hmac, identity_pub, as_signature) VALUES ($1, $2, $3, $4)`,
			accountID, h, m.IdentityPub, sig); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO devices (account_id, device_id, token_hash, platform) VALUES ($1, $2, $3, $4)`,
			accountID, deviceID, tokenHash[:], int16(m.Platform)); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `DELETE FROM otps WHERE phone_hmac = $1`, h)
		return err
	})
	if err != nil {
		return nil, internal(err)
	}
	s.count(ctx, "otp_verified")
	// ID-09: a re-registered device learns what the account already has.
	var username string
	var locked bool
	if existing {
		_ = s.db.QueryRow(ctx, `SELECT coalesce((SELECT name FROM usernames WHERE account_id = $1 AND quarantined_until IS NULL), ''),
			reg_lock_hash IS NOT NULL FROM accounts WHERE id = $1`, accountID).Scan(&username, &locked)
	}
	return connect.NewResponse(&siegelv1.VerifyResponse{
		AccountId:        accountID[:],
		DeviceId:         deviceID[:],
		DeviceToken:      token,
		AsSignature:      sig,
		ExistingAccount:  existing,
		AsPublicKey:      asPub,
		Username:         username,
		RegistrationLock: locked,
	}), nil
}

// checkOtp spends one attempt on the pending code, so a code survives at most otpAttempts
// guesses (ID-03).
func (s *server) checkOtp(ctx context.Context, phoneHmac []byte, otp string) error {
	var code string
	err := s.db.QueryRow(ctx, `UPDATE otps SET attempts = attempts + 1
		WHERE phone_hmac = $1 AND expires_at > now() AND attempts < $2 RETURNING code`,
		phoneHmac, s.cfg.otpAttempts).Scan(&code)
	if errors.Is(err, pgx.ErrNoRows) || err == nil && subtle.ConstantTimeCompare([]byte(code), []byte(otp)) != 1 {
		return cerr(connect.CodePermissionDenied, "otp_invalid")
	} else if err != nil {
		return internal(err)
	}
	return nil
}

// checkLock enforces the Registration Lock PIN (ID-10), if the account has one. Wrong PINs
// count towards a lockout.
func (s *server) checkLock(ctx context.Context, acct [16]byte, hash *string, lockedUntil *time.Time, pin string) error {
	switch {
	case hash == nil:
		return nil
	case lockedUntil != nil && lockedUntil.After(time.Now()):
		return cerr(connect.CodePermissionDenied, "registration_lock_locked")
	case pin == "":
		return cerr(connect.CodePermissionDenied, "registration_lock_required")
	case !pinMatches(*hash, pin):
		if _, err := s.db.Exec(ctx, `UPDATE accounts SET
			reg_lock_attempts = CASE WHEN reg_lock_attempts + 1 >= $2 THEN 0 ELSE reg_lock_attempts + 1 END,
			reg_lock_locked_until = CASE WHEN reg_lock_attempts + 1 >= $2 THEN now() + $3 * interval '1 second' ELSE reg_lock_locked_until END
			WHERE id = $1`, acct, s.cfg.lockAttempts, int(s.cfg.lockLockout.Seconds())); err != nil {
			return internal(err)
		}
		return cerr(connect.CodePermissionDenied, "registration_lock_invalid")
	}
	return nil
}

// numberChangeEvery: a stolen session can't hop numbers to dodge the per-number limits.
const numberChangeEvery = 7 * 24 * time.Hour

// ChangeNumber moves the account to a proven new number (docs/change-number.md). Same account,
// keys and devices. Whoever proves a number by SMS gets it: an account still holding it keeps
// everything else and is told on its next connect.
func (s *server) ChangeNumber(ctx context.Context, req *connect.Request[siegelv1.ChangeNumberRequest]) (*connect.Response[siegelv1.ChangeNumberResponse], error) {
	m, me := req.Msg, account(ctx)
	if !s.ipHits.allow("verify|"+peerIP(req.Peer()), s.cfg.verifyPerIP) {
		return nil, cerr(connect.CodeResourceExhausted, "rate_limited")
	}
	if !e164.MatchString(m.PhoneE164) {
		return nil, cerr(connect.CodeInvalidArgument, "phone_invalid")
	}
	var (
		current     []byte
		lockHash    *string
		lockedUntil *time.Time
		changedAt   *time.Time
	)
	if err := s.db.QueryRow(ctx, `SELECT phone_hmac, reg_lock_hash, reg_lock_locked_until, number_changed_at
		FROM accounts WHERE id = $1`, me).Scan(&current, &lockHash, &lockedUntil, &changedAt); err != nil {
		return nil, internal(err)
	}
	if changedAt != nil && time.Since(*changedAt) < numberChangeEvery {
		return nil, cerr(connect.CodeFailedPrecondition, "number_change_too_soon")
	}
	h, err := s.hmacPhone(ctx, m.PhoneE164)
	if err != nil {
		return nil, internal(err)
	}
	if subtle.ConstantTimeCompare(current, h) == 1 {
		return nil, cerr(connect.CodeInvalidArgument, "number_same")
	}
	if err := s.checkOtp(ctx, h, m.Otp); err != nil {
		return nil, err
	}
	if err := s.checkLock(ctx, me, lockHash, lockedUntil, m.RegistrationLockPin); err != nil {
		return nil, err
	}
	err = pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		var other [16]byte
		err := tx.QueryRow(ctx, `UPDATE accounts SET phone_hmac = NULL, number_removed = true
			WHERE phone_hmac = $1 RETURNING id`, h).Scan(&other)
		if err == nil {
			// The number was recycled (or SIM-swapped): its old account stays, without it.
			if _, err := tx.Exec(ctx, `DELETE FROM discovery WHERE account_id = $1`, other); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `SELECT pg_notify('queue', encode(uuid_send(device_id), 'hex'))
				FROM devices WHERE account_id = $1`, other); err != nil {
				return err
			}
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		// Discovery listed the old number; the app opts in again with the new one.
		if _, err := tx.Exec(ctx, `DELETE FROM discovery WHERE account_id = $1`, me); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE accounts SET phone_hmac = $2, number_changed_at = now(),
			number_removed = false WHERE id = $1`, me, h); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `DELETE FROM otps WHERE phone_hmac = $1`, h)
		return err
	})
	if err != nil {
		return nil, internal(err)
	}
	s.count(ctx, "number_changed")
	return connect.NewResponse(&siegelv1.ChangeNumberResponse{}), nil
}

func (s *server) AppVersion(_ context.Context, req *connect.Request[siegelv1.AppVersionRequest]) (*connect.Response[siegelv1.AppVersionResponse], error) {
	res := &siegelv1.AppVersionResponse{}
	if req.Msg.Platform == siegelv1.Platform_PLATFORM_ANDROID {
		res.Latest, res.Minimum = uint32(s.cfg.androidLatest), uint32(s.cfg.androidMin)
	}
	return connect.NewResponse(res), nil
}
