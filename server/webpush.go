package main

import (
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"net/url"
	"strings"
	"time"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
)

// M8 part 6: Web Push for the web app while its tab is closed. Like the phone's (MSG-17) the
// push carries nothing: no payload, so nothing to encrypt; the browser's service worker only
// says a message is waiting. Requests are signed with our VAPID key (RFC 8292).

// pushServices are the browsers' push services. A subscription naming any other host is
// refused, so a device can't make this server call an address of its choosing.
var pushServices = []string{
	"fcm.googleapis.com",                // Chrome, Edge, Opera
	"updates.push.services.mozilla.com", // Firefox
	"web.push.apple.com",                // Safari
	".notify.windows.com",               // Edge (legacy WNS)
}

// webSubscription is what the browser's PushManager hands out (PushSubscription.toJSON).
type webSubscription struct {
	Endpoint string `json:"endpoint"`
}

// webPushEndpoint checks a stored web push token and returns its endpoint.
func webPushEndpoint(token string) (*url.URL, error) {
	var sub webSubscription
	if err := json.Unmarshal([]byte(token), &sub); err != nil {
		return nil, errors.New("not a subscription")
	}
	u, err := url.Parse(sub.Endpoint)
	if err != nil || u.Scheme != "https" || u.User != nil || u.Port() != "" {
		return nil, errors.New("bad endpoint")
	}
	host := strings.ToLower(u.Hostname())
	for _, p := range pushServices {
		if host == p || strings.HasPrefix(p, ".") && strings.HasSuffix(host, p) {
			return u, nil
		}
	}
	return nil, errors.New("not a known push service")
}

type vapid struct {
	key     *ecdsa.PrivateKey
	public  string // uncompressed point, base64url: the browser's applicationServerKey
	subject string
}

// newVapid reads SIEGEL_VAPID_KEY: the P-256 private scalar, base64url (`siegel-admin vapid-keygen`).
func newVapid(b64, subject string) (*vapid, error) {
	d, err := base64.RawURLEncoding.DecodeString(b64)
	if err != nil {
		return nil, err
	}
	ek, err := ecdh.P256().NewPrivateKey(d)
	if err != nil {
		return nil, err
	}
	pub := ek.PublicKey().Bytes()
	key := &ecdsa.PrivateKey{D: new(big.Int).SetBytes(d)}
	key.Curve = elliptic.P256()
	key.X, key.Y = new(big.Int).SetBytes(pub[1:33]), new(big.Int).SetBytes(pub[33:])
	return &vapid{key: key, public: base64.RawURLEncoding.EncodeToString(pub), subject: subject}, nil
}

// vapidKeygen makes a new key for SIEGEL_VAPID_KEY.
func vapidKeygen() (string, error) {
	k, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(k.Bytes()), nil
}

// jwt is the VAPID token for one push service (aud), valid 12 hours.
func (v *vapid) jwt(aud string, now time.Time) (string, error) {
	enc := base64.RawURLEncoding
	head := enc.EncodeToString([]byte(`{"typ":"JWT","alg":"ES256"}`))
	claims, _ := json.Marshal(map[string]any{"aud": aud, "exp": now.Add(12 * time.Hour).Unix(), "sub": v.subject})
	signing := head + "." + enc.EncodeToString(claims)
	h := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, v.key, h[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signing + "." + enc.EncodeToString(sig), nil
}

// webPushOr sends web devices' pushes itself and hands the others to next.
func (v *vapid) webPushOr(next func(context.Context, siegelv1.Platform, string) error) func(context.Context, siegelv1.Platform, string) error {
	return func(ctx context.Context, platform siegelv1.Platform, token string) error {
		if platform != siegelv1.Platform_PLATFORM_WEB {
			return next(ctx, platform, token)
		}
		u, err := webPushEndpoint(token)
		if err != nil {
			return errPushTokenGone
		}
		t, err := v.jwt(u.Scheme+"://"+u.Host, time.Now())
		if err != nil {
			return err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), nil)
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "vapid t="+t+", k="+v.public)
		req.Header.Set("TTL", "86400")
		req.Header.Set("Urgency", "high")
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			return err
		}
		res.Body.Close()
		switch {
		case res.StatusCode == http.StatusNotFound || res.StatusCode == http.StatusGone:
			return errPushTokenGone // unsubscribed, or the browser data was cleared
		case res.StatusCode >= 300:
			return fmt.Errorf("web push: %d", res.StatusCode)
		}
		return nil
	}
}

// vapidKey serves GET /v1/push/vapid: the public key the web app subscribes with.
func (s *server) vapidKey(w http.ResponseWriter, r *http.Request) {
	if s.vapid == nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/plain")
	w.Write([]byte(s.vapid.public))
}
