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

Deploys leave OpenBao running (unchanged containers are not recreated), so no unseal is needed,
unless a commit bumps the OpenBao image.

Backups land in `/opt/siegel/backups` (one copy each, overwritten daily). They do not include
OpenBao: your offline unseal key plus the `baodata` volume are what matter there.

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
2. On your laptop: `base64 -i key.json | tr -d '\n' | pbcopy`, then paste it into
   `/opt/siegel/.env` as `SIEGEL_FCM_CREDENTIALS=...` and `docker compose up -d server`.
3. Delete `key.json` from your laptop (keep an offline copy only if you want one; you can
   always generate a new key and delete the old one in the console).
4. Without it, a server in dev mode logs `dev push stub` instead of pushing.

