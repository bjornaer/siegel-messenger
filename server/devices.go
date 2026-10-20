package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"strings"
	"time"
	"unicode/utf8"

	"connectrpc.com/connect"
	"github.com/jackc/pgx/v5"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
)

// M8 part 1: linked devices. The registered device is primary: it adds and removes up to
// maxLinked others, which act as the same account with their own MLS keys.
const (
	maxLinked = 4
	linkTTL   = 5 * time.Minute
)

func (s *server) primary(ctx context.Context) error {
	var linked bool
	c := who(ctx)
	if err := s.db.QueryRow(ctx, `SELECT linked FROM devices WHERE account_id = $1 AND device_id = $2`, c.account, c.device).Scan(&linked); err != nil {
		return internal(err)
	} else if linked {
		return cerr(connect.CodePermissionDenied, "primary_only")
	}
	return nil
}

func (s *server) ListDevices(ctx context.Context, _ *connect.Request[siegelv1.ListDevicesRequest]) (*connect.Response[siegelv1.ListDevicesResponse], error) {
	c := who(ctx)
	r, err := s.exportData(ctx, c.account, c.device)
	if err != nil {
		return nil, internal(err)
	}
	return connect.NewResponse(&siegelv1.ListDevicesResponse{Devices: r.Devices}), nil
}

func (s *server) AddDevice(ctx context.Context, req *connect.Request[siegelv1.AddDeviceRequest]) (*connect.Response[siegelv1.AddDeviceResponse], error) {
	if err := s.primary(ctx); err != nil {
		return nil, err
	}
	name := strings.TrimSpace(req.Msg.Name)
	if name == "" || utf8.RuneCountInString(name) > 64 {
		return nil, cerr(connect.CodeInvalidArgument, "name_invalid")
	}
	acct := account(ctx)
	deviceID, token := newUUID(), rand.Text()
	hash := sha256.Sum256([]byte(token))
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		var n int
		// The account row serialises concurrent links, so the limit holds.
		if _, err := tx.Exec(ctx, `SELECT 1 FROM accounts WHERE id = $1 FOR UPDATE`, acct); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM devices WHERE account_id = $1 AND linked`, acct).Scan(&n); err != nil {
			return err
		} else if n >= maxLinked {
			return cerr(connect.CodeResourceExhausted, "too_many_devices")
		}
		_, err := tx.Exec(ctx, `INSERT INTO devices (account_id, device_id, token_hash, platform, name, linked) VALUES ($1, $2, $3, $4, $5, true)`,
			acct, deviceID, hash[:], int16(req.Msg.Platform), name)
		return err
	})
	var ce *connect.Error
	if errors.As(err, &ce) {
		return nil, err
	} else if err != nil {
		return nil, internal(err)
	}
	return connect.NewResponse(&siegelv1.AddDeviceResponse{DeviceId: deviceID[:], DeviceToken: token}), nil
}

func (s *server) RemoveDevice(ctx context.Context, req *connect.Request[siegelv1.RemoveDeviceRequest]) (*connect.Response[siegelv1.RemoveDeviceResponse], error) {
	if err := s.primary(ctx); err != nil {
		return nil, err
	}
	id, ok := uuid(req.Msg.DeviceId)
	if !ok {
		return nil, cerr(connect.CodeInvalidArgument, "device_invalid")
	}
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		// Its open stream notices the device is gone and tells it it was deregistered (ID-12).
		if _, err := tx.Exec(ctx, `SELECT pg_notify('queue', encode(uuid_send($1::uuid), 'hex'))`, id); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `DELETE FROM devices WHERE account_id = $1 AND device_id = $2 AND linked`, account(ctx), id)
		if err == nil && tag.RowsAffected() == 0 {
			return cerr(connect.CodeNotFound, "device_not_found")
		}
		return err
	})
	var ce *connect.Error
	if errors.As(err, &ce) {
		return nil, err
	} else if err != nil {
		return nil, internal(err)
	}
	return connect.NewResponse(&siegelv1.RemoveDeviceResponse{}), nil
}

type links struct{ *server }

func (s links) Begin(ctx context.Context, req *connect.Request[siegelv1.LinkServiceBeginRequest]) (*connect.Response[siegelv1.LinkServiceBeginResponse], error) {
	if !strings.HasPrefix(req.Msg.AgeRecipient, "age1") || len(req.Msg.AgeRecipient) > 100 {
		return nil, cerr(connect.CodeInvalidArgument, "link_invalid")
	}
	if !s.ipHits.allow("link|"+peerIP(req.Peer()), s.cfg.verifyPerIP) {
		return nil, cerr(connect.CodeResourceExhausted, "rate_limited")
	}
	id := make([]byte, 16)
	rand.Read(id)
	if _, err := s.db.Exec(ctx, `INSERT INTO device_links (id, recipient, expires_at) VALUES ($1, $2, $3)`,
		id, req.Msg.AgeRecipient, time.Now().Add(linkTTL)); err != nil {
		return nil, internal(err)
	}
	return connect.NewResponse(&siegelv1.LinkServiceBeginResponse{LinkId: id}), nil
}

func (s links) Complete(ctx context.Context, req *connect.Request[siegelv1.LinkServiceCompleteRequest]) (*connect.Response[siegelv1.LinkServiceCompleteResponse], error) {
	if err := s.primary(ctx); err != nil {
		return nil, err
	}
	tag, err := s.db.Exec(ctx, `UPDATE device_links SET sealed = $2 WHERE id = $1 AND sealed IS NULL AND expires_at > now()`,
		req.Msg.LinkId, req.Msg.Sealed)
	if err != nil {
		return nil, internal(err)
	} else if tag.RowsAffected() == 0 {
		return nil, cerr(connect.CodeNotFound, "link_expired")
	}
	return connect.NewResponse(&siegelv1.LinkServiceCompleteResponse{}), nil
}

func (s links) Collect(ctx context.Context, req *connect.Request[siegelv1.LinkServiceCollectRequest]) (*connect.Response[siegelv1.LinkServiceCollectResponse], error) {
	var sealed []byte
	err := s.db.QueryRow(ctx, `DELETE FROM device_links WHERE id = $1 AND sealed IS NOT NULL RETURNING sealed`, req.Msg.LinkId).Scan(&sealed)
	if errors.Is(err, pgx.ErrNoRows) {
		var waiting bool
		if s.db.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM device_links WHERE id = $1 AND expires_at > now())`, req.Msg.LinkId).Scan(&waiting); !waiting {
			return nil, cerr(connect.CodeNotFound, "link_expired")
		}
		return connect.NewResponse(&siegelv1.LinkServiceCollectResponse{}), nil // not approved yet: ask again
	} else if err != nil {
		return nil, internal(err)
	}
	return connect.NewResponse(&siegelv1.LinkServiceCollectResponse{Sealed: sealed}), nil
}
