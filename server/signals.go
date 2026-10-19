package main

import (
	"context"
	"log/slog"
)

// M7 part 6: abuse signals. What the server can see without content: chats started, the daily
// limits hit, reports received. Whether a message request was accepted is end-to-end encrypted.
const (
	sigNewChat      = "new_chat"
	sigNewChatLimit = "new_chat_limit"
	sigLookupLimit  = "lookup_limit"
)

// signal counts one event for the account today. Best effort: it never fails the request.
func (s *server) signal(ctx context.Context, acct [16]byte, name string) {
	if _, err := s.db.Exec(ctx, `INSERT INTO signals (account_id, name) VALUES ($1, $2)
		ON CONFLICT (account_id, name, day) DO UPDATE SET count = signals.count + 1`, acct, name); err != nil {
		slog.Error("signal", "err", err)
	}
}

// accountSignals is the last 30 days for one account, plus reports received.
type accountSignals struct {
	NewChats, NewChatLimit, LookupLimit, Reports, ChildSafetyReports int
	CreatedDay                                                       string
}

func (s *server) signals(ctx context.Context, acct [16]byte) (accountSignals, error) {
	var a accountSignals
	err := s.db.QueryRow(ctx, `SELECT
		coalesce((SELECT sum(count) FROM signals WHERE account_id = $1 AND name = 'new_chat'), 0),
		coalesce((SELECT sum(count) FROM signals WHERE account_id = $1 AND name = 'new_chat_limit'), 0),
		coalesce((SELECT sum(count) FROM signals WHERE account_id = $1 AND name = 'lookup_limit'), 0),
		(SELECT count(*) FROM reports WHERE reported = $1 AND created_at > now() - interval '30 days'),
		(SELECT count(*) FROM reports WHERE reported = $1 AND category = 4 AND created_at > now() - interval '30 days'),
		coalesce((SELECT created_day::text FROM accounts WHERE id = $1), '')`, acct).Scan(
		&a.NewChats, &a.NewChatLimit, &a.LookupLimit, &a.Reports, &a.ChildSafetyReports, &a.CreatedDay)
	return a, err
}
