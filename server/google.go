package main

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// googleAccount signs in to Google APIs as a service account (FCM, Play Integrity).
type googleAccount struct {
	project string
	bearer  func(context.Context) (string, error)
}

// Scopes for everything the server calls: push (SRV-05) and attestation (ID-02).
const googleScopes = "https://www.googleapis.com/auth/firebase.messaging https://www.googleapis.com/auth/playintegrity"

func googleAuth(credentials []byte) (*googleAccount, error) {
	var sa struct {
		ProjectID   string `json:"project_id"`
		ClientEmail string `json:"client_email"`
		PrivateKey  string `json:"private_key"`
		TokenURI    string `json:"token_uri"`
	}
	if err := json.Unmarshal(credentials, &sa); err != nil {
		return nil, err
	}
	block, _ := pem.Decode([]byte(sa.PrivateKey))
	if block == nil {
		return nil, errors.New("google: no private key")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := k.(*rsa.PrivateKey)
	if !ok || sa.ProjectID == "" || sa.ClientEmail == "" || sa.TokenURI == "" {
		return nil, errors.New("google: incomplete service account")
	}
	var (
		mu      sync.Mutex
		access  string
		expires time.Time
	)
	// OAuth 2.0 JWT bearer grant (RFC 7523), cached until shortly before it expires.
	bearer := func(ctx context.Context) (string, error) {
		mu.Lock()
		defer mu.Unlock()
		if time.Now().Before(expires) {
			return access, nil
		}
		now := time.Now()
		enc := base64.RawURLEncoding.EncodeToString
		head, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT"})
		claims, _ := json.Marshal(map[string]any{
			"iss": sa.ClientEmail, "aud": sa.TokenURI, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix(),
			"scope": googleScopes,
		})
		unsigned := enc(head) + "." + enc(claims)
		sum := sha256.Sum256([]byte(unsigned))
		sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, sum[:])
		if err != nil {
			return "", err
		}
		form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {unsigned + "." + enc(sig)}}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, sa.TokenURI, strings.NewReader(form.Encode()))
		if err != nil {
			return "", err
		}
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		res, err := httpClient.Do(req)
		if err != nil {
			return "", err
		}
		defer res.Body.Close()
		var tok struct {
			AccessToken string `json:"access_token"`
			ExpiresIn   int    `json:"expires_in"`
		}
		if res.StatusCode != http.StatusOK {
			return "", fmt.Errorf("google oauth: status %d", res.StatusCode)
		}
		if err := json.NewDecoder(res.Body).Decode(&tok); err != nil {
			return "", err
		}
		access, expires = tok.AccessToken, now.Add(time.Duration(tok.ExpiresIn)*time.Second-time.Minute)
		return access, nil
	}
	return &googleAccount{project: sa.ProjectID, bearer: bearer}, nil
}
