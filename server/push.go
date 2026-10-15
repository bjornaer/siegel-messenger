package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
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
// no payload. ponytail: iOS (APNs) devices are skipped until the iOS app exists.
func fcm(g *googleAccount) func(context.Context, siegelv1.Platform, string) error {
	send := fcmBase + "/v1/projects/" + g.project + "/messages:send"
	return func(ctx context.Context, platform siegelv1.Platform, token string) error {
		if platform != siegelv1.Platform_PLATFORM_ANDROID {
			return nil
		}
		b, err := g.bearer(ctx)
		if err != nil {
			return err
		}
		msg := map[string]any{"message": map[string]any{"token": token, "android": map[string]any{"priority": "HIGH"}}}
		err = postJSON(ctx, send, http.Header{"Authorization": {"Bearer " + b}}, msg, nil)
		if se := new(statusError); errors.As(err, &se) && se.code == http.StatusNotFound {
			return errPushTokenGone // UNREGISTERED
		}
		return err
	}
}
