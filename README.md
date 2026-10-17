<p align="center">
  <img src="app/assets/icon/icon.png" alt="Siegel logo" width="140">
</p>

# Siegel Messenger

**Sealed. Not shared.** A private, end-to-end encrypted messenger, made in Europe.

Siegel ("seal" in German) keeps your messages on your phone and nowhere else. The server only passes
along sealed envelopes: it can't read messages, see names or photos, or tell who is in a group.

- **End-to-end encryption with MLS** ([RFC 9420](https://www.rfc-editor.org/rfc/rfc9420)), the open IETF
  standard, for every chat, one-to-one and groups (up to 256 members).
- **Your number stays private.** People find you by @username, QR code or link. Finding contacts by
  phone number is opt-in on both sides and uses an
  [OPRF](https://www.rfc-editor.org/rfc/rfc9497), so the server never sees your address book.
- **Nothing kept on the server.** Messages wait encrypted until your phone fetches them; attachments are
  deleted after 30 days. Message history lives only on your phone.
- **No trackers, no ads, no third-party SDKs** besides push notifications (FCM), which carry no content.
- Text, replies, reactions, edits, deletes, voice messages, photos, videos and files; groups with admins
  and invite links; safety numbers; app lock; English, Spanish, German and Portuguese.

Android today (closed testing on Google Play); iOS is planned.

## How it fits together

```
 Flutter app (UI)                         Go server (one process)
 └─ Rust core: MLS (OpenMLS), crypto,     ├─ registration, @usernames, key bundles
    encrypted database (SQLCipher),  ───► ├─ message queue + WebSocket, push wake-ups
    networking (protobuf over HTTPS)      ├─ encrypted attachment blobs (S3, SeaweedFS)
                                          └─ discovery (OPRF)
                                          PostgreSQL · OpenBao (secrets) · Let's Encrypt
```

| Path | What |
| --- | --- |
| `app/` | Flutter app (Android; iOS later) and the Rust bridge in `app/rust` |
| `core/` | Rust core: `core-crypto` (MLS, discovery), `core-media` (attachment encryption), `core-store` (SQLCipher), `core-net` (API client), `core-api` (what the app calls) |
| `server/` | Go API server ([Connect](https://connectrpc.com/) + WebSocket) |
| `proto/` | The API, as Protocol Buffers, shared by server and core |
| `docs/` | Threat model, deployment, discovery and number-change designs, Play Store notes |
| `compose.yaml` | Everything the server needs, for local development and for a single-VM deployment |

## Run it locally

You need Docker, Go, Rust (stable) and Flutter. Ports used: 58080 (API), 55432 (Postgres).

```sh
cp .env.example .env            # COMPOSE_PROFILES=localbao runs an in-memory OpenBao
docker compose up -d --build    # server, Postgres, SeaweedFS, OpenBao

# Tests
(cd server && SIEGEL_TEST_DATABASE_URL=postgres://postgres:siegel@localhost:55432/postgres go test ./...)
(cd core && cargo test && SIEGEL_TEST_SERVER_URL=http://localhost:58080 cargo test -p core-api --test e2e)
(cd app && flutter test)

# The app, on an Android emulator, against your local server
(cd app && flutter run --dart-define=SIEGEL_SERVER=http://10.0.2.2:58080)
```

Without an SMS provider configured, the server runs in dev mode and logs the verification code instead
of sending it: `docker compose logs server`.

## Host your own

Siegel is one central service by design (no federation), so your server is its own separate network:
its users can talk to each other, not to users of the official server. Everything you need is in this
repo.

**1. A server.** One small Linux VM is enough to start (2 vCPU, 4 GB). Install Docker, clone the repo to
`/opt/siegel`, and point a domain at it. The server gets its TLS certificate from Let's Encrypt by
itself; the app only trusts Let's Encrypt roots (certificate pinning), so keep it that way.

**2. Configure** `/opt/siegel/.env` (see `.env.example`; every setting has a default you can override):

| Setting | Why |
| --- | --- |
| `SIEGEL_DOMAIN` | Your domain; turns on HTTPS (TLS 1.3 only) |
| `POSTGRES_PASSWORD`, `S3_ACCESS_KEY`, `S3_SECRET_KEY` | Random values (`openssl rand -base64 32`) |
| `COMPOSE_PROFILES=bao`, `SIEGEL_BAO_*` | A persistent OpenBao holding the phone-number pepper and signing key |
| `SIEGEL_SEVEN_API_KEY` or `SIEGEL_GATEWAYAPI_TOKEN` | An SMS provider for verification codes |
| `SIEGEL_FCM_CREDENTIALS` | A Firebase service account (base64), for push wake-ups and Play Integrity |
| `SIEGEL_OPERATOR`, `SIEGEL_CONTACT_EMAIL` | Shown on the privacy policy page your server publishes at `/privacy` |

**3. Start it and set up OpenBao once**, following [docs/deploy.md](docs/deploy.md) step by step. Keep the
OpenBao unseal key offline: losing it means losing every account's phone-number mapping, with no way
back. After a reboot OpenBao starts sealed and needs that key again.

**4. Build the app for your server.** The official app only talks to the official server, so you
publish your own build:

- Change the application ID (`in.schlk.siegel` in `app/android/app/build.gradle.kts`) and the app name.
- Create a Firebase project for push and put its values in `app/lib/push.dart`; set your Google Cloud
  project number for Play Integrity in `MainActivity.kt`.
- Build with your server's address:
  ```sh
  cd app && flutter build appbundle --release --dart-define=SIEGEL_SERVER=https://your.domain
  ```
- For links that open in the app (`/u/…` and `/g/…`), set `SIEGEL_ANDROID_CERT_SHA256` to your signing
  certificate's SHA-256.

**5. Before real users:**

- Set `SIEGEL_DEV=0`. Compose defaults it to `1` (dev mode: no device attestation, SMS codes in the log),
  so leaving it out is not enough.
- Set the SMS daily budget (`SIEGEL_SMS_DAILY_CAP`) and keep an eye on it; SMS fraud is the main cost risk.
- Read [docs/threat-model.md](docs/threat-model.md): it says what a server operator can and cannot see,
  and what's still open (for example, backups are not yet encrypted at rest).
- You are the data controller for your users: publish your own privacy policy and terms.

Every push to `main` can deploy automatically over SSH once CI passes (see the `deploy` job in
`.github/workflows/ci.yml` and docs/deploy.md).

## Security

Found a vulnerability? Please email **privacy@schlk.in** rather than opening a public issue. The design
assumes a fully compromised server must not be able to read messages, profiles or group data
(see [docs/threat-model.md](docs/threat-model.md)). An external security audit is planned before public
launch.

## License

[GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0-only). If you run a modified version as a
service, your users must be able to get its source code (section 13). Contributions require agreeing to a
contributor licence agreement, so the app can also be published in app stores.
