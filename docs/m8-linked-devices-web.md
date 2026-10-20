# M8: Linked devices and Siegel Web, plan

Status: parts 1–4 built (2026-10-20). AAB and web release at the end.

## Decided

| # | Question | Decision |
| --- | --- | --- |
| W1 | History on a newly linked device | None. It sees messages from the moment it's linked (like Signal's default). |
| W2 | How many | Up to 4 linked devices per phone. The phone stays primary: it links and unlinks them. |
| W3 | Web sign-in | Stays linked, but a PIN of 4 to 6 digits unlocks it each time the tab opens. Unlinked automatically after 14 days unused. |
| W4 | Address | `web.siegel.schlk.in`, static files only. The API stays at `siegel.schlk.in`. |

## What exists already

- The server keeps devices per account, and KeyPackage claims return one per device. The MLS core
  already puts every device of an account in a group as its own member, so messages fan out to all
  of a person's devices.
- Re-registration already swaps one account's devices in every group (AC-05). Adding a linked device
  is the same commit, without the removal.

## Parts

### Part 1: Linking (server, core, phone)

1. **The browser starts:** it makes a fresh MLS signing key and an X25519 key, and asks the server
   for a link ID (`LinkService.Begin`). It shows a QR code: `siegel-link:<id>#<x25519 pub>.<signing pub>`.
2. **The phone scans it**, shows "Link this browser?", and on yes:
   - signs a device credential for the browser's signing key with the account identity key (the
     same binding phone devices have, CRY-08);
   - seals a bundle to the browser's X25519 key: account ID, credential, profile key, contacts
     (names, usernames, profile keys), blocked list, settings;
   - calls `LinkService.Approve(id, sealed)`.
3. **The server** creates the device (at most 4 linked per account) and gives the browser its token
   and the sealed bundle once (`LinkService.Wait`, long poll, 2 minutes).
4. **The phone** adds the new device to every chat and group it's in (one commit per conversation,
   built on the AC-05 code). Contacts' apps add it to new chats as they would any device.
5. **Settings → Linked devices:** each device's name and last active day; Unlink revokes it (ID-13
   removes it from every group).

Done when: e2e links a second headless client to an account and both receive a message sent to the
account, and unlinking stops delivery.

### Part 2: Keeping your devices in step

A private MLS group of your own devices carries sync messages:
- contacts accepted, blocked or unblocked;
- profile and avatar changes;
- message requests accepted;
- read state ("read up to");
- deleted chats and archive or mute settings.

What you send from one device reaches your others already, through MLS (part 1).

Done when: e2e changes each of these on one device and sees it on the other.

### Part 3: Spike, the core in a browser (1 to 2 days, then go or no-go)

The Rust core compiled to WebAssembly:
- **Storage:** SQLite on the browser's private file system (`sqlite-wasm-rs`), encrypted with a key
  wrapped by the PIN (WebCrypto, non-extractable).
- **Network:** fetch and browser WebSockets in place of reqwest and tungstenite.
- **Crypto:** OpenMLS and our crates on wasm32.

Output: a report on what works, the bundle size, and any blocker, before Part 4 starts.

### Part 4: Siegel Web

- The same Flutter app built for the web. Android-only features (contacts discovery, share-to-Siegel,
  photo picker details) are hidden or replaced.
- The browser's link screen with the QR code, then the PIN set-up and the PIN lock.
- Unlinked after 14 days unused (W3). The server expires the device; the page forgets everything.

**Built (part 4):**
- The core builds for the browser:
  - SQLite3 Multiple Ciphers in the SQLCipher format, kept in IndexedDB (relaxed-idb);
  - fetch;
  - the browser's WebSocket, with the token sent as a subprotocol;
  - clocks and timers that work in the browser;
  - attachments kept in the encrypted database.
  `openmls_sqlite_storage` is vendored with rusqlite 0.39 until upstream releases its bump.
- The web start: choose a PIN, show the link QR, then the usual app.
  - The database key is wrapped by the PIN (argon2id 19 MiB × 2, AES-256-GCM) in localStorage.
  - Ten wrong PINs, or 14 days unused, and the browser forgets everything. The server also drops
    linked devices unseen for 14 days.
- A linked device:
  - can't delete the account (server enforced);
  - can unlink itself;
  - its Settings hide number, discovery and linking.
- Hidden in the browser until part 6: camera scanning, phone contacts, sending and playing video,
  voice notes, notifications.
- CI job `web` builds the site (`flutter_rust_bridge build-web`, then `flutter build web`) and keeps
  it as an artifact.

### Part 5: Hosting `web.siegel.schlk.in`

- A static file server in compose, its own TLS certificate, nothing but the built app.
- **Headers:**
  - a strict Content-Security-Policy: our own scripts and the API's origin only;
  - Subresource Integrity on every script;
  - cross-origin isolation (needed by WebAssembly threads);
  - no third-party anything.
- The API accepts the web origin through CORS and checks WebSocket origins.
- **Each release publishes the hash of its files** (in the repo and on `/transparency`), so anyone can
  check the served code is the published code. This is the main protection a web client can offer
  against a server that would serve different code.

### Part 6: Notifications and polish

- Web Push (VAPID) for new messages while the tab is closed. Content-free, like the phone's pushes.
- Desktop layout: the chat list beside the open chat.
- Privacy policy and terms updates for linked devices.

## Risks

- **Code served by a server can be changed by that server.** Signal ships no web app for this reason.
  Published hashes (Part 5) let people check, but most won't. The terms and privacy policy will say so
  plainly.
- **Browser storage can be cleared by the browser.** The device then has to be linked again, and
  history (none by W1) is lost.
- **Part 3 can say no.** If encrypted storage or the core's size doesn't work in the browser, we stop
  there and decide again.
