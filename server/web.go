package main

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// M8 part 5: the web app (web.siegel.schlk.in), served by this process on its own host name
// and certificate. Only the files CI built, under headers that keep everything on our two
// origins. SIEGEL_WEB_DIR/current is a symlink deploy.sh swaps in one step.

// manifestPath lists every file's SHA-256; CI attests it (Sigstore), so anyone can check the
// served code is the code built from the public repo.
const manifestPath = ".well-known/siegel-web-manifest.txt"

// webHost is the web app's host name, from SIEGEL_WEB_ORIGIN; empty when there is no web app.
func (s *server) webHost() string {
	_, host, _ := strings.Cut(s.cfg.webOrigin, "://")
	return host
}

func (s *server) webCSP() string {
	api := "https://" + s.cfg.domain
	if s.cfg.domain == "" {
		api = "http://localhost:58080" // compose without TLS
	}
	ws := "wss" + strings.TrimPrefix(strings.TrimPrefix(api, "https"), "http")
	if strings.HasPrefix(api, "http://") {
		ws = "ws" + strings.TrimPrefix(api, "http")
	}
	return strings.Join([]string{
		"default-src 'none'",
		"script-src 'self' 'wasm-unsafe-eval'", // WebAssembly; no eval, no inline scripts
		"style-src 'self' 'unsafe-inline'",     // Flutter sets inline styles on its own elements
		"img-src 'self' data: blob:",
		"font-src 'self'",
		"connect-src 'self' " + api + " " + ws,
		"worker-src 'self' blob:", // flutter_rust_bridge's worker pool
		"manifest-src 'self'",
		"base-uri 'self'", // Flutter's <base href="/">
		"form-action 'none'",
		"frame-ancestors 'none'",
	}, "; ")
}

func (s *server) webSite() http.Handler {
	root := filepath.Join(s.cfg.webDir, "current")
	files := http.FileServer(http.Dir(root))
	csp := s.webCSP()
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		h := w.Header()
		h.Set("Content-Security-Policy", csp)
		// Cross-origin isolation: the core's threads need SharedArrayBuffer.
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		h.Set("Cross-Origin-Embedder-Policy", "require-corp")
		h.Set("Cross-Origin-Resource-Policy", "same-origin")
		h.Set("Strict-Transport-Security", "max-age=31536000")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=()")
		// Always ask: a new release is picked up on the next load, never a stale mix of files.
		h.Set("Cache-Control", "no-cache")
		p := path.Clean("/" + r.URL.Path)
		if p != "/" {
			if fi, err := os.Stat(filepath.Join(root, filepath.FromSlash(p))); err != nil || fi.IsDir() {
				http.NotFound(w, r) // no listings, no guesses
				return
			}
		}
		files.ServeHTTP(w, r)
	})
}

// webRelease is the served manifest's SHA-256, for /transparency; empty when none is served.
func (s *server) webRelease() string {
	if s.cfg.webDir == "" {
		return ""
	}
	b, err := os.ReadFile(filepath.Join(s.cfg.webDir, "current", filepath.FromSlash(manifestPath)))
	if err != nil {
		return ""
	}
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}
