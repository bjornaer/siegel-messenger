package main

import (
	"embed"
	"html/template"
	"log/slog"
	"net/http"
)

// Public pages the app stores require (CMP-07): privacy policy and account deletion.
// Operator details come from config, so publishing them needs no code change.
//
//go:embed pages/*.html
var pageFiles embed.FS

var pages = template.Must(template.ParseFS(pageFiles, "pages/*.html"))

type pageData struct {
	Contact  string // SIEGEL_CONTACT_EMAIL
	Operator string // SIEGEL_OPERATOR: legal name and postal address
}

func (s *server) page(name string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
		if err := pages.ExecuteTemplate(w, name, pageData{s.cfg.contactEmail, s.cfg.operator}); err != nil {
			slog.Error("page", "name", name, "err", err)
		}
	}
}
