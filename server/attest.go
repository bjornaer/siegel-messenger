package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strconv"
	"time"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
)

// playIntegrityBase is overridden in tests.
var playIntegrityBase = "https://playintegrity.googleapis.com"

// androidPackage is the app the Play Integrity verdict must name.
const androidPackage = "in.schlk.siegel"

// playIntegrity checks the device attestation that must precede every SMS (ID-02). The app
// binds its token to the number via requestHash = hex(SHA-256(E.164)), so a token can't be
// replayed for another number. Accepted: a Play-recognized install on a device that meets
// basic device integrity, with a token at most 10 minutes old.
// ponytail: iOS is rejected until App Attest ships with the iOS app.
func playIntegrity(g *googleAccount) func(context.Context, siegelv1.Platform, string, string) error {
	decode := playIntegrityBase + "/v1/" + androidPackage + ":decodeIntegrityToken"
	return func(ctx context.Context, platform siegelv1.Platform, phone, token string) error {
		if platform != siegelv1.Platform_PLATFORM_ANDROID || token == "" {
			return errors.New("no attestation for this platform")
		}
		b, err := g.bearer(ctx)
		if err != nil {
			return err
		}
		var res struct {
			TokenPayloadExternal struct {
				RequestDetails struct {
					RequestPackageName string
					RequestHash        string
					TimestampMillis    string
				}
				AppIntegrity struct {
					AppRecognitionVerdict string
				}
				DeviceIntegrity struct {
					DeviceRecognitionVerdict []string
				}
			}
		}
		if err := postJSON(ctx, decode, http.Header{"Authorization": {"Bearer " + b}},
			map[string]string{"integrityToken": token}, &res); err != nil {
			return err
		}
		v := res.TokenPayloadExternal
		sum := sha256.Sum256([]byte(phone))
		ms, _ := strconv.ParseInt(v.RequestDetails.TimestampMillis, 10, 64)
		age := time.Since(time.UnixMilli(ms))
		switch {
		case v.RequestDetails.RequestPackageName != androidPackage:
			return errors.New("attestation: wrong package")
		case v.RequestDetails.RequestHash != hex.EncodeToString(sum[:]):
			return errors.New("attestation: token is for another request")
		case age > 10*time.Minute || age < -time.Minute:
			return fmt.Errorf("attestation: token age %s", age.Round(time.Second))
		case v.AppIntegrity.AppRecognitionVerdict != "PLAY_RECOGNIZED":
			return fmt.Errorf("attestation: app %s", v.AppIntegrity.AppRecognitionVerdict)
		case !slices.Contains(v.DeviceIntegrity.DeviceRecognitionVerdict, "MEETS_DEVICE_INTEGRITY"):
			return errors.New("attestation: device integrity not met")
		}
		return nil
	}
}
