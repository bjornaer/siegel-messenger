package main

// Phone-number discovery (DISC-03..07). The design is in docs/discovery.md: an OPRF over
// ristretto255 lets clients test their contacts' numbers without the server seeing them, and
// directory entries are encrypted to the OPRF output, so a downloaded bucket only opens for
// numbers the client already has.

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"sync"
	"time"

	"connectrpc.com/connect"
	"github.com/gtank/ristretto255"
	"github.com/jackc/pgx/v5"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
)

const discLabel = "siegel-disc-v1"

// discPoint is H(n): the number mapped to a ristretto255 point. Clients compute the same.
func discPoint(phone string) *ristretto255.Element {
	h := sha512.Sum512([]byte(discLabel + ":" + phone))
	e, _ := ristretto255.NewElement().SetUniformBytes(h[:])
	return e
}

// discOutput is O = SHA-256(label ‖ k·H(n)), what both sides derive the entry ID and key from.
func discOutput(evaluated *ristretto255.Element) []byte {
	h := sha256.Sum256(append([]byte(discLabel), evaluated.Bytes()...))
	return h[:]
}

func discEntry(o []byte, username string) *siegelv1.DirectoryEntry {
	id := sha256.Sum256(append([]byte("id"), o...))
	key := sha256.Sum256(append([]byte("key"), o...))
	block, _ := aes.NewCipher(key[:])
	gcm, _ := cipher.NewGCM(block)
	nonce := make([]byte, gcm.NonceSize())
	rand.Read(nonce)
	return &siegelv1.DirectoryEntry{Id: id[:16], Box: gcm.Seal(nonce, nonce, []byte(username), nil)}
}

func bucketOf(id []byte, bits uint32) uint32 {
	if bits == 0 {
		return 0
	}
	return binary.BigEndian.Uint32(id[:4]) >> (32 - bits)
}

// bucketBits: as many bits as keep every bucket at minBucket entries or more on average.
func bucketBits(n, minBucket int) uint32 {
	var b uint32
	for b < 16 && n>>(b+1) >= minBucket {
		b++
	}
	return b
}

// discKeys derives OPRF scalars from the phone pepper, which never leaves OpenBao. The labels
// can't collide with the E.164 numbers the pepper otherwise hashes (those start with "+").
type discKeys struct {
	derive func(ctx context.Context, label string) ([]byte, error) // 64 bytes
	mu     sync.Mutex
	cache  map[string]*ristretto255.Scalar
}

func (d *discKeys) scalar(ctx context.Context, label string) (*ristretto255.Scalar, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if s, ok := d.cache[label]; ok {
		return s, nil
	}
	b, err := d.derive(ctx, discLabel+":"+label)
	if err != nil {
		return nil, err
	}
	s, err := ristretto255.NewScalar().SetUniformBytes(b)
	if err != nil {
		return nil, err
	}
	if d.cache == nil {
		d.cache = map[string]*ristretto255.Scalar{}
	}
	d.cache[label] = s
	return s, nil
}

type discovery struct{ *server }

func (s *server) discPeriod(now time.Time) int64 {
	return now.Unix() / int64(s.cfg.discPeriod/time.Second)
}

func (s discovery) SetDiscoverable(ctx context.Context, req *connect.Request[siegelv1.DiscoveryServiceSetDiscoverableRequest]) (*connect.Response[siegelv1.DiscoveryServiceSetDiscoverableResponse], error) {
	acct := account(ctx)
	phone := req.Msg.PhoneE164
	if phone == "" {
		if _, err := s.db.Exec(ctx, `DELETE FROM discovery WHERE account_id = $1`, acct); err != nil {
			return nil, internal(err)
		}
		return connect.NewResponse(&siegelv1.DiscoveryServiceSetDiscoverableResponse{}), nil
	}
	if !e164.MatchString(phone) {
		return nil, cerr(connect.CodeInvalidArgument, "phone_invalid")
	}
	// Only our own number: it must hash to the account's (ID-05). Nobody can list someone else's.
	h, err := s.hmacPhone(ctx, phone)
	if err != nil {
		return nil, internal(err)
	}
	var stored []byte
	if err := s.db.QueryRow(ctx, `SELECT phone_hmac FROM accounts WHERE id = $1`, acct).Scan(&stored); err != nil {
		return nil, internal(err)
	}
	if subtle.ConstantTimeCompare(stored, h) != 1 {
		return nil, cerr(connect.CodePermissionDenied, "phone_mismatch")
	}
	m, err := s.disc.scalar(ctx, "master")
	if err != nil {
		return nil, internal(err)
	}
	y := ristretto255.NewElement().ScalarMult(m, discPoint(phone)) // keyed, like the HMAC; never the number
	if _, err := s.db.Exec(ctx, `INSERT INTO discovery (account_id, y) VALUES ($1, $2)
		ON CONFLICT (account_id) DO UPDATE SET y = $2`, acct, y.Bytes()); err != nil {
		return nil, internal(err)
	}
	return connect.NewResponse(&siegelv1.DiscoveryServiceSetDiscoverableResponse{}), nil
}

func (s discovery) GetDiscoverable(ctx context.Context, _ *connect.Request[siegelv1.DiscoveryServiceGetDiscoverableRequest]) (*connect.Response[siegelv1.DiscoveryServiceGetDiscoverableResponse], error) {
	var on bool
	if err := s.db.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM discovery WHERE account_id = $1)`, account(ctx)).Scan(&on); err != nil {
		return nil, internal(err)
	}
	return connect.NewResponse(&siegelv1.DiscoveryServiceGetDiscoverableResponse{On: on}), nil
}

// discHolds: does proof equal the account's discovery output O this key period (or the last
// one, around a rotation)? Only someone who evaluated their number gets O (M7).
func (s *server) discHolds(ctx context.Context, acct [16]byte, proof []byte) (bool, error) {
	if len(proof) != sha256.Size {
		return false, nil
	}
	var yb []byte
	err := s.db.QueryRow(ctx, `SELECT y FROM discovery WHERE account_id = $1`, acct).Scan(&yb)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	} else if err != nil {
		return false, err
	}
	y, err := ristretto255.NewElement().SetCanonicalBytes(yb)
	if err != nil {
		return false, nil
	}
	m, err := s.disc.scalar(ctx, "master")
	if err != nil {
		return false, err
	}
	now := s.discPeriod(time.Now())
	for _, p := range []int64{now, now - 1} {
		k, err := s.disc.scalar(ctx, fmt.Sprint("period:", p))
		if err != nil {
			return false, err
		}
		shift := ristretto255.NewScalar().Multiply(k, ristretto255.NewScalar().Invert(m))
		if subtle.ConstantTimeCompare(discOutput(ristretto255.NewElement().ScalarMult(shift, y)), proof) == 1 {
			return true, nil
		}
	}
	return false, nil
}

// discQuota is DISC-06: a first-sync allowance per key period, then a daily one.
func (s *server) discQuota(ctx context.Context, acct [16]byte, n int) (bool, error) {
	a := hex.EncodeToString(acct[:])
	now := time.Now().UTC()
	periodStart := time.Unix(s.discPeriod(now)*int64(s.cfg.discPeriod/time.Second), 0).UTC()
	day := now.Truncate(24 * time.Hour)
	count := func(key string, window time.Time) (c int, err error) {
		err = s.db.QueryRow(ctx, `SELECT count FROM rate_limits WHERE key = $1 AND window_start = $2`, key, window).Scan(&c)
		if errors.Is(err, pgx.ErrNoRows) {
			err = nil
		}
		return
	}
	add := func(key string, window time.Time) error {
		_, err := s.db.Exec(ctx, `INSERT INTO rate_limits VALUES ($1, $2, $3)
			ON CONFLICT (key, window_start) DO UPDATE SET count = rate_limits.count + $3`, key, window, n)
		return err
	}
	pk, dk := "disc_period:"+a, "disc_day:"+a
	used, err := count(pk, periodStart)
	if err != nil {
		return false, err
	}
	if used+n <= s.cfg.discInitial {
		return true, add(pk, periodStart)
	}
	used, err = count(dk, day)
	if err != nil {
		return false, err
	}
	if used+n <= s.cfg.discDaily {
		return true, add(dk, day)
	}
	return false, nil
}

func (s discovery) Evaluate(ctx context.Context, req *connect.Request[siegelv1.DiscoveryServiceEvaluateRequest]) (*connect.Response[siegelv1.DiscoveryServiceEvaluateResponse], error) {
	in := req.Msg.Blinded
	if len(in) == 0 || len(in) > s.cfg.discInitial {
		return nil, cerr(connect.CodeInvalidArgument, "discovery_invalid")
	}
	points := make([]*ristretto255.Element, len(in))
	for i, b := range in {
		p, err := ristretto255.NewElement().SetCanonicalBytes(b)
		if err != nil {
			return nil, cerr(connect.CodeInvalidArgument, "discovery_invalid")
		}
		points[i] = p
	}
	if ok, err := s.discQuota(ctx, account(ctx), len(in)); err != nil {
		return nil, internal(err)
	} else if !ok {
		return nil, cerr(connect.CodeResourceExhausted, "rate_limited")
	}
	period := s.discPeriod(time.Now())
	k, err := s.disc.scalar(ctx, fmt.Sprint("period:", period))
	if err != nil {
		return nil, internal(err)
	}
	var n int // counted like Buckets lists them, so both agree on the bucket size
	if err := s.db.QueryRow(ctx, `SELECT count(*) FROM discovery d
		JOIN usernames u ON u.account_id = d.account_id AND u.quarantined_until IS NULL`).Scan(&n); err != nil {
		return nil, internal(err)
	}
	res := &siegelv1.DiscoveryServiceEvaluateResponse{Period: period, BucketBits: bucketBits(n, s.cfg.discBucketMin)}
	for _, p := range points {
		res.Evaluated = append(res.Evaluated, ristretto255.NewElement().ScalarMult(k, p).Bytes())
	}
	return connect.NewResponse(res), nil
}

// Buckets serves whole buckets: the server learns which buckets, never which entry (DISC-05.5).
// ponytail: rebuilds the directory on every call; cache it per period once there are thousands.
func (s discovery) Buckets(ctx context.Context, req *connect.Request[siegelv1.DiscoveryServiceBucketsRequest]) (*connect.Response[siegelv1.DiscoveryServiceBucketsResponse], error) {
	period := s.discPeriod(time.Now())
	if req.Msg.Period != period {
		return nil, cerr(connect.CodeFailedPrecondition, "period_changed")
	}
	if len(req.Msg.Buckets) > 1<<10 {
		return nil, cerr(connect.CodeInvalidArgument, "discovery_invalid")
	}
	want := map[uint32]bool{}
	for _, b := range req.Msg.Buckets {
		want[b] = true
	}
	m, err := s.disc.scalar(ctx, "master")
	if err != nil {
		return nil, internal(err)
	}
	k, err := s.disc.scalar(ctx, fmt.Sprint("period:", period))
	if err != nil {
		return nil, internal(err)
	}
	// k·m⁻¹·Y = k·H(n): today's evaluation of each number, without the number.
	shift := ristretto255.NewScalar().Multiply(k, ristretto255.NewScalar().Invert(m))
	rows, err := s.db.Query(ctx, `SELECT d.y, u.name FROM discovery d
		JOIN usernames u ON u.account_id = d.account_id AND u.quarantined_until IS NULL`)
	if err != nil {
		return nil, internal(err)
	}
	type row struct {
		Y    []byte
		Name string
	}
	all, err := pgx.CollectRows(rows, pgx.RowToStructByPos[row])
	if err != nil {
		return nil, internal(err)
	}
	bits := bucketBits(len(all), s.cfg.discBucketMin)
	res := &siegelv1.DiscoveryServiceBucketsResponse{}
	for _, r := range all {
		y, err := ristretto255.NewElement().SetCanonicalBytes(r.Y)
		if err != nil {
			continue
		}
		e := discEntry(discOutput(ristretto255.NewElement().ScalarMult(shift, y)), r.Name)
		if want[bucketOf(e.Id, bits)] {
			res.Entries = append(res.Entries, e)
		}
	}
	return connect.NewResponse(res), nil
}
