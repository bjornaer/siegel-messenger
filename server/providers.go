package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

var httpClient = &http.Client{Timeout: 10 * time.Second}

func postJSON(ctx context.Context, url string, header http.Header, in, out any) error {
	body, err := json.Marshal(in)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header = header
	req.Header.Set("Content-Type", "application/json")
	res, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode/100 != 2 {
		return fmt.Errorf("%s: status %d", strings.SplitN(url, "?", 2)[0], res.StatusCode) // never echo the body: it may hold a number
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(res.Body).Decode(out)
}

// bao talks to the OpenBao transit engine; the pepper and AS key never leave it (SEC-05).
type bao struct{ addr, token string }

func (b bao) transit(ctx context.Context, path, field string, in map[string]any) ([]byte, error) {
	var out struct{ Data map[string]any }
	if err := postJSON(ctx, b.addr+"/v1/"+path, http.Header{"X-Vault-Token": {b.token}}, in, &out); err != nil {
		return nil, err
	}
	v, _ := out.Data[field].(string) // "vault:v1:<base64>"
	raw, err := base64.StdEncoding.DecodeString(v[strings.LastIndexByte(v, ':')+1:])
	if err == nil && len(raw) == 0 {
		err = fmt.Errorf("openbao %s: empty %s", path, field) // an empty HMAC would merge every account
	}
	return raw, err
}

// hmacPhone is HMAC-SHA256(pepper, E.164) (ID-05). Pinned to key version 1: rotating the
// pepper would orphan every account, so rotation needs a rehash migration first.
func (b bao) hmacPhone(ctx context.Context, phone string) ([]byte, error) {
	return b.transit(ctx, "transit/hmac/siegel-phone/sha2-256", "hmac",
		map[string]any{"input": base64.StdEncoding.EncodeToString([]byte(phone)), "key_version": 1})
}

// signAS is the Authentication Service Ed25519 signature (CRY-08).
func (b bao) signAS(ctx context.Context, msg []byte) ([]byte, error) {
	return b.transit(ctx, "transit/sign/siegel-as", "signature",
		map[string]any{"input": base64.StdEncoding.EncodeToString(msg)})
}

func (b bao) renew(ctx context.Context) error {
	return postJSON(ctx, b.addr+"/v1/auth/token/renew-self", http.Header{"X-Vault-Token": {b.token}}, map[string]any{}, nil)
}

// gatewayAPI sends OTPs through GatewayAPI's Messaging API (EU platform by default).
func gatewayAPI(url, token, sender string) func(ctx context.Context, phone, code string) error {
	return func(ctx context.Context, phone, code string) error {
		return postJSON(ctx, url, http.Header{"Authorization": {"Token " + token}}, map[string]any{
			"sender":    sender,
			"message":   "Your Siegel code: " + code,
			"recipient": json.Number(strings.TrimPrefix(phone, "+")),
		}, nil)
	}
}
