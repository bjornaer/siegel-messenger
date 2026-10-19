package main

import (
	"bytes"
	"context"
	"fmt"
	"strings"
	"time"

	"connectrpc.com/connect"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
)

// reports is CMP-03: reports arrive sealed to the moderators' key; the server stores them for
// the review queue and can't read them.
type reports struct{ *server }

const reportsPerDay = 20

func (s reports) Key(context.Context, *connect.Request[siegelv1.ReportServiceKeyRequest]) (*connect.Response[siegelv1.ReportServiceKeyResponse], error) {
	key := s.cfg.reportsKey
	if !strings.HasPrefix(key, "age1") {
		key = "" // never hand out a secret key pasted here by mistake
	}
	return connect.NewResponse(&siegelv1.ReportServiceKeyResponse{AgeRecipient: key}), nil
}

func (s reports) Submit(ctx context.Context, req *connect.Request[siegelv1.ReportServiceSubmitRequest]) (*connect.Response[siegelv1.ReportServiceSubmitResponse], error) {
	m := req.Msg
	if m.Category <= siegelv1.ReportCategory_REPORT_CATEGORY_UNSPECIFIED || m.Category > siegelv1.ReportCategory_REPORT_CATEGORY_OTHER ||
		(len(m.ReportedAccount) != 0 && len(m.ReportedAccount) != 16) ||
		!bytes.HasPrefix(m.Sealed, []byte("age-encryption.org/v1\n")) {
		return nil, cerr(connect.CodeInvalidArgument, "report_invalid")
	}
	me := account(ctx)
	if ok, err := s.hit(ctx, fmt.Sprintf("report:%x", me), 24*time.Hour, reportsPerDay); err != nil {
		return nil, internal(err)
	} else if !ok {
		return nil, cerr(connect.CodeResourceExhausted, "rate_limited")
	}
	var reported *[16]byte
	if len(m.ReportedAccount) == 16 {
		reported = (*[16]byte)(m.ReportedAccount)
	}
	if _, err := s.db.Exec(ctx, `INSERT INTO reports (reporter, reported, category, sealed) VALUES ($1, $2, $3, $4)`,
		me, reported, int16(m.Category), m.Sealed); err != nil {
		return nil, internal(err)
	}
	s.count(ctx, "reports_received")
	return connect.NewResponse(&siegelv1.ReportServiceSubmitResponse{}), nil
}
