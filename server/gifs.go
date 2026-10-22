package main

import (
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// GIF search (GIPHY), through this server: GIPHY sees neither the user's address nor which
// account searched, only this server. Searches are never logged. The app downloads the GIF here
// and sends it like any photo, end-to-end encrypted, so recipients never contact GIPHY.

// giphyAPI and giphyMedia are variables so tests can point them at a fake.
var (
	giphyAPI   = "https://api.giphy.com/v1/gifs/"
	giphyMedia = "https://i.giphy.com/media/"
)

var giphyID = regexp.MustCompile(`^[A-Za-z0-9]{1,64}$`)

// gifSizes are the renditions the app may fetch: a small animated preview for the grid, and
// the one it sends (at most 2 MB).
var gifSizes = map[string]string{"preview": "100w.webp", "full": "giphy-downsized.gif"}

const (
	maxGif        = 8 << 20
	gifsPerHour   = 3000 // a search shows 24 previews, each its own request
	gifsPageLimit = 24
)

var giphyClient = &http.Client{Timeout: 15 * time.Second}

// gifCaller authenticates a GIF request and counts it against the account's hourly budget.
func (s *server) gifCaller(w http.ResponseWriter, r *http.Request) bool {
	if s.cfg.giphyKey == "" {
		http.NotFound(w, r)
		return false
	}
	c, found, err := s.authenticate(r.Context(), r.Header.Get("Authorization"))
	if err != nil {
		http.Error(w, "internal", http.StatusInternalServerError)
		return false
	}
	if !found || c.suspended {
		http.Error(w, "unauthenticated", http.StatusUnauthorized)
		return false
	}
	if ok, err := s.hit(r.Context(), "gifs:"+hex.EncodeToString(c.account[:]), time.Hour, gifsPerHour); err != nil || !ok {
		http.Error(w, "rate_limited", http.StatusTooManyRequests)
		return false
	}
	return true
}

// gifSearch serves GET /v1/gifs?q=&offset=: GIPHY IDs, trending when q is empty.
func (s *server) gifSearch(w http.ResponseWriter, r *http.Request) {
	if !s.gifCaller(w, r) {
		return
	}
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if len([]rune(q)) > 50 {
		q = string([]rune(q)[:50])
	}
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	offset = max(0, min(offset, 4999)) // GIPHY's own ceiling
	v := url.Values{
		"api_key": {s.cfg.giphyKey},
		"limit":   {strconv.Itoa(gifsPageLimit)},
		"offset":  {strconv.Itoa(offset)},
		"rating":  {"pg-13"},
		"bundle":  {"messaging_non_clips"},
	}
	endpoint := "trending"
	if q != "" {
		endpoint = "search"
		v.Set("q", q)
	}
	res, err := giphyClient.Get(giphyAPI + endpoint + "?" + v.Encode())
	if err != nil {
		http.Error(w, "network", http.StatusBadGateway)
		return
	}
	defer res.Body.Close()
	var body struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if res.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(res.Body, 4<<20)).Decode(&body) != nil {
		http.Error(w, "network", http.StatusBadGateway)
		return
	}
	ids := []string{}
	for _, d := range body.Data {
		if giphyID.MatchString(d.ID) {
			ids = append(ids, d.ID)
		}
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(ids)
}

// gifMedia serves GET /v1/gifs/{id}/{preview|full}. Only GIPHY's own media host, built from an
// ID and a fixed rendition, so the request can't be pointed anywhere else.
func (s *server) gifMedia(w http.ResponseWriter, r *http.Request) {
	id, file := r.PathValue("id"), gifSizes[r.PathValue("size")]
	if !giphyID.MatchString(id) || file == "" {
		http.NotFound(w, r)
		return
	}
	if !s.gifCaller(w, r) {
		return
	}
	res, err := giphyClient.Get(giphyMedia + id + "/" + file)
	if err != nil {
		http.Error(w, "network", http.StatusBadGateway)
		return
	}
	defer res.Body.Close()
	ct := res.Header.Get("Content-Type")
	if res.StatusCode != http.StatusOK || (ct != "image/gif" && ct != "image/webp") || res.ContentLength > maxGif {
		http.Error(w, "gif_unavailable", http.StatusBadGateway)
		return
	}
	b, err := io.ReadAll(io.LimitReader(res.Body, maxGif+1))
	if err != nil || len(b) > maxGif {
		http.Error(w, "gif_unavailable", http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", ct)
	w.Header().Set("Cache-Control", "no-store")
	w.Write(b)
}
