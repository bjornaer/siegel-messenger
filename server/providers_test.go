package main

import (
	"bytes"
	"cmp"
	"context"
	"crypto/ed25519"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

func TestGatewayAPI(t *testing.T) {
	var got []byte
	var auth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got, _ = io.ReadAll(r.Body)
		auth = r.Header.Get("Authorization")
		w.Write([]byte(`{"msg_id":"x"}`))
	}))
	defer srv.Close()
	if err := gatewayAPI(srv.URL, "tok", "Siegel")(context.Background(), "+34600000001", "123456"); err != nil {
		t.Fatal(err)
	}
	want(t, auth, "Token tok")
	want(t, string(got), `{"message":"Your Siegel code: 123456","recipient":34600000001,"sender":"Siegel"}`)

	srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(422) })
	if gatewayAPI(srv.URL, "tok", "Siegel")(context.Background(), "+34600000001", "1") == nil {
		t.Fatal("422 must fail")
	}
}

// Runs against the compose OpenBao: SIEGEL_TEST_BAO_ADDR=http://localhost:58200 (token dev-root).
func TestBao(t *testing.T) {
	addr := os.Getenv("SIEGEL_TEST_BAO_ADDR")
	if addr == "" {
		t.Skip("SIEGEL_TEST_BAO_ADDR not set")
	}
	ctx := context.Background()
	b := bao{addr: addr, token: cmp.Or(os.Getenv("SIEGEL_TEST_BAO_TOKEN"), "dev-root")}
	h1, err := b.hmacPhone(ctx, "+34600000001")
	h2, _ := b.hmacPhone(ctx, "+34600000001")
	h3, _ := b.hmacPhone(ctx, "+34600000002")
	if err != nil || len(h1) != 32 || !bytes.Equal(h1, h2) || bytes.Equal(h1, h3) {
		t.Fatal("hmac", err, len(h1))
	}

	sig, err := b.signAS(ctx, []byte("msg"))
	if err != nil {
		t.Fatal(err)
	}
	pub, err := b.asPublicKey(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !ed25519.Verify(pub, []byte("msg"), sig) {
		t.Fatal("AS signature does not verify with the transit public key")
	}
}
