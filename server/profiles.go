package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"errors"

	"connectrpc.com/connect"
	"github.com/jackc/pgx/v5"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
)

// profiles serves ProfileService; a separate type because UsernameService also has a Set.
type profiles struct{ *server }

func (p profiles) Set(ctx context.Context, req *connect.Request[siegelv1.ProfileServiceSetRequest]) (*connect.Response[siegelv1.ProfileServiceSetResponse], error) {
	m := req.Msg
	if len(m.EncryptedProfile) == 0 || len(m.EncryptedProfile) > 4096 || len(m.DeliveryTokenVerifier) != sha256.Size {
		return nil, cerr(connect.CodeInvalidArgument, "profile_invalid")
	}
	if _, err := p.db.Exec(ctx, `INSERT INTO profiles (account_id, encrypted, verifier) VALUES ($1, $2, $3)
		ON CONFLICT (account_id) DO UPDATE SET encrypted = $2, verifier = $3`,
		account(ctx), m.EncryptedProfile, m.DeliveryTokenVerifier); err != nil {
		return nil, internal(err)
	}
	return connect.NewResponse(&siegelv1.ProfileServiceSetResponse{}), nil
}

func (p profiles) Get(ctx context.Context, req *connect.Request[siegelv1.ProfileServiceGetRequest]) (*connect.Response[siegelv1.ProfileServiceGetResponse], error) {
	id, ok := uuid(req.Msg.AccountId)
	if !ok {
		return nil, cerr(connect.CodeInvalidArgument, "account_id_invalid")
	}
	res := &siegelv1.ProfileServiceGetResponse{}
	err := p.db.QueryRow(ctx, `SELECT encrypted FROM profiles WHERE account_id = $1`, id).Scan(&res.EncryptedProfile)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, cerr(connect.CodeNotFound, "profile_not_found")
	} else if err != nil {
		return nil, internal(err)
	}
	return connect.NewResponse(res), nil
}

// SendSealed queues a payload without knowing who sent it (MSG-10). Unauthenticated; each
// recipient must present the delivery token whose SHA-256 it registered with its profile.
func (s *server) SendSealed(ctx context.Context, req *connect.Request[siegelv1.MessagesServiceSendSealedRequest]) (*connect.Response[siegelv1.MessagesServiceSendSealedResponse], error) {
	if !s.ipHits.allow("sealed|"+peerIP(req.Peer()), s.cfg.sealedPerIP) {
		return nil, cerr(connect.CodeResourceExhausted, "rate_limited")
	}
	m := req.Msg
	if len(m.Payload) == 0 {
		return nil, cerr(connect.CodeInvalidArgument, "payload_empty")
	}
	if len(m.Recipients) > maxRecipients {
		return nil, cerr(connect.CodeInvalidArgument, "too_many_recipients")
	}
	res := &siegelv1.MessagesServiceSendSealedResponse{}
	var allowed []*siegelv1.DeviceAddress
	for _, r := range m.Recipients {
		a, ok := uuid(r.GetAddress().GetAccountId())
		if !ok {
			return nil, cerr(connect.CodeInvalidArgument, "recipient_invalid")
		}
		var verifier []byte
		err := s.db.QueryRow(ctx, `SELECT verifier FROM profiles WHERE account_id = $1`, a).Scan(&verifier)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return nil, internal(err)
		}
		got := sha256.Sum256(r.DeliveryToken)
		if verifier == nil || subtle.ConstantTimeCompare(got[:], verifier) != 1 {
			res.Rejected = append(res.Rejected, r.Address)
			continue
		}
		allowed = append(allowed, r.Address)
	}
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) (err error) {
		res.Revoked, err = enqueue(ctx, tx, allowed, m.Payload)
		return err
	})
	if err != nil {
		return nil, txErr(err)
	}
	return connect.NewResponse(res), nil
}
