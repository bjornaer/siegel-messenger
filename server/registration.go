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
	attest    func(ctx context.Context, token string) error
	sendSMS   func(ctx context.Context, phone, code string) error
	hmacPhone func(ctx context.Context, phone string) ([]byte, error)
	signAS    func(ctx context.Context, msg []byte) ([]byte, error)
	hub       *hub

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
	if err := s.attest(ctx, req.Msg.AttestationToken); err != nil {
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
	if ok, err := s.hit(ctx, fmt.Sprintf("otp:%x", h), time.Hour, s.cfg.otpPerNumber); err != nil {
		return nil, internal(err)
	} else if !ok {
		return nil, cerr(connect.CodeResourceExhausted, "rate_limited")
	}
	// ponytail: caps SMS count, not spend; switch to per-country cost once the provider is chosen (Q2, Q9).
	if ok, err := s.hit(ctx, "sms:global", 24*time.Hour, s.cfg.smsDailyCap); err != nil {
		return nil, internal(err)
	} else if !ok {
		slog.Error("global daily SMS cap reached")
		return nil, cerr(connect.CodeUnavailable, "sms_unavailable")
	}
	n, _ := rand.Int(rand.Reader, big.NewInt(1_000_000))
	code := fmt.Sprintf("%06d", n)
	if _, err := s.db.Exec(ctx, `INSERT INTO otps (phone_hmac, code, expires_at) VALUES ($1, $2, $3)
		ON CONFLICT (phone_hmac) DO UPDATE SET code = $2, attempts = 0, expires_at = $3`,
		h, code, time.Now().Add(s.cfg.otpTTL)); err != nil {
		return nil, internal(err)
	}
	if err := s.sendSMS(ctx, phone, code); err != nil {
		return nil, internal(err)
	}
	s.count(ctx, "otp_sent")
	return connect.NewResponse(&siegelv1.RequestOtpResponse{}), nil
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

	// Every call spends one attempt, so a code survives at most otpAttempts guesses (ID-03).
	var code string
	err = s.db.QueryRow(ctx, `UPDATE otps SET attempts = attempts + 1
		WHERE phone_hmac = $1 AND expires_at > now() AND attempts < $2 RETURNING code`,
		h, s.cfg.otpAttempts).Scan(&code)
	if errors.Is(err, pgx.ErrNoRows) || err == nil && subtle.ConstantTimeCompare([]byte(code), []byte(m.Otp)) != 1 {
		return nil, cerr(connect.CodePermissionDenied, "otp_invalid")
	} else if err != nil {
		return nil, internal(err)
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
	if existing && lockHash != nil && !lapsed {
		switch {
		case lockedUntil != nil && lockedUntil.After(time.Now()):
			return nil, cerr(connect.CodePermissionDenied, "registration_lock_locked")
		case m.RegistrationLockPin == "":
			return nil, cerr(connect.CodePermissionDenied, "registration_lock_required")
		case !pinMatches(*lockHash, m.RegistrationLockPin):
			if _, err := s.db.Exec(ctx, `UPDATE accounts SET
				reg_lock_attempts = CASE WHEN reg_lock_attempts + 1 >= $2 THEN 0 ELSE reg_lock_attempts + 1 END,
				reg_lock_locked_until = CASE WHEN reg_lock_attempts + 1 >= $2 THEN now() + $3 * interval '1 second' ELSE reg_lock_locked_until END
				WHERE id = $1`, accountID, s.cfg.lockAttempts, int(s.cfg.lockLockout.Seconds())); err != nil {
				return nil, internal(err)
			}
			return nil, cerr(connect.CodePermissionDenied, "registration_lock_invalid")
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
	return connect.NewResponse(&siegelv1.VerifyResponse{
		AccountId:       accountID[:],
		DeviceId:        deviceID[:],
		DeviceToken:     token,
		AsSignature:     sig,
		ExistingAccount: existing,
		AsPublicKey:     asPub,
	}), nil
}
