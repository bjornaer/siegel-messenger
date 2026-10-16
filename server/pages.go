package main

import (
	"embed"
	"encoding/json"
	"html/template"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
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
	Username string // /u/<username> (DISC-02)
}

var usernamePath = regexp.MustCompile(`^[a-z0-9._]{1,32}$`)

// contactPage is what a contact link shows in a browser (DISC-08): how to get the app.
func (s *server) contactPage(w http.ResponseWriter, r *http.Request) {
	u := strings.ToLower(r.PathValue("username"))
	if !usernamePath.MatchString(u) {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
	w.Header().Set("Referrer-Policy", "no-referrer")
	if err := pages.ExecuteTemplate(w, "u", pageData{Contact: s.cfg.contactEmail, Username: u}); err != nil {
		slog.Error("page", "name", "u", "err", err)
	}
}

// assetLinks lets Android open /u/ links straight in the app (App Links). The fingerprints are
// the app's signing certificates: the upload key and Play's app signing key.
func (s *server) assetLinks(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode([]map[string]any{{
		"relation": []string{"delegate_permission/common.handle_all_urls"},
		"target": map[string]any{
			"namespace": "android_app", "package_name": androidPackage, "sha256_cert_fingerprints": s.cfg.androidCerts,
		},
	}})
}

func (s *server) page(name string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
		if err := pages.ExecuteTemplate(w, name, pageData{Contact: s.cfg.contactEmail, Operator: s.cfg.operator}); err != nil {
			slog.Error("page", "name", name, "err", err)
		}
	}
}
