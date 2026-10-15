package main

import (
	"context"
	"encoding/hex"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5"
	"google.golang.org/protobuf/proto"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
)

// hub wakes this instance's open streams when their device's queue changes (SRV-03).
type hub struct {
	mu   sync.Mutex
	subs map[[16]byte]map[chan struct{}]struct{}
}

func newHub() *hub { return &hub{subs: map[[16]byte]map[chan struct{}]struct{}{}} }

func (h *hub) sub(device [16]byte) (chan struct{}, func()) {
	ch := make(chan struct{}, 1)
	h.mu.Lock()
	if h.subs[device] == nil {
		h.subs[device] = map[chan struct{}]struct{}{}
	}
	h.subs[device][ch] = struct{}{}
	h.mu.Unlock()
	return ch, func() {
		h.mu.Lock()
		delete(h.subs[device], ch)
		if len(h.subs[device]) == 0 {
			delete(h.subs, device)
		}
		h.mu.Unlock()
	}
}

// wake signals one device's streams, or every stream when all is true.
func (h *hub) wake(device [16]byte, all bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for d, chans := range h.subs {
		if all || d == device {
			for ch := range chans {
				select {
				case ch <- struct{}{}:
				default: // already pending
				}
			}
		}
	}
}

// online reports whether this instance holds a stream for the device (push decision, SRV-06).
// ponytail: per-instance only; with several instances, share presence through PostgreSQL.
func (h *hub) online(device [16]byte) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.subs[device]) > 0
}

// listen turns PostgreSQL NOTIFY 'queue' (device ID in hex) into hub wake-ups, reconnecting forever.
func (s *server) listen(ctx context.Context) {
	for ctx.Err() == nil {
		err := func() error {
			conn, err := s.db.Acquire(ctx)
			if err != nil {
				return err
			}
			defer conn.Release()
			if _, err := conn.Exec(ctx, "LISTEN queue"); err != nil {
				return err
			}
			s.hub.wake([16]byte{}, true) // notifications may have been missed while disconnected
			for {
				n, err := conn.Conn().WaitForNotification(ctx)
				if err != nil {
					return err
				}
				var d [16]byte
				if b, err := hex.DecodeString(n.Payload); err == nil && len(b) == 16 {
					copy(d[:], b)
					s.hub.wake(d, false)
					s.wakeDevice(d)
				}
			}
		}()
		slog.Error("queue listener", "err", err)
		time.Sleep(time.Second)
	}
}

// stream serves WS /v1/stream: queued messages out, acknowledgements in (SRV-03).
func (s *server) stream(w http.ResponseWriter, r *http.Request) {
	c, found, err := s.authenticate(r.Context(), r.Header.Get("Authorization"))
	if err != nil {
		slog.Error("stream auth", "err", err)
		http.Error(w, "internal", http.StatusInternalServerError)
		return
	}
	if !found && r.Header.Get("Authorization") == "" {
		http.Error(w, "unauthenticated", http.StatusUnauthorized)
		return
	}
	// The server's 30 s read/write timeouts are for unary calls; a stream lives for hours.
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Time{})
	_ = rc.SetWriteDeadline(time.Time{})
	ws, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	defer ws.CloseNow()
	ws.SetReadLimit(64 << 10)
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	send := func(f *siegelv1.StreamFrame) error {
		b, err := proto.Marshal(f)
		if err != nil {
			return err
		}
		wctx, done := context.WithTimeout(ctx, 30*time.Second)
		defer done()
		return ws.Write(wctx, websocket.MessageBinary, b)
	}
	deregistered := func() {
		_ = send(&siegelv1.StreamFrame{Kind: &siegelv1.StreamFrame_Deregistered{Deregistered: &siegelv1.Deregistered{}}})
		ws.Close(websocket.StatusPolicyViolation, "deregistered")
	}
	if !found {
		deregistered() // ID-12: the token's device was revoked or the account deleted
		return
	}

	wake, unsub := s.hub.sub(c.device)
	defer func() {
		unsub()
		// Messages that came in while this connection was already dead (pings find out within
		// 40 s) were never delivered and got no push: wake the device now (SRV-06).
		var pending bool
		if s.db.QueryRow(context.Background(), `SELECT EXISTS (SELECT 1 FROM queue WHERE account_id = $1 AND device_id = $2)`,
			c.account, c.device).Scan(&pending) == nil && pending {
			s.wakeDevice(c.device)
		}
	}()
	s.pushes.connected(c.device)
	go func() { // acknowledgements delete delivered messages
		defer cancel()
		for {
			_, b, err := ws.Read(ctx)
			if err != nil {
				return
			}
			var ack siegelv1.StreamAck
			if proto.Unmarshal(b, &ack) != nil {
				return
			}
			if _, err := s.db.Exec(ctx, `DELETE FROM queue WHERE account_id = $1 AND device_id = $2 AND id = ANY($3)`,
				c.account, c.device, ack.Ids); err != nil {
				slog.Error("stream ack", "err", err)
				return
			}
		}
	}()

	ping := time.NewTicker(30 * time.Second)
	defer ping.Stop()
	var last int64 // unacknowledged messages are resent on the next connection; clients dedupe (MSG-03)
	for {
		var exists bool
		if err := s.db.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM devices WHERE account_id = $1 AND device_id = $2)`,
			c.account, c.device).Scan(&exists); err != nil {
			return
		}
		if !exists {
			deregistered()
			return
		}
		rows, err := s.db.Query(ctx, `SELECT id, payload FROM queue WHERE account_id = $1 AND device_id = $2 AND id > $3
			ORDER BY id LIMIT 100`, c.account, c.device, last)
		if err != nil {
			return
		}
		msgs, err := pgx.CollectRows(rows, pgx.RowToStructByPos[struct {
			ID      int64
			Payload []byte
		}])
		if err != nil {
			return
		}
		for _, m := range msgs {
			if send(&siegelv1.StreamFrame{Kind: &siegelv1.StreamFrame_Message{Message: &siegelv1.QueuedMessage{Id: m.ID, Payload: m.Payload}}}) != nil {
				return
			}
			last = m.ID
		}
		if len(msgs) == 100 {
			continue
		}
		select {
		case <-wake:
		case <-ping.C:
			pctx, done := context.WithTimeout(ctx, 10*time.Second)
			err := ws.Ping(pctx)
			done()
			if err != nil {
				return
			}
		case <-ctx.Done():
			return
		}
	}
}
