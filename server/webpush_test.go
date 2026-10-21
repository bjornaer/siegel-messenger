package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
)

func TestWebPush(t *testing.T) { // M8 part 6
	for token, ok := range map[string]bool{
		`{"endpoint":"https://fcm.googleapis.com/fcm/send/abc","keys":{}}`:    true,
		`{"endpoint":"https://updates.push.services.mozilla.com/wpush/v2/x"}`: true,
		`{"endpoint":"https://db5p.notify.windows.com/w/?token=x"}`:           true,
		`{"endpoint":"http://fcm.googleapis.com/fcm/send/abc"}`:               false, // not https
		`{"endpoint":"https://openbao:8200/v1/sys/seal"}`:                     false, // our own network
		`{"endpoint":"https://fcm.googleapis.com.evil.example/x"}`:            false,
		`{"endpoint":"https://169.254.169.254/latest"}`:                       false,
		`{"endpoint":"https://user@fcm.googleapis.com/x"}`:                    false,
		`{"endpoint":"https://fcm.googleapis.com:8443/x"}`:                    false,
		`not json`: false,
	} {
		if _, err := webPushEndpoint(token); (err == nil) != ok {
			t.Fatal(token, err)
		}
	}

	key, err := vapidKeygen()
	if err != nil {
		t.Fatal(err)
	}
	v, err := newVapid(key, "mailto:ops@example.org")
	if err != nil {
		t.Fatal(err)
	}
	// The JWT verifies under the public key the browser subscribes with.
	jwt, _ := v.jwt("https://fcm.googleapis.com", time.Now())
	parts := strings.Split(jwt, ".")
	pub, _ := base64.RawURLEncoding.DecodeString(v.public)
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	h := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	pk := ecdsa.PublicKey{Curve: v.key.Curve, X: new(big.Int).SetBytes(pub[1:33]), Y: new(big.Int).SetBytes(pub[33:])}
	if len(pub) != 65 || !ecdsa.Verify(&pk, h[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		t.Fatal("VAPID signature")
	}
	var claims map[string]any
	b, _ := base64.RawURLEncoding.DecodeString(parts[1])
	json.Unmarshal(b, &claims)
	want(t, claims["aud"].(string), "https://fcm.googleapis.com")

	// Android pushes still go the old way; a web device's empty push is sent signed.
	var android int
	send := v.webPushOr(func(context.Context, siegelv1.Platform, string) error { android++; return nil })
	send(context.Background(), siegelv1.Platform_PLATFORM_ANDROID, "fcm-token")
	want(t, fmt.Sprint(android), "1")
	if err := send(context.Background(), siegelv1.Platform_PLATFORM_WEB, `{"endpoint":"https://openbao:8200/x"}`); err != errPushTokenGone {
		t.Fatal("a stored bad endpoint is dropped, never called", err)
	}

	s := &server{vapid: v}
	w := httptest.NewRecorder()
	s.vapidKey(w, httptest.NewRequest(http.MethodGet, "/v1/push/vapid", nil))
	want(t, w.Body.String(), v.public)
}
