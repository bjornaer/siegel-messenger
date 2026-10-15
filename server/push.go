package main

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"connectrpc.com/connect"
	"github.com/jackc/pgx/v5"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
)

// pushRepeat: after a wake-up, more queued messages don't push again until the device has
// connected, or this long has passed in case the push was lost (SRV-06).
const pushRepeat = 5 * time.Minute

// fcmBase is overridden in tests.
var fcmBase = "https://fcm.googleapis.com"

// errPushTokenGone: the push service no longer knows the token (app uninstalled).
var errPushTokenGone = errors.New("push token gone")

type pushes struct {
	mu   sync.Mutex
	sent map[[16]byte]time.Time
}

// connected resets collapsing: the next message after this connection pushes again.
func (p *pushes) connected(device [16]byte) {
	p.mu.Lock()
	delete(p.sent, device)
	p.mu.Unlock()
}

// due records a push for the device unless one went out recently.
func (p *pushes) due(device [16]byte, now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if t, ok := p.sent[device]; ok && now.Sub(t) < pushRepeat {
		return false
	}
	if p.sent == nil {
		p.sent = map[[16]byte]time.Time{}
	}
	p.sent[device] = now
	return true
}

// wakeDevice sends a content-free push (MSG-17) when the device has no live stream (SRV-06).
func (s *server) wakeDevice(device [16]byte) {
	if s.hub.online(device) || !s.pushes.due(device, time.Now()) {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		var token string
		var platform siegelv1.Platform
		err := s.db.QueryRow(ctx, `SELECT push_token, platform FROM devices
			WHERE device_id = $1 AND push_token IS NOT NULL`, device).Scan(&token, &platform)
		if errors.Is(err, pgx.ErrNoRows) {
			return
		} else if err != nil {
			slog.Error("push lookup", "err", err)
			return
		}
		err = s.sendPush(ctx, platform, token)
		if errors.Is(err, errPushTokenGone) {
			_, err = s.db.Exec(ctx, `UPDATE devices SET push_token = NULL WHERE device_id = $1 AND push_token = $2`, device, token)
		}
		if err != nil {
			slog.Warn("push", "err", err) // never the token
		} else {
			s.count(ctx, "push_sent")
		}
	}()
}

func (s *server) SetPushToken(ctx context.Context, req *connect.Request[siegelv1.SetPushTokenRequest]) (*connect.Response[siegelv1.SetPushTokenResponse], error) {
	t := req.Msg.PushToken
	if len(t) > 4096 {
		return nil, cerr(connect.CodeInvalidArgument, "push_token_invalid")
	}
	c := who(ctx)
	if _, err := s.db.Exec(ctx, `UPDATE devices SET push_token = NULLIF($3, '') WHERE account_id = $1 AND device_id = $2`,
		c.account, c.device, t); err != nil {
		return nil, internal(err)
	}
	return connect.NewResponse(&siegelv1.SetPushTokenResponse{}), nil
}

// fcm sends Android wake-ups through FCM HTTP v1 (SRV-05): a high-priority data message with
// no payload. credentials is a Google service account key with the Firebase Messaging role.
// ponytail: iOS (APNs) devices are skipped until the iOS app exists.
func fcm(credentials []byte) (func(context.Context, siegelv1.Platform, string) error, error) {
	var sa struct {
		ProjectID   string `json:"project_id"`
		ClientEmail string `json:"client_email"`
		PrivateKey  string `json:"private_key"`
		TokenURI    string `json:"token_uri"`
	}
	if err := json.Unmarshal(credentials, &sa); err != nil {
		return nil, err
	}
	block, _ := pem.Decode([]byte(sa.PrivateKey))
	if block == nil {
		return nil, errors.New("fcm: no private key")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := k.(*rsa.PrivateKey)
	if !ok || sa.ProjectID == "" || sa.ClientEmail == "" || sa.TokenURI == "" {
		return nil, errors.New("fcm: incomplete service account")
	}
	var (
		mu      sync.Mutex
		access  string
		expires time.Time
	)
	// OAuth 2.0 JWT bearer grant (RFC 7523), cached until shortly before it expires.
	bearer := func(ctx context.Context) (string, error) {
		mu.Lock()
		defer mu.Unlock()
		if time.Now().Before(expires) {
			return access, nil
		}
		now := time.Now()
		enc := base64.RawURLEncoding.EncodeToString
		head, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT"})
		claims, _ := json.Marshal(map[string]any{
			"iss": sa.ClientEmail, "aud": sa.TokenURI, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix(),
			"scope": "https://www.googleapis.com/auth/firebase.messaging",
		})
		unsigned := enc(head) + "." + enc(claims)
		sum := sha256.Sum256([]byte(unsigned))
		sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, sum[:])
		if err != nil {
			return "", err
		}
		form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {unsigned + "." + enc(sig)}}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, sa.TokenURI, strings.NewReader(form.Encode()))
		if err != nil {
			return "", err
		}
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		res, err := httpClient.Do(req)
		if err != nil {
			return "", err
		}
		defer res.Body.Close()
		var tok struct {
			AccessToken string `json:"access_token"`
			ExpiresIn   int    `json:"expires_in"`
		}
		if res.StatusCode != http.StatusOK {
			return "", fmt.Errorf("fcm oauth: status %d", res.StatusCode)
		}
		if err := json.NewDecoder(res.Body).Decode(&tok); err != nil {
			return "", err
		}
		access, expires = tok.AccessToken, now.Add(time.Duration(tok.ExpiresIn)*time.Second-time.Minute)
		return access, nil
	}
	send := fcmBase + "/v1/projects/" + sa.ProjectID + "/messages:send"
	return func(ctx context.Context, platform siegelv1.Platform, token string) error {
		if platform != siegelv1.Platform_PLATFORM_ANDROID {
			return nil
		}
		b, err := bearer(ctx)
		if err != nil {
			return err
		}
		msg := map[string]any{"message": map[string]any{"token": token, "android": map[string]any{"priority": "HIGH"}}}
		err = postJSON(ctx, send, http.Header{"Authorization": {"Bearer " + b}}, msg, nil)
		if se := new(statusError); errors.As(err, &se) && se.code == http.StatusNotFound {
			return errPushTokenGone // UNREGISTERED
		}
		return err
	}, nil
}
