# Deploying to Hetzner

Two Hetzner Cloud servers on one private network:

| Server | Runs | Public ports |
| --- | --- | --- |
| `siegel-api` | `compose.yaml`: API server, PostgreSQL, SeaweedFS, backups | 22 (your IP), 80, 443 |
| `siegel-bao` | OpenBao (phone pepper, AS signing key) | 22 (your IP) only |

Every push to `main` that passes CI deploys `siegel-api` over SSH. OpenBao is set up once by hand.

> Docker-published ports bypass `ufw`. That is why `compose.yaml` binds Postgres, S3 and OpenBao to
> 127.0.0.1 and why the Hetzner Cloud Firewall (outside the VM) is the one that matters.

## 1. GitHub

1. Create the repository `bjornaer/siegel-messenger` (public, D15) and push `main`.
2. Repository → Settings → Environments → create `production`.
3. Keep `DEPLOY_HOST` unset until step 3.6; the deploy job is skipped while it is empty.

## 2. Hetzner Cloud

1. New project → Security → SSH keys: add your personal key.
2. Networks → create `siegel-net`, `10.0.0.0/16`.
3. Firewalls → `fw-api`: inbound TCP 22 from your IP, TCP 80 and 443 from anywhere.
   `fw-bao`: inbound TCP 22 from your IP only.
   (Cloud Firewalls do not filter the private network, so the API reaches OpenBao over `10.0.0.x`.)
4. Servers (Ubuntu 24.04, same location, attach `siegel-net`; region is open question Q8):
   - `siegel-api`: CX22 or CAX11, firewall `fw-api`.
   - `siegel-bao`: smallest type, firewall `fw-bao`.
   Note each private IP (below: API `10.0.0.2`, Bao `10.0.0.3`).
5. DNS at your registrar: `A siegel.schlk.in → <siegel-api IPv4>` and `AAAA → <siegel-api IPv6>`.

## 3. `siegel-api`

```sh
ssh root@<siegel-api>
curl -fsSL https://get.docker.com | sh
adduser --disabled-password --gecos "" deploy && usermod -aG docker deploy
mkdir -p /opt/siegel && chown deploy: /opt/siegel
sudo -u deploy git clone https://github.com/bjornaer/siegel-messenger.git /opt/siegel
sudo -u deploy cp /opt/siegel/.env.example /opt/siegel/.env && chmod 600 /opt/siegel/.env
```

1. Edit `/opt/siegel/.env`:
   - delete the `COMPOSE_PROFILES=localbao` line (production uses the separate OpenBao);
   - `POSTGRES_PASSWORD`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`: `openssl rand -base64 32` each;
   - `SIEGEL_DOMAIN=siegel.schlk.in`, `SIEGEL_HTTP_PORT=80`, `SIEGEL_HTTPS_PORT=443`;
   - `SIEGEL_BAO_ADDR=http://10.0.0.3:8200`, `SIEGEL_BAO_TOKEN=<from section 4>`;
   - `SIEGEL_GATEWAYAPI_TOKEN=<from section 5>`, `SIEGEL_SMS_DAILY_CAP=50`.
2. Deploy key, used only by CI. On your laptop: `ssh-keygen -t ed25519 -N "" -f siegel-deploy`.
3. On the server, as `deploy`, add to `~/.ssh/authorized_keys` (one line). The forced command means this
   key can only run the deploy script, never a shell:
   ```
   command="/opt/siegel/scripts/deploy.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA... siegel-deploy
   ```
4. First deploy by hand: `sudo -u deploy /opt/siegel/scripts/deploy.sh`. The first HTTPS request
   gets the Let's Encrypt certificate: `curl -XPOST https://siegel.schlk.in/siegel.v1.RegistrationService/RequestOtp -H 'Content-Type: application/json' -d '{}'`
   should return `invalid_argument`.
5. GitHub `production` environment → secrets:
   - `DEPLOY_SSH_KEY`: contents of `siegel-deploy` (private key);
   - `DEPLOY_KNOWN_HOSTS`: output of `ssh-keyscan -t ed25519 <siegel-api IPv4>`.
6. GitHub → variables: `DEPLOY_HOST=<siegel-api IPv4>`. From now on green `main` deploys itself.

Backups land in `/opt/siegel/backups` (one copy each, overwritten daily). Copy them off the box
encrypted if you want disaster recovery (threat model T7).

## 4. `siegel-bao`

```sh
ssh root@<siegel-bao>
curl -fsSL https://get.docker.com | sh
mkdir -p /opt/bao && cd /opt/bao
curl -fsSLO https://raw.githubusercontent.com/bjornaer/siegel-messenger/main/infra/openbao/bao.hcl
curl -fsSLO https://raw.githubusercontent.com/bjornaer/siegel-messenger/main/scripts/bao-setup.sh && chmod +x bao-setup.sh
docker run -d --name openbao --restart unless-stopped -p 10.0.0.3:8200:8200 \
  -v /opt/bao/bao.hcl:/openbao/config/bao.hcl:ro -v /opt/bao/bao-setup.sh:/bao-setup.sh:ro -v baodata:/openbao/file \
  openbao/openbao:2.4.1 server -config=/openbao/config/bao.hcl
alias bao='docker exec -it -e BAO_ADDR=http://127.0.0.1:8200 openbao bao'
bao operator init -key-shares=1 -key-threshold=1
```

**Store the unseal key and root token offline (password manager plus paper). Losing the unseal key
means losing the pepper, and with it every account's phone mapping. There is no recovery.**

```sh
bao operator unseal                       # paste the unseal key
docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN=<root token> openbao /bao-setup.sh
docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN=<root token> openbao \
  bao token create -policy=siegel-server -period=768h -orphan -field=token   # -> SIEGEL_BAO_TOKEN
docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN=<root token> openbao bao token revoke -self
```

The server renews its token hourly; the 32-day period only matters if the API is down that long.
Need root again later: `bao operator generate-root` with the unseal key.

**After every reboot or container restart OpenBao is sealed and the API cannot register users until
you run `bao operator unseal`.** Auto-unseal needs a cloud KMS, which Hetzner does not offer.

## 5. GatewayAPI

1. Check which platform the account is on. EU (`gatewayapi.eu`) is the default. For a `.com`
   account set `SIEGEL_GATEWAYAPI_URL=https://messaging.gatewayapi.com/mobile/single`.
2. Create an API token and paste it only into `/opt/siegel/.env` on `siegel-api`
   (`SIEGEL_GATEWAYAPI_TOKEN`). Never commit it.
3. Add prepaid credit and a low-balance alert, so a pumping attack hits a ceiling you chose.
4. Restrict destination countries to the launch countries if the dashboard offers it (Q2).
5. Sender ID is `Siegel` (`SIEGEL_SMS_SENDER`). Check whether your launch countries require
   alphanumeric sender registration; until it is approved, some carriers replace or drop the sender.
6. Sign their data processing agreement (CMP-07).

## Until device attestation ships (ID-02)

The server runs with `SIEGEL_DEV=1`, which **disables attestation**. With a real SMS token that means
anyone can make the server send SMS, limited only by 3/number/hour, 10/IP/hour and
`SIEGEL_SMS_DAILY_CAP`. Keep the cap low and the GatewayAPI balance small until App Attest and Play
Integrity land.
