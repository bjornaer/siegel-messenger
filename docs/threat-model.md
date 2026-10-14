# Siegel Messenger threat model (SEC-09)

Status: M1 draft, 2026-10-14. Covers the v1 design in the requirements spec and what is built so far
(server identity slice, Hetzner docker compose deployment). Revisit at every milestone and before the
external audit (SEC-10).

## Assets

| ID | Asset | Where it lives | Requirement |
| --- | --- | --- | --- |
| A1 | Message and attachment plaintext | Sender and recipient phones only | TRUST-01 |
| A2 | Profile name, picture, group name/avatar/members/roles | Phones; server holds only ciphertext | TRUST-01, GRP-03 |
| A3 | Account Identity private key, MLS device keys | Phone (Keychain/Keystore, SQLCipher DB) | CRY-06, CRY-15 |
| A4 | Phone numbers | Server sees in transit at registration; stores HMAC only | ID-05 |
| A5 | Social graph (who talks to whom) | Transiently on server (recipient lists, IPs) | MSG-10, SEC-03 |
| A6 | Server secrets: phone pepper, AS signing key, OPRF key | Server host | SEC-05 |
| A7 | Account control (device token, Registration Lock PIN) | Phone; server stores token hash, Argon2id PIN hash | ID-10 |
| A8 | Service availability and SMS budget | Server, SMS provider | ID-02, ID-04 |
| A9 | Backups of PostgreSQL and the S3 bucket | `BACKUP_DIR` on the Hetzner host, overwritten each run | compose.yaml |

## Adversaries

### T1 Server operator or full server compromise

Can read the database, object store, backups, memory and logs, and change server code.

- Cannot read A1/A2: MLS ciphertext and client-side attachment encryption (CRY-01, MED-01).
- Can attempt to insert a rogue device or key for a user. Mitigated only by safety-number verification
  (CRY-12, CRY-13). Unverified users are exposed; key transparency is roadmap (SEC-12).
- Sees A5 transiently: recipient of each message, online status, IPs at connection. Sealed sender hides the
  sender (MSG-10). Mitigation is policy (no logging, SEC-03), not cryptography.
- **A4 via A6.** Phone HMACs are reversible by brute force once the pepper is known (the number space is small).
  The pepper is a non-exportable OpenBao transit key on a separate server (`siegel-bao`), so a stolen
  DB or backup cannot be brute-forced offline. An attacker *inside* the API host can still call the
  HMAC endpoint while they hold access (an online oracle); OpenBao's audit log and the token's narrow
  policy are the controls there.
- The AS signing key is also in OpenBao transit. A compromised API host can request signatures (mint
  credential bindings, CRY-08) while it has access. Clients still check the Account Identity signature,
  so this helps only together with the unverified-key attack above.

### T2 Network attacker

On-path between phone and server.

- TLS 1.3 only (ARCH-02) plus certificate pinning with a backup pin (SEC-06, client work).
- Sees connection timing and sizes. Padding hides exact lengths (CRY-05, MED-02); traffic analysis is
  otherwise out of scope for v1.
- Production sets `SIEGEL_DOMAIN`: TLS 1.3 only with Let's Encrypt certificates (autocert). Without it
  the server speaks plaintext h2c, which is for local development only.
- API → OpenBao traffic is plaintext on the Hetzner private network. Acceptable while the network holds
  only our two servers; add TLS to the listener if that changes.

### T3 Malicious group member

A legitimate member with a modified client.

- Unauthorised commits (removing members, changing roles): every client validates permissions from the
  MLS group state and rejects them (GRP-07, AC-10).
- Keeps copies of messages or attachments: unpreventable. "Delete for everyone" must not promise more (MSG-11).
- Removed member reading later messages: prevented by MLS epoch change (CRY-11, AC-03).
- Spam and abuse: Message requests, blocking, reporting (MSG-15, MSG-16, CMP-03, CMP-04).

### T4 Thief with the phone

- **Locked phone:** keys are in Keychain/Keystore and the DB is SQLCipher (CRY-15), so the data stays protected
  as long as the OS holds. App-switcher previews are hidden (ID-15).
- **Unlocked phone:** full access to chats while unlocked, unless the optional app lock is on (ID-15).
  The real owner re-registers on a new phone, which revokes the stolen device (ID-09, ID-12).

### T5 SIM-swap attacker

Takes over the victim's phone number and receives the OTP.

- Without Registration Lock: can re-register and take the account and @username. Old device revoked;
  contacts see a key-change notice (CRY-13). No history is exposed (messages are device-only).
- With Registration Lock: needs the 4-digit PIN. 10 attempts, then a 24 h lockout (ID-10): at most ~10
  guesses/day of 10,000. **The lock lapses after 7 days without the victim's device being seen.** A victim
  whose phone is off for a week (travel, lost phone) loses the protection. This is a deliberate trade-off for
  owner recovery (spec ID-10); the 7-day value is a [default] awaiting confirmation (Q10).
- Argon2id hash in the DB makes offline PIN cracking expensive but not impossible (4 digits = 10^4).
  Server compromise (T1) therefore defeats the PIN; the PIN is an online control only.

### T6 Automated abuse (SMS pumping, enumeration)

- SMS pumping: device attestation (ID-02, **not yet implemented; server refuses non-dev mode until it is**),
  3/number/hour, 10/IP/hour in memory, global daily cap, prefix denylist (ID-04).
- Username enumeration: exact-match lookup only (ID-08). There is no lookup rate limit yet; add one if
  scraping by dictionary shows up.
- Phone discovery enumeration: OPRF rate limits (DISC-06, M5).

### T7 Hosting provider / backup holder

Hetzner (EU, D8) has physical and hypervisor access to the host.

- Equivalent to T1 for data at rest on `siegel-api`: DB, bucket, backups and `.env` share one machine.
  The pepper and AS key sit on `siegel-bao`, a separate VM, but with the same provider.
- Backups (A9) hold the same data as the live DB (phone HMACs, token hashes, queued ciphertext). They are
  overwritten each run, so with `BACKUP_INTERVAL` <= 24 h deleted accounts leave the backups within 24 h
  (ID-16). Backups are not encrypted at rest. Use an encrypted volume or move them off-host
  encrypted before launch.

## Open risks (tracked)

| Risk | Severity | Fix | Ref |
| --- | --- | --- | --- |
| No device attestation (`SIEGEL_DEV=1`) | High (cost) | App Attest / Play Integrity; low SMS cap until then | ID-02 |
| OpenBao sealed after reboot, manual unseal | Medium (availability) | Accepted; auto-unseal needs a cloud KMS | SEC-05 |
| Lost OpenBao unseal key loses the pepper | High (data) | Offline copies of the unseal key | SEC-05 |
| API → OpenBao plaintext on private network | Low | TLS listener if the network is shared | SEC-05 |
| Unverified key substitution by server | Medium | Safety numbers now, key transparency later | SEC-12 |
| Backups unencrypted on host | Medium | Encrypted volume / encrypted off-host copy | A9 |
| Registration Lock lapse after 7 days | Accepted | Product decision | ID-10 |
| No username lookup rate limit | Low | Add if abused | ID-08 |
