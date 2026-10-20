package main

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"connectrpc.com/connect"
	"github.com/jackc/pgx/v5"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
)

const (
	maxKeyPackagesPerDevice = 500  // storage cap per device; clients keep ~100 (CRY-09)
	maxRecipients           = 1024 // 256 members (D4) with room for multi-device later (D2)
)

func (s *server) Upload(ctx context.Context, req *connect.Request[siegelv1.KeysServiceUploadRequest]) (*connect.Response[siegelv1.KeysServiceUploadResponse], error) {
	c := who(ctx)
	var remaining uint32
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if req.Msg.Replace {
			if _, err := tx.Exec(ctx, `DELETE FROM key_packages WHERE account_id = $1 AND device_id = $2 AND NOT last_resort`,
				c.account, c.device); err != nil {
				return err
			}
		}
		for _, kp := range req.Msg.KeyPackages {
			if _, err := tx.Exec(ctx, `INSERT INTO key_packages (account_id, device_id, data) VALUES ($1, $2, $3)`,
				c.account, c.device, kp); err != nil {
				return err
			}
		}
		if lr := req.Msg.LastResort; len(lr) > 0 {
			if _, err := tx.Exec(ctx, `DELETE FROM key_packages WHERE account_id = $1 AND device_id = $2 AND last_resort`,
				c.account, c.device); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `INSERT INTO key_packages (account_id, device_id, data, last_resort) VALUES ($1, $2, $3, true)`,
				c.account, c.device, lr); err != nil {
				return err
			}
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM key_packages WHERE account_id = $1 AND device_id = $2 AND NOT last_resort`,
			c.account, c.device).Scan(&remaining); err != nil {
			return err
		}
		if remaining > maxKeyPackagesPerDevice {
			return cerr(connect.CodeInvalidArgument, "too_many_key_packages")
		}
		return nil
	})
	if err != nil {
		return nil, txErr(err)
	}
	return connect.NewResponse(&siegelv1.KeysServiceUploadResponse{Remaining: remaining}), nil
}

func (s *server) Claim(ctx context.Context, req *connect.Request[siegelv1.KeysServiceClaimRequest]) (*connect.Response[siegelv1.KeysServiceClaimResponse], error) {
	target, ok := uuid(req.Msg.AccountId)
	if !ok {
		return nil, cerr(connect.CodeInvalidArgument, "account_id_invalid")
	}
	// Draining someone's one-time packages degrades them to the last-resort one; limit claims per caller.
	if ok, err := s.hit(ctx, fmt.Sprintf("claim:%x", account(ctx)), 24*time.Hour, s.cfg.claimPerDay); err != nil {
		return nil, internal(err)
	} else if !ok {
		return nil, cerr(connect.CodeResourceExhausted, "rate_limited")
	}
	rows, err := s.db.Query(ctx, `SELECT device_id FROM devices WHERE account_id = $1`, target)
	if err != nil {
		return nil, internal(err)
	}
	devices, err := pgx.CollectRows(rows, pgx.RowTo[[16]byte])
	if err != nil {
		return nil, internal(err)
	}
	res := &siegelv1.KeysServiceClaimResponse{}
	me := who(ctx)
	for _, d := range devices {
		if target == me.account && d == me.device {
			continue // M8: claiming our own account's keys is for our other devices
		}
		var data []byte
		err := s.db.QueryRow(ctx, `DELETE FROM key_packages WHERE id = (
			SELECT id FROM key_packages WHERE account_id = $1 AND device_id = $2 AND NOT last_resort
			ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED) RETURNING data`, target, d).Scan(&data)
		if errors.Is(err, pgx.ErrNoRows) {
			err = s.db.QueryRow(ctx, `SELECT data FROM key_packages WHERE account_id = $1 AND device_id = $2 AND last_resort`,
				target, d).Scan(&data)
		}
		if errors.Is(err, pgx.ErrNoRows) {
			continue // device has no packages at all
		} else if err != nil {
			return nil, internal(err)
		}
		res.KeyPackages = append(res.KeyPackages, &siegelv1.ClaimedKeyPackage{DeviceId: d[:], KeyPackage: data})
	}
	if len(res.KeyPackages) == 0 {
		return nil, cerr(connect.CodeNotFound, "no_key_packages")
	}
	return connect.NewResponse(res), nil
}

func (s *server) SendIdentified(ctx context.Context, req *connect.Request[siegelv1.MessagesServiceSendIdentifiedRequest]) (*connect.Response[siegelv1.MessagesServiceSendIdentifiedResponse], error) {
	if len(req.Msg.Payload) == 0 {
		return nil, cerr(connect.CodeInvalidArgument, "payload_empty")
	}
	var revoked []*siegelv1.DeviceAddress
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) (err error) {
		revoked, err = enqueue(ctx, tx, req.Msg.Recipients, req.Msg.Payload)
		return err
	})
	if err != nil {
		return nil, txErr(err)
	}
	return connect.NewResponse(&siegelv1.MessagesServiceSendIdentifiedResponse{Revoked: revoked}), nil
}

func (s *server) Commit(ctx context.Context, req *connect.Request[siegelv1.GroupsServiceCommitRequest]) (*connect.Response[siegelv1.GroupsServiceCommitResponse], error) {
	m := req.Msg
	if n := len(m.GroupId); n == 0 || n > 64 || len(m.Commit) == 0 || (len(m.Welcome) > 0) != (len(m.WelcomeRecipients) > 0) {
		return nil, cerr(connect.CodeInvalidArgument, "commit_invalid")
	}
	var revoked []*siegelv1.DeviceAddress
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		// First writer wins (CRY-14): only the commit built on the current epoch moves it forward.
		q := `UPDATE groups SET epoch = epoch + 1, updated_at = now() WHERE group_id = $1 AND epoch = $2`
		if m.Epoch == 0 {
			// CMP-04: cap new conversations per account per day (spam without content access).
			if ok, err := s.hit(ctx, fmt.Sprintf("newchat:%x", account(ctx)), 24*time.Hour, s.cfg.newChatPerDay); err != nil {
				return err
			} else if !ok {
				s.signal(ctx, account(ctx), sigNewChatLimit)
				return cerr(connect.CodeResourceExhausted, "rate_limited")
			}
			s.signal(ctx, account(ctx), sigNewChat)
			q = `INSERT INTO groups (group_id, epoch) VALUES ($1, 1) ON CONFLICT DO NOTHING`
		}
		args := []any{m.GroupId}
		if m.Epoch != 0 {
			args = append(args, int64(m.Epoch))
		}
		tag, err := tx.Exec(ctx, q, args...)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return cerr(connect.CodeAborted, "epoch_conflict")
		}
		if revoked, err = enqueue(ctx, tx, m.Recipients, m.Commit); err != nil {
			return err
		}
		if len(m.Welcome) > 0 {
			gone, err := enqueue(ctx, tx, m.WelcomeRecipients, m.Welcome)
			revoked = append(revoked, gone...)
			return err
		}
		return nil
	})
	if err != nil {
		return nil, txErr(err)
	}
	return connect.NewResponse(&siegelv1.GroupsServiceCommitResponse{Revoked: revoked}), nil
}

// enqueue queues payload for every recipient device that still exists and wakes their streams.
// Devices that no longer exist are returned as revoked (ID-13).
func enqueue(ctx context.Context, tx pgx.Tx, to []*siegelv1.DeviceAddress, payload []byte) ([]*siegelv1.DeviceAddress, error) {
	if len(to) > maxRecipients {
		return nil, cerr(connect.CodeInvalidArgument, "too_many_recipients")
	}
	var revoked []*siegelv1.DeviceAddress
	for _, r := range to {
		a, ok1 := uuid(r.AccountId)
		d, ok2 := uuid(r.DeviceId)
		if !ok1 || !ok2 {
			return nil, cerr(connect.CodeInvalidArgument, "recipient_invalid")
		}
		tag, err := tx.Exec(ctx, `INSERT INTO queue (account_id, device_id, payload)
			SELECT $1, $2, $3 WHERE EXISTS (SELECT 1 FROM devices WHERE account_id = $1 AND device_id = $2)`, a, d, payload)
		if err != nil {
			return nil, err
		}
		if tag.RowsAffected() == 0 {
			revoked = append(revoked, r)
			continue
		}
		if _, err := tx.Exec(ctx, `SELECT pg_notify('queue', $1)`, hex.EncodeToString(d[:])); err != nil {
			return nil, err
		}
	}
	return revoked, nil
}

func uuid(b []byte) (u [16]byte, ok bool) {
	if len(b) != 16 {
		return u, false
	}
	copy(u[:], b)
	return u, true
}

// txErr passes Connect errors raised inside a transaction through and hides everything else.
func txErr(err error) error {
	if ce := new(connect.Error); errors.As(err, &ce) {
		return ce
	}
	return internal(err)
}
