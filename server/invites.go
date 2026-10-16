package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"time"

	"connectrpc.com/connect"
	"github.com/jackc/pgx/v5"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
)

// maxInviteLife caps how long a link lives (GRP-16: 1 week by default, set by the client).
const maxInviteLife = 8 * 24 * time.Hour

type invites struct{ *server }

func (s invites) Put(ctx context.Context, req *connect.Request[siegelv1.InvitesServicePutRequest]) (*connect.Response[siegelv1.InvitesServicePutResponse], error) {
	m := req.Msg
	exp := time.Unix(m.ExpiresAt, 0)
	if len(m.Id) != 16 || len(m.WriteKey) != 16 || len(m.Snapshot) == 0 || exp.Before(time.Now()) || time.Until(exp) > maxInviteLife {
		return nil, cerr(connect.CodeInvalidArgument, "invite_invalid")
	}
	h := sha256.Sum256(m.WriteKey)
	var stored []byte
	err := s.db.QueryRow(ctx, `INSERT INTO group_invites (id, write_hash, snapshot, expires_at) VALUES ($1, $2, $3, $4)
		ON CONFLICT (id) DO UPDATE SET snapshot = $3, expires_at = $4 WHERE group_invites.write_hash = $2
		RETURNING write_hash`, m.Id, h[:], m.Snapshot, exp).Scan(&stored)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, cerr(connect.CodePermissionDenied, "invite_write_denied") // wrong write key
	} else if err != nil {
		return nil, internal(err)
	}
	return connect.NewResponse(&siegelv1.InvitesServicePutResponse{}), nil
}

func (s invites) Get(ctx context.Context, req *connect.Request[siegelv1.InvitesServiceGetRequest]) (*connect.Response[siegelv1.InvitesServiceGetResponse], error) {
	var snap []byte
	var exp time.Time
	err := s.db.QueryRow(ctx, `SELECT snapshot, expires_at FROM group_invites WHERE id = $1 AND expires_at > now()`,
		req.Msg.Id).Scan(&snap, &exp)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, cerr(connect.CodeNotFound, "invite_not_found")
	} else if err != nil {
		return nil, internal(err)
	}
	return connect.NewResponse(&siegelv1.InvitesServiceGetResponse{Snapshot: snap, ExpiresAt: exp.Unix()}), nil
}

func (s invites) Delete(ctx context.Context, req *connect.Request[siegelv1.InvitesServiceDeleteRequest]) (*connect.Response[siegelv1.InvitesServiceDeleteResponse], error) {
	h := sha256.Sum256(req.Msg.WriteKey)
	var stored []byte
	err := s.db.QueryRow(ctx, `SELECT write_hash FROM group_invites WHERE id = $1`, req.Msg.Id).Scan(&stored)
	if err == nil && subtle.ConstantTimeCompare(stored, h[:]) == 1 {
		_, err = s.db.Exec(ctx, `DELETE FROM group_invites WHERE id = $1`, req.Msg.Id)
	}
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, internal(err)
	}
	return connect.NewResponse(&siegelv1.InvitesServiceDeleteResponse{}), nil
}
