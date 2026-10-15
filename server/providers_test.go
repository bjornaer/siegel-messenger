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
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

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
	g, err := googleAuth(creds)
	if err != nil {
		t.Fatal(err)
	}
	send := fcm(g)
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

func TestPlayIntegrity(t *testing.T) { // ID-02
	var verdict map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/in.schlk.siegel:decodeIntegrityToken" || r.Header.Get("Authorization") != "Bearer at" {
			t.Errorf("bad call %s", r.URL.Path)
		}
		json.NewEncoder(w).Encode(map[string]any{"tokenPayloadExternal": verdict})
	}))
	defer srv.Close()
	playIntegrityBase = srv.URL
	check := playIntegrity(&googleAccount{project: "p1", bearer: func(context.Context) (string, error) { return "at", nil }})
	phone := "+34600000001"
	sum := sha256.Sum256([]byte(phone))
	good := func() map[string]any {
		return map[string]any{
			"requestDetails": map[string]any{"requestPackageName": "in.schlk.siegel", "requestHash": hex.EncodeToString(sum[:]),
				"timestampMillis": strconv.FormatInt(time.Now().UnixMilli(), 10)},
			"appIntegrity":    map[string]any{"appRecognitionVerdict": "PLAY_RECOGNIZED"},
			"deviceIntegrity": map[string]any{"deviceRecognitionVerdict": []string{"MEETS_BASIC_INTEGRITY", "MEETS_DEVICE_INTEGRITY"}},
		}
	}
	android := siegelv1.Platform_PLATFORM_ANDROID
	verdict = good()
	if err := check(context.Background(), android, phone, "tok"); err != nil {
		t.Fatal(err)
	}
	for name, spoil := range map[string]func(map[string]any){
		"other number": func(v map[string]any) { v["requestDetails"].(map[string]any)["requestHash"] = "00" },
		"old token": func(v map[string]any) {
			v["requestDetails"].(map[string]any)["timestampMillis"] = strconv.FormatInt(time.Now().Add(-time.Hour).UnixMilli(), 10)
		},
		"sideloaded": func(v map[string]any) {
			v["appIntegrity"].(map[string]any)["appRecognitionVerdict"] = "UNRECOGNIZED_VERSION"
		},
		"rooted": func(v map[string]any) {
			v["deviceIntegrity"] = map[string]any{"deviceRecognitionVerdict": []string{"MEETS_BASIC_INTEGRITY"}}
		},
		"other app": func(v map[string]any) { v["requestDetails"].(map[string]any)["requestPackageName"] = "evil.app" },
	} {
		verdict = good()
		spoil(verdict)
		if check(context.Background(), android, phone, "tok") == nil {
			t.Error(name, "accepted")
		}
	}
	if check(context.Background(), siegelv1.Platform_PLATFORM_IOS, phone, "tok") == nil || check(context.Background(), android, phone, "") == nil {
		t.Error("iOS or empty token accepted")
	}
}

func TestSMSFallback(t *testing.T) { // ID-03: one provider failing doesn't stop sign-ups
	var sevenCode string
	var gotForm url.Values
	sv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		gotForm = r.PostForm
		if r.Header.Get("X-Api-Key") != "k" {
			t.Error("missing api key")
		}
		w.Write([]byte(`{"success":"` + sevenCode + `","messages":[]}`))
	}))
	defer sv.Close()
	sevenURL = sv.URL
	gwDown := true
	gw := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if gwDown {
			w.WriteHeader(http.StatusPaymentRequired)
			return
		}
		w.Write([]byte(`{}`))
	}))
	defer gw.Close()
	send := smsChain([]smsProvider{{"gatewayapi", gatewayAPI(gw.URL, "t", "Siegel")}, {"seven", seven("k", "Siegel")}})
	ctx := context.Background()

	sevenCode = "100"
	if err := send(ctx, "+34600000001", "123456"); err != nil {
		t.Fatal("seven should take over when GatewayAPI fails:", err)
	}
	if gotForm.Get("to") != "+34600000001" || gotForm.Get("text") != "Your Siegel code: 123456" || gotForm.Get("from") != "Siegel" {
		t.Fatal(gotForm)
	}
	sevenCode = "500" // seven.io: no credit, still HTTP 200
	err := send(ctx, "+34600000001", "123456")
	if err == nil || !strings.Contains(err.Error(), "seven: code 500") || strings.Contains(err.Error(), "600000001") {
		t.Fatal("both failing must fail, without the number in the error:", err)
	}
	gwDown = false
	if err := send(ctx, "+34600000001", "123456"); err != nil {
		t.Fatal("the first provider is used when it works:", err)
	}
}
