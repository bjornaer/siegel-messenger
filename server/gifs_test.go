package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestGifs(t *testing.T) {
	e := setup(t)
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/gifs/search":
			if r.URL.Query().Get("api_key") != "k" || r.URL.Query().Get("q") != "cats" {
				http.Error(w, "bad", 400)
				return
			}
			w.Write([]byte(`{"data":[{"id":"abc123"},{"id":"../evil"}]}`))
		case "/media/abc123/giphy-downsized.gif":
			w.Header().Set("Content-Type", "image/gif")
			w.Write([]byte("GIF89a"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer fake.Close()
	giphyAPI, giphyMedia = fake.URL+"/v1/gifs/", fake.URL+"/media/"
	e.s.cfg.giphyKey = "k"
	a, err := e.register("+34600000091", "")
	if err != nil {
		t.Fatal(err)
	}
	get := func(path, token string) (int, []byte) {
		req, _ := http.NewRequest(http.MethodGet, e.url+path, nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		b, _ := io.ReadAll(res.Body)
		return res.StatusCode, b
	}

	if code, _ := get("/v1/gifs?q=cats", ""); code != http.StatusUnauthorized {
		t.Fatalf("no token: %d", code)
	}
	code, b := get("/v1/gifs?q=cats", a.DeviceToken)
	var ids []string
	if code != 200 || json.Unmarshal(b, &ids) != nil || len(ids) != 1 || ids[0] != "abc123" {
		t.Fatalf("search: %d %s", code, b)
	}
	if code, b := get("/v1/gifs/abc123/full", a.DeviceToken); code != 200 || string(b) != "GIF89a" {
		t.Fatalf("media: %d %s", code, b)
	}
	if code, _ := get("/v1/gifs/abc123/huge", a.DeviceToken); code != http.StatusNotFound {
		t.Fatalf("unknown size: %d", code)
	}
}
