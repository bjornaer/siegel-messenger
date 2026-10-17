package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"
)

var httpClient = &http.Client{Timeout: 10 * time.Second}

type statusError struct {
	url  string
	code int
}

func (e *statusError) Error() string { return fmt.Sprintf("%s: status %d", e.url, e.code) }

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
		return &statusError{strings.SplitN(url, "?", 2)[0], res.StatusCode} // never echo the body: it may hold a number
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

// hmac512 is a 64-byte HMAC under the phone pepper, for deriving discovery keys (DISC-05).
func (b bao) hmac512(ctx context.Context, input string) ([]byte, error) {
	return b.transit(ctx, "transit/hmac/siegel-phone/sha2-512", "hmac",
		map[string]any{"input": base64.StdEncoding.EncodeToString([]byte(input)), "key_version": 1})
}

// signAS is the Authentication Service Ed25519 signature (CRY-08).
func (b bao) signAS(ctx context.Context, msg []byte) ([]byte, error) {
	return b.transit(ctx, "transit/sign/siegel-as", "signature",
		map[string]any{"input": base64.StdEncoding.EncodeToString(msg)})
}

// asPublicKey reads the AS signing public key (key version 1) from transit.
func (b bao) asPublicKey(ctx context.Context) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, b.addr+"/v1/transit/keys/siegel-as", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Vault-Token", b.token)
	res, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("openbao keys/siegel-as: status %d", res.StatusCode)
	}
	var out struct {
		Data struct {
			Keys map[string]struct {
				PublicKey string `json:"public_key"`
			}
		}
	}
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
		return nil, err
	}
	return base64.StdEncoding.DecodeString(out.Data.Keys["1"].PublicKey)
}

func (b bao) renew(ctx context.Context) error {
	return postJSON(ctx, b.addr+"/v1/auth/token/renew-self", http.Header{"X-Vault-Token": {b.token}}, map[string]any{}, nil)
}

// gatewayAPI sends OTPs through GatewayAPI's Messaging API (EU platform by default).
type smsSender func(ctx context.Context, phone, code string) error

// smsProvider is one SMS gateway; the server tries them in order (ID-03).
type smsProvider struct {
	name string
	send smsSender
}

// smsChain sends through the first provider that works: when one fails (out of credit, down,
// rejected), the next takes over. Errors never include the number (SEC-03).
// ponytail: a provider that times out after accepting can lead to a second SMS with the same code.
func smsChain(providers []smsProvider) smsSender {
	return func(ctx context.Context, phone, code string) error {
		var errs []error
		for _, p := range providers {
			err := p.send(ctx, phone, code)
			if err == nil {
				return nil
			}
			slog.Warn("sms provider failed, trying the next", "provider", p.name, "err", err)
			errs = append(errs, fmt.Errorf("%s: %w", p.name, err))
		}
		return errors.Join(errs...)
	}
}

// sevenURL is overridden in tests.
var sevenURL = "https://gateway.seven.io/api/sms"

// seven sends through seven.io. It answers HTTP 200 even on failure; the body's "success"
// code says what happened ("100" = accepted, "500" = no credit, ...).
func seven(key, sender string) smsSender {
	return func(ctx context.Context, phone, code string) error {
		form := url.Values{"to": {phone}, "text": {"Your Siegel code: " + code}, "from": {sender}}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, sevenURL, strings.NewReader(form.Encode()))
		if err != nil {
			return err
		}
		req.Header.Set("X-Api-Key", key)
		req.Header.Set("Accept", "application/json")
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		res, err := httpClient.Do(req)
		if err != nil {
			return err
		}
		defer res.Body.Close()
		if res.StatusCode/100 != 2 {
			return &statusError{sevenURL, res.StatusCode}
		}
		var out struct {
			Success json.RawMessage `json:"success"`
		}
		if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
			return err
		}
		if c := strings.Trim(string(out.Success), `"`); c != "100" {
			return fmt.Errorf("seven: code %s", c)
		}
		return nil
	}
}

func gatewayAPI(url, token, sender string) smsSender {
	return func(ctx context.Context, phone, code string) error {
		return postJSON(ctx, url, http.Header{"Authorization": {"Token " + token}}, map[string]any{
			"sender":    sender,
			"message":   "Your Siegel code: " + code,
			"recipient": json.Number(strings.TrimPrefix(phone, "+")),
		}, nil)
	}
}
