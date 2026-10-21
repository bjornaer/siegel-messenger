# Deploying to Hetzner

**Test setup: one server.** Everything from `compose.yaml` runs on a single Hetzner Cloud VM:
API server, PostgreSQL, SeaweedFS, backups and a persistent OpenBao (`COMPOSE_PROFILES=bao`).
Every push to `main` that passes CI deploys it over SSH.

> Docker-published ports bypass `ufw`. That is why `compose.yaml` binds Postgres and S3 to 127.0.0.1,
> leaves OpenBao unpublished, and why the Hetzner Cloud Firewall (outside the VM) is the one that matters.

## 1. Hetzner

1. Security → SSH keys: add your personal key.
2. Firewalls → `fw-siegel`: inbound TCP 22 from your IP, TCP 80 and 443 from anywhere.
3. Server: Ubuntu 24.04, the smallest type (ARM `CAX` or x86 `CX`; every image we use is multi-arch),
   firewall `fw-siegel`. No private network needed.
4. DNS at your registrar: `A siegel.schlk.in → <server IPv4>` and `AAAA → <server IPv6>`.

## 2. Server

```sh
ssh root@<server>
curl -fsSL https://get.docker.com | sh
adduser --disabled-password --gecos "" deploy && usermod -aG docker deploy
mkdir -p /opt/siegel && chown deploy: /opt/siegel
sudo -u deploy git clone https://github.com/bjornaer/siegel-messenger.git /opt/siegel
cd /opt/siegel && sudo -u deploy cp .env.example .env && chmod 600 .env
```

Edit `/opt/siegel/.env`:

```sh
COMPOSE_PROFILES=bao
POSTGRES_PASSWORD=   # openssl rand -base64 32
S3_ACCESS_KEY=       # openssl rand -hex 16
S3_SECRET_KEY=       # openssl rand -base64 32
SIEGEL_DOMAIN=siegel.schlk.in
SIEGEL_HTTP_PORT=80
SIEGEL_HTTPS_PORT=443
SIEGEL_BAO_ADDR=http://bao:8200
SIEGEL_BAO_TOKEN=    # step 3
SIEGEL_GATEWAYAPI_TOKEN=   # section 4; leave empty to log OTPs instead (docker compose logs server)
SIEGEL_SMS_DAILY_CAP=50
```

## 3. OpenBao (once)

```sh
cd /opt/siegel && sudo -u deploy docker compose up -d --build
B() { docker compose exec -e BAO_ADDR=http://127.0.0.1:8200 "$@"; }
B bao bao operator init -key-shares=1 -key-threshold=1
```

**Store the unseal key and root token offline (password manager plus paper). Losing the unseal key
means losing the pepper, and with it every account's phone mapping. There is no recovery.**

```sh
B bao bao operator unseal                                   # paste the unseal key
B -e BAO_TOKEN=<root token> bao /bao-setup.sh
B -e BAO_TOKEN=<root token> bao bao token create -policy=siegel-server -period=768h -orphan -field=token
#   -> put it in .env as SIEGEL_BAO_TOKEN, then:
B -e BAO_TOKEN=<root token> bao bao token revoke -self
sudo -u deploy docker compose up -d                         # server picks up the token
```

**After every reboot or OpenBao restart, OpenBao is sealed.** The API answers `internal` to registration
until you run `B bao bao operator unseal`. Data is safe meanwhile. Need root again later:
`bao operator generate-root` with the unseal key.

Check it end to end; the first HTTPS request also fetches the Let's Encrypt certificate:

```sh
curl -XPOST https://siegel.schlk.in/siegel.v1.RegistrationService/RequestOtp \
  -H 'Content-Type: application/json' -d '{"phoneE164":"+34600000000"}'   # {} = OK
```

## 4. GatewayAPI

1. Check which platform the account is on. EU (`gatewayapi.eu`) is the default. For a `.com`
   account set `SIEGEL_GATEWAYAPI_URL=https://messaging.gatewayapi.com/mobile/single`.
2. Create an API token and paste it only into `/opt/siegel/.env` (`SIEGEL_GATEWAYAPI_TOKEN`). Never commit it.
3. Add prepaid credit and a low-balance alert, so a pumping attack hits a ceiling you chose.
4. Restrict destination countries to the launch countries if the dashboard offers it (Q2).
5. Sender ID is `Siegel` (`SIEGEL_SMS_SENDER`). Check whether your launch countries require
   alphanumeric sender registration; until it is approved, some carriers replace or drop the sender.
6. Sign their data processing agreement (CMP-07).
7. Fallback: with `SIEGEL_SEVEN_API_KEY` set (a seven.io API key), codes go out through seven.io
   whenever GatewayAPI fails, for example once its credit runs out. `SIEGEL_SMS_PROVIDERS`
   sets the order (`gatewayapi,seven` by default; `seven,gatewayapi` makes seven.io first).
   The server log names the provider that failed, never the number.

## 5. Automatic deploys

1. On your laptop: `ssh-keygen -t ed25519 -N "" -f siegel-deploy`.
2. On the server, as `deploy`, add to `~/.ssh/authorized_keys` (one line). The forced command means
   this key can only run the deploy script, never a shell:
   ```
   command="/opt/siegel/scripts/deploy.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA... siegel-deploy
   ```
3. GitHub → Settings → Environments → `production`:
   - secret `DEPLOY_SSH_KEY`: contents of `siegel-deploy` (the private key);
   - secret `DEPLOY_KNOWN_HOSTS`: output of `ssh-keyscan -t ed25519 <server IPv4>`;
   - variable `DEPLOY_HOST`: `<server IPv4>`. The deploy job is skipped until this is set.

Schema changes ship as numbered files in `server/migrations/` (`NNNN_what.sql`). The server
applies the ones a database hasn't had at startup, each in one transaction, and records them in
`schema_migrations`. Never edit a file that has shipped; add a new one. Write each statement so it can run twice
(`ADD COLUMN IF NOT EXISTS`, `CREATE ... IF NOT EXISTS`): a test replays them all on an existing database. A migration that fails
rolls back and stops the server from starting: the deploy job fails and the API is down until a
fix ships (`docker compose logs server` names the file).

Deploys leave OpenBao running (unchanged containers are not recreated), so no unseal is needed,
unless a commit bumps the OpenBao image.

## Siegel Web: web.siegel.schlk.in (M8)

The web app is static files that CI builds (job `web`) and the deploy job sends along
(`ssh deploy@host web < siegel-web.tar.gz`). `scripts/deploy.sh` unpacks each release into
`/opt/siegel/web-site/releases/<commit>` and points `web-site/current` at it in one step, keeping the
last three. The server serves it on its own host name and certificate, under strict headers:
- CSP: our scripts and WebAssembly only, no eval; connections only to the API;
- cross-origin isolated (the core's threads need it);
- no framing.
Fonts are mirrored at build time, so nothing loads from a third party.

To turn it on, once:
1. DNS: an `A` record for `web.siegel.schlk.in` to the server's IPv4 (same as `siegel.schlk.in`).
2. In `/opt/siegel/.env`: `SIEGEL_WEB_ORIGIN=https://web.siegel.schlk.in`, then
   `docker compose up -d server`. The certificate comes on the first visit.

Until both are done the API serves no site, and the browser can't call it (no CORS).

3. Notifications for closed tabs (Web Push), optional: on the server, run
   `docker compose exec server /server admin vapid-keygen` and put the line it prints
   (`SIEGEL_VAPID_KEY=…`) in `/opt/siegel/.env`, then `docker compose up -d server`. Keep it:
   a new key silently ends every browser's subscription. The pushes carry nothing, and go only
   to the browsers' own push services (Google, Mozilla, Apple, Microsoft).

**Checking the served code.** Each release's `.well-known/siegel-web-manifest.txt` lists every
file's SHA-256, and GitHub attests the manifest (Sigstore: which commit, which workflow).
`scripts/verify-web.sh` checks the attestation and every served file; `/transparency` shows the
manifest hash being served. **Roll back:** `ln -sfn releases/<older> web-site/current` (no restart needed).

## Backups

Backups land in `/opt/siegel/backups` (one copy each, overwritten daily). They do not include
OpenBao: your offline unseal key plus the `baodata` volume are what matter there.

The database dump is encrypted with [age](https://age-encryption.org) to a key whose private half
never touches the server (threat model T7):

1. On your laptop: `brew install age && age-keygen -o siegel-backup.key`. Store the file like the
   unseal key: password manager plus an offline copy. Without it the backups can't be read.
2. On the server, put the printed public key in `.env` as `BACKUP_AGE_RECIPIENT=age1...`, then
   `docker compose up -d postgres-backup`. Its log says `postgres backup ok (postgres.dump.age)`, and
   the old plain `postgres.dump` is deleted.
3. The encrypted file can safely leave the host: `scp root@<host>:/opt/siegel/backups/postgres.dump.age .`

Restore (try it once a quarter, on your laptop, so you know the key works):

```sh
age -d -i siegel-backup.key postgres.dump.age > postgres.dump
pg_restore --list postgres.dump | head                 # the drill: it lists the tables
pg_restore -h <db> -U postgres -d siegel --clean postgres.dump   # a real restore
```

The bucket mirror (`backups/bucket`) stays plain: attachments are encrypted by the apps with keys the
server never has (MED-03), so it holds only ciphertext.

## Moderators' key (reports, M7)

Reports are sealed by the reporter's app to this key; only its private half opens them.

1. On your laptop: `age-keygen -o siegel-reports.key`. Keep it offline, like the backup key, and
   never put it on a server.
2. In the server `.env`: `SIEGEL_REPORTS_AGE_RECIPIENT=age1...` (the public line), then
   `docker compose up -d server`. Until it's set, the app says reporting isn't available yet.
3. To read a report by hand, until the console (Part 5) exists:
   `psql ... -tAc "SELECT encode(sealed,'base64') FROM reports WHERE id = N" | base64 -d | age -d -i siegel-reports.key`
   gives the `Report` protobuf (`proto/siegel/v1/reports.proto`).

`core/core-api/tests/reports-test.key` is a test-only key for the e2e tests. Never set its public
half in production.

## Moderation: `siegel-admin` (M7)

Moderator actions run from a shell on the server, never over the API. Each needs a reason, tells
the account why in the app, and writes a row to the hash-chained audit log:

```sh
cd /opt/siegel
A="docker compose exec server /server admin"
$A suspend --days 7 --rule harassment --reason "threats to another user" --by max @someone
$A unsuspend --reason "appeal accepted" --by max @someone
$A ban --rule child_safety --reason "…" --by max @someone          # for good; --days N for a set time
$A remove-username --rule impersonation --reason "looks like staff" --by max @siegel_help
$A remove-link --reason "removal order 2026/123" --by max <link id hex>
$A remove-blob --reason "removal order 2026/123" --by max <blob id hex>
$A audit --verify --last 50
$A issue-code --reason "SMS not arriving; owner confirmed by phone call" --by max +34611223344
```

`issue-code` is for when a sign-up SMS doesn't arrive. It prints a fresh 10-minute code. **Give it
only to someone you've confirmed owns that number** (in person, or by calling that exact number):
the code is what proves ownership, so whoever gets it can take over an account on that number that
has no Registration Lock. It's audited under the number's hash, never the number.

Rules: spam, harassment, hate, child_safety, non_consensual, violence, impersonation, other.

### The web console

The same actions, plus the report queue and in-browser decryption. It listens only on the server's
loopback, so it is reached through SSH:

1. Once per operator: `$A console-enrol max` prints a single-use link (30 minutes).
2. On your laptop: `ssh -L 9443:127.0.0.1:9443 root@<server>`, then open the link in a browser on
   the same laptop and create a passkey (Touch ID, your phone, or a security key).
3. From then on: keep the tunnel open and go to `http://localhost:9443`.
4. On a report, load `siegel-reports.key`. It is read in the page and never uploaded; closing the
   tab forgets it.

The browser needs to be from 2024 or newer, because older ones lack the WebAuthn JSON helpers.

### Alerts on your phone

Child-safety and threat reports must be reviewed within 24 hours, so the server posts an alert to
`SIEGEL_ALERT_WEBHOOK`. The alert carries only the report's category, never who or what. The
simplest setup: install the ntfy app, subscribe to a long random topic name, and set
`SIEGEL_ALERT_WEBHOOK=https://ntfy.sh/<that topic>` in `.env`. SMS-pumping alerts arrive there too.

### Procedures

`docs/child-safety.md` covers reports about children; `docs/law-enforcement.md` covers requests from
authorities and appeals. A
banned number can't register again; its @username stays taken for good. The web console (M7
part 5) runs the same actions.

## Key rotation (SEC-05)

| Key | Rotates | How |
| --- | --- | --- |
| OPRF key (DISC-05) | Every `SIEGEL_DISCOVERY_KEY_DAYS` (90), by itself | Derived from the pepper and the period number. Apps on the old period get `period_changed` and check again. Nothing to do. |
| OpenBao server token | Before its 32-day period lapses unused (the server renews it hourly), or on suspicion | Create a new one as in step 3, put it in `.env`, `docker compose up -d server`, then `bao token revoke <old>`. |
| PostgreSQL password | On suspicion | `ALTER USER postgres PASSWORD '...'` in psql, update `POSTGRES_PASSWORD` in `.env`, `docker compose up -d`. |
| S3 keys | On suspicion | Change `S3_ACCESS_KEY`/`S3_SECRET_KEY` in `.env`, `docker compose up -d`. |
| Backup age key | On suspicion | New key pair as above; old backups stay readable with the old key until overwritten (a day). |
| Phone pepper (ID-05) | Never routinely | Every phone HMAC, pending code and discovery entry is keyed with it, and the server doesn't know the numbers to rehash them. The server is pinned to key version 1, so a `transit/keys/siegel-phone/rotate` by mistake changes nothing. If it ever leaked, rotating wouldn't protect what an attacker already copied; it would need a lazy re-key (look up v1 or v2, rewrite on the next verification), which isn't built. |
| AS signing key (CRY-08) | Never routinely | Apps store the AS public key at registration and check every member's credential against it. The server signs and publishes version 1 only, so an accidental rotate changes nothing. A real rotation needs apps that trust more than one AS key, which isn't built. |

Device tokens are stored as hashes; a lost phone is cut off by re-registering the number (ID-09).

## Until device attestation ships (ID-02)

The server runs with `SIEGEL_DEV=1`, which **disables attestation**. With a real SMS token, anyone can
make the server send SMS, limited only by 3/number/hour, 10/IP/hour and `SIEGEL_SMS_DAILY_CAP`.
Keep the cap low and the GatewayAPI balance small until App Attest and Play Integrity land.

## Before public launch: split OpenBao out

On one server the pepper sits on the same machine as the database, so a host compromise exposes
phone numbers again (threat model T1). Before launch:

1. Second VM `siegel-bao` on a Hetzner private network, firewall allowing only SSH from your IP.
2. Run OpenBao there with `infra/openbao/bao.hcl`, publishing `-p <private IP>:8200:8200`.
3. Migrate the keys: either move the `baodata` volume as-is (same unseal key), or init fresh and
   re-register test accounts (a new pepper orphans existing ones).
4. In `.env`: drop `COMPOSE_PROFILES`, set `SIEGEL_BAO_ADDR=http://<private IP>:8200`.

## 6. App store review account

Store reviewers can't receive our SMS, so one number can be given a fixed code.

1. Pick a number nobody uses and that can't be someone's real phone: for example one from
   a range your telecom regulator reserves for fiction or testing in the launch country,
   otherwise a number you own.
2. Set `SIEGEL_REVIEW_PHONE` (E.164) and `SIEGEL_REVIEW_CODE` (6 random digits) in
   `/opt/siegel/.env`, then `docker compose up -d server`. That number never gets an SMS and
   doesn't count against the SMS cap.
3. Give both to the store in the review notes. Anyone who learns them can register that
   number, so it must never hold a real person's account. Rotate the code after each review.

## 7. Push notifications (FCM)

1. Firebase console → Project settings → Service accounts → Generate new private key. This
   key can send pushes to every install: treat it like the GatewayAPI token.
2. On your laptop: `openssl base64 -A -in key.json | pbcopy`, then paste it into
   `/opt/siegel/.env` as `SIEGEL_FCM_CREDENTIALS=...` and `docker compose up -d server`.
3. Delete `key.json` from your laptop (keep an offline copy only if you want one; you can
   always generate a new key and delete the old one in the console).
4. Without it, a server in dev mode logs `dev push stub` instead of pushing.

## 8. Log retention (SEC-03)

Server logs can name an account ID, so they may be kept 7 days at most. Docker keeps logs
forever by default, so production logs go to journald with a 7-day limit:

```sh
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nMaxRetentionSec=7day\n' > /etc/systemd/journald.conf.d/siegel.conf
systemctl restart systemd-journald
echo 'LOG_DRIVER=journald' >> /opt/siegel/.env
cd /opt/siegel && docker compose up -d server
```

Read them with `journalctl CONTAINER_NAME=siegel-server-1 --since today`.

