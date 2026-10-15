package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"
)

// count adds one to an hourly aggregate counter (SEC-04). Failures are logged, never surfaced.
func (s *server) count(ctx context.Context, name string) {
	if _, err := s.db.Exec(ctx, `INSERT INTO metrics VALUES ($1, date_trunc('hour', now()), 1)
		ON CONFLICT (name, hour) DO UPDATE SET count = metrics.count + 1`, name); err != nil {
		slog.Error("metrics", "err", err)
	}
}

// otpRate returns OTPs sent and the share verified over the last 24 hours (ID-04).
func (s *server) otpRate(ctx context.Context) (sent int64, rate float64, err error) {
	var verified int64
	err = s.db.QueryRow(ctx, `SELECT
		coalesce(sum(count) FILTER (WHERE name = 'otp_sent'), 0),
		coalesce(sum(count) FILTER (WHERE name = 'otp_verified'), 0)
		FROM metrics WHERE hour > now() - interval '24 hours'`).Scan(&sent, &verified)
	if sent > 0 {
		rate = float64(verified) / float64(sent)
	}
	return sent, rate, err
}

// checkOtpRate alerts at most once a day when the completion rate drops, the usual sign of SMS pumping.
func (s *server) checkOtpRate(ctx context.Context) {
	sent, rate, err := s.otpRate(ctx)
	if err != nil {
		slog.Error("otp rate", "err", err)
		return
	}
	if sent < int64(s.cfg.otpAlertMin) || rate >= s.cfg.otpAlertRate || time.Since(s.lastAlert) < 24*time.Hour {
		return
	}
	s.lastAlert = time.Now()
	s.alert(ctx, fmt.Sprintf("Siegel: OTP completion %.0f%% over 24h (%d codes sent). Possible SMS pumping; check SIEGEL_SMS_DAILY_CAP and GatewayAPI spend.", rate*100, sent))
}

// alert posts plain text to the operator webhook, or logs it when none is set.
func (s *server) alert(ctx context.Context, msg string) {
	slog.Error("ALERT", "msg", msg)
	if s.cfg.alertURL == "" {
		return
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.cfg.alertURL, strings.NewReader(msg))
	if err != nil {
		slog.Error("alert", "err", err)
		return
	}
	res, err := httpClient.Do(req)
	if err != nil {
		slog.Error("alert", "err", err)
		return
	}
	res.Body.Close()
}
