package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWebSite(t *testing.T) { // M8 part 5
	dir := t.TempDir()
	release := filepath.Join(dir, "r1")
	os.MkdirAll(filepath.Join(release, "pkg"), 0o755)
	os.MkdirAll(filepath.Join(release, ".well-known"), 0o755)
	os.WriteFile(filepath.Join(release, "index.html"), []byte("<html>siegel</html>"), 0o644)
	os.WriteFile(filepath.Join(release, "pkg", "core.wasm"), []byte("\x00asm"), 0o644)
	os.WriteFile(filepath.Join(release, manifestPath), []byte("abc  index.html\n"), 0o644)
	os.Symlink(release, filepath.Join(dir, "current"))

	s := newServer(config{domain: "siegel.schlk.in", webOrigin: "https://web.siegel.schlk.in", webDir: dir}, nil)
	h := s.routes()
	get := func(host, p string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodGet, p, nil)
		r.Host = host
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	page := get("web.siegel.schlk.in", "/")
	if page.Code != 200 || !strings.Contains(page.Body.String(), "siegel") {
		t.Fatal("the app's page", page.Code)
	}
	for k, v := range map[string]string{
		"Cross-Origin-Opener-Policy":   "same-origin",
		"Cross-Origin-Embedder-Policy": "require-corp",
		"X-Content-Type-Options":       "nosniff",
	} {
		want(t, page.Header().Get(k), v)
	}
	csp := page.Header().Get("Content-Security-Policy")
	for _, part := range []string{"script-src 'self' 'wasm-unsafe-eval'", "connect-src 'self' https://siegel.schlk.in wss://siegel.schlk.in", "frame-ancestors 'none'"} {
		if !strings.Contains(csp, part) {
			t.Fatal("CSP lacks", part, csp)
		}
	}
	if strings.Contains(csp, "'unsafe-eval'") {
		t.Fatal("no eval")
	}
	if w := get("web.siegel.schlk.in", "/pkg/core.wasm"); w.Code != 200 || w.Header().Get("Content-Type") != "application/wasm" {
		t.Fatal("wasm served as wasm", w.Code, w.Header().Get("Content-Type"))
	}
	if w := get("web.siegel.schlk.in", "/pkg/"); w.Code != 404 {
		t.Fatal("no directory listings", w.Code)
	}
	if w := get("web.siegel.schlk.in", "/../../etc/passwd"); w.Code != 404 {
		t.Fatal("nothing outside the release", w.Code)
	}
	if w := get("web.siegel.schlk.in:443", "/v1/stream"); w.Code != 404 {
		t.Fatal("the API isn't on the web app's host", w.Code)
	}
	if w := get("siegel.schlk.in", "/index.html"); strings.Contains(w.Body.String(), "<html>siegel") {
		t.Fatal("the site isn't on the API's host")
	}
	if len(s.webRelease()) != 64 {
		t.Fatal("transparency shows the manifest's hash")
	}
	want(t, strings.Join(hosts(s.cfg), ","), "siegel.schlk.in,web.siegel.schlk.in")
}
