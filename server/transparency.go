package main

import (
	"context"
	"log/slog"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// M7 part 7: the yearly transparency report and retention. Everything counted here is a number
// per year; nothing names a person.

// dbExec is a pool or a transaction.
type dbExec interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
}

// tally adds one to this year's count for item.
func tally(ctx context.Context, db dbExec, item string) error {
	_, err := db.Exec(ctx, `INSERT INTO transparency (year, item, count) VALUES (extract(year FROM now())::int, $1, 1)
		ON CONFLICT (year, item) DO UPDATE SET count = transparency.count + 1`, item)
	return err
}

// retain deletes reports past retention (D2) unless a court asked to keep them, and expired
// preservation snapshots. Child-safety reports go after 12 months at most, the rest 6 months
// after they were resolved.
func (s *server) retain(ctx context.Context) {
	for _, q := range []string{
		`DELETE FROM reports WHERE (hold_until IS NULL OR hold_until < now()) AND
			((category <> 4 AND resolved_at < now() - interval '6 months') OR (category = 4 AND created_at < now() - interval '12 months'))`,
		`DELETE FROM preservations WHERE expires_at < now()`,
	} {
		if _, err := s.db.Exec(ctx, q); err != nil {
			slog.Error("retention", "err", err)
		}
	}
}

// transparencyPage is /transparency: this year's numbers (or ?year=), and the years there are.
func (s *server) transparencyPage(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	year, err := strconv.Atoi(r.URL.Query().Get("year"))
	if err != nil {
		year = time.Now().Year()
	}
	type line struct {
		Item  string
		Count int64
	}
	data := struct {
		pageData
		Year    int
		Years   []int
		Reports []line
		Actions []line
		Appeals []line
		Legal   []line
	}{pageData: pageData{Contact: s.cfg.contactEmail, Operator: s.cfg.operator}, Year: year}
	rows, err := s.db.Query(ctx, `SELECT item, count FROM transparency WHERE year = $1 ORDER BY item`, year)
	if err == nil {
		for rows.Next() {
			var l line
			if rows.Scan(&l.Item, &l.Count) != nil {
				continue
			}
			kind, item, _ := strings.Cut(l.Item, ":")
			l.Item = strings.ReplaceAll(item, "_", " ")
			switch kind {
			case "report":
				data.Reports = append(data.Reports, l)
			case "action":
				data.Actions = append(data.Actions, l)
			case "appeal":
				data.Appeals = append(data.Appeals, l)
			case "request":
				l.Item = strings.ReplaceAll(l.Item, ":", ", ")
				data.Legal = append(data.Legal, l)
			}
		}
		rows.Close()
	}
	if rows, err := s.db.Query(ctx, `SELECT DISTINCT year FROM transparency ORDER BY year DESC`); err == nil {
		for rows.Next() {
			var y int
			if rows.Scan(&y) == nil {
				data.Years = append(data.Years, y)
			}
		}
		rows.Close()
	}
	sort.Ints(data.Years)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
	if err := pages.ExecuteTemplate(w, "transparency", data); err != nil {
		slog.Error("page", "name", "transparency", "err", err)
	}
}
