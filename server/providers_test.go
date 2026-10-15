package main

import (
	"bytes"
	"cmp"
	"context"
	"crypto"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
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

func TestFCM(t *testing.T) { // SRV-05
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	var tokenCalls, sends int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/token":
			tokenCalls++
			r.ParseForm()
			parts := strings.Split(r.Form.Get("assertion"), ".")
			sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
			sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
			if rsa.VerifyPKCS1v15(&key.PublicKey, crypto.SHA256, sum[:], sig) != nil {
				t.Error("bad JWT signature")
			}
			w.Write([]byte(`{"access_token":"at","expires_in":3600}`))
		case "/v1/projects/p1/messages:send":
			sends++
			var m struct {
				Message struct {
					Token   string
					Android struct{ Priority string }
					Data    map[string]string
				}
			}
			json.NewDecoder(r.Body).Decode(&m)
			if r.Header.Get("Authorization") != "Bearer at" || m.Message.Android.Priority != "HIGH" || m.Message.Data != nil {
				t.Errorf("bad send: %+v", m)
			}
			if m.Message.Token == "gone" {
				w.WriteHeader(http.StatusNotFound)
			}
		}
	}))
	defer srv.Close()
	fcmBase = srv.URL
	creds, _ := json.Marshal(map[string]string{"project_id": "p1", "client_email": "x@p1", "token_uri": srv.URL + "/token",
		"private_key": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))})
	send, err := fcm(creds)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if err := send(ctx, siegelv1.Platform_PLATFORM_ANDROID, "t1"); err != nil {
		t.Fatal(err)
	}
	if err := send(ctx, siegelv1.Platform_PLATFORM_ANDROID, "gone"); !errors.Is(err, errPushTokenGone) {
		t.Fatal("404 must mean token gone", err)
	}
	send(ctx, siegelv1.Platform_PLATFORM_IOS, "ios") // not until APNs ships
	if tokenCalls != 1 || sends != 2 {
		t.Fatal("token not cached or iOS sent", tokenCalls, sends)
	}
}
