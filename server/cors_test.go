package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCORS(t *testing.T) { // M8: the web app's origin only
	s := &server{cfg: config{webOrigin: "https://web.siegel.schlk.in"}}
	h := s.cors(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusTeapot) }))
	call := func(method, origin string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "/siegel.v1.AccountService/Export", nil)
		if origin != "" {
			r.Header.Set("Origin", origin)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	pre := call(http.MethodOptions, "https://web.siegel.schlk.in")
	if pre.Code != http.StatusNoContent || pre.Header().Get("Access-Control-Allow-Headers") == "" {
		t.Fatal("preflight from the web app", pre.Code, pre.Header())
	}
	if got := call(http.MethodPost, "https://web.siegel.schlk.in"); got.Header().Get("Access-Control-Allow-Origin") != "https://web.siegel.schlk.in" || got.Code != http.StatusTeapot {
		t.Fatal("the call itself goes through, readable by the web app")
	}
	if got := call(http.MethodPost, "https://evil.example"); got.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatal("no other origin")
	}
	plain := (&server{}).cors(http.NotFoundHandler())
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodOptions, "/", nil)
	r.Header.Set("Origin", "https://web.siegel.schlk.in")
	plain.ServeHTTP(w, r)
	if w.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatal("no web origin set: no CORS at all")
	}
}
