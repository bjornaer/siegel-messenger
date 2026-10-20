# M8 part 3: can the Rust core run in the browser?

**Verdict: go.** Each blocker has a known fix, and the hard ones (MLS, encrypted
storage) have been shown to work. Cost: about one part of work in the core
before the Flutter web app (part 4) can start.

Evidence: branch `spike/wasm`, workflow `spike-wasm` (Ubuntu, clang + lld,
`wasm32-unknown-unknown`).

## What was checked

| Piece | Result | How |
|---|---|---|
| core-crypto (OpenMLS, age, identity keys) | **builds** | `openmls` feature `js`; getrandom 0.2 `js`, 0.4 `wasm_js`; `RUSTFLAGS=--cfg getrandom_backend="wasm_js"` |
| core-media | **builds** | getrandom 0.2 `js` |
| Encrypted SQLite | **builds and runs** (node, wasm-bindgen-test) | see below |
| core-store as it is | fails | `bundled-sqlcipher-vendored-openssl` pulls in openssl-sys |
| core-net as it is | fails | ring, tokio sockets, tokio-tungstenite, rustls with pinned roots |
| core-api | not tried | depends on the two above |

### Encrypted storage

On wasm, rusqlite 0.40 doesn't use libsqlite3-sys. It uses sqlite-wasm-rs and
silently **ignores** `bundled-sqlcipher`. A build that looks fine is
unencrypted, and `PRAGMA key` does nothing.

What works: also depend on `sqlite-wasm-rs` with the `sqlite3mc` feature
(SQLite3 Multiple Ciphers), then before the key:

```
PRAGMA cipher = 'sqlcipher'; PRAGMA legacy = 4; PRAGMA key = "x'…'";
```

The spike test checks all of this:
- `PRAGMA cipher` answers `sqlcipher`;
- `sqlite3mc_version()` exists;
- data written can be read back with the right key;
- a wrong key gets "file is not a database".

The key can't be set on `:memory:`; it must be a named file.

Building it needs a wasm-capable clang. CI has one. The Mac doesn't (Apple
clang can't target wasm; `brew install llvm` fixes that).

For data that lasts across visits, the browser needs sqlite-wasm-rs's OPFS VFS
(`opfs-sahpool`). That VFS runs only in a web worker. The spike used the
default memory VFS.

## What part 4 has to change in the core

1. **core-store:** pick the SQLite per target. Native keeps
   `bundled-sqlcipher-vendored-openssl`. wasm uses rusqlite plus
   `sqlite-wasm-rs/sqlite3mc` with the pragmas above, and registers the OPFS
   VFS.
2. **core-net, unary calls:** reqwest already has a fetch backend on wasm.
   Leave out the rustls / pinned-roots client setup there.
3. **core-net, stream:** the one `stream()` (tokio TCP + tungstenite, about
   100 lines) gets a browser WebSocket twin (web-sys or gloo-net) with the
   same `next` / `ack`.
4. **core-api:**
   - swap tokio time (sleep/timeout in chat, devices, groups) for a small
     cfg'd helper (gloo-timers on wasm);
   - put the `std::fs` uses (media, stickers, lib) behind native-only cfgs,
     since web has no files and media stays in memory or the database.
5. **core-crypto / core-media:** the wasm target dependencies proven on the
   branch. They change nothing for native builds.

## Limits we accept on the web

- **No certificate pinning (SEC-06).** The browser does TLS. Our own code
  can't pin certificates there. What protects web users instead:
  - MLS end to end;
  - the pinned AS key (CRY-08);
  - safety numbers;
  - CSP, SRI and published hashes of the web app (part 5).
- **The key at rest is weaker than on the phone.** There's no Keystore in the
  browser, so the database key is wrapped by the PIN (W3) and kept in
  IndexedDB. Someone who steals the browser profile can attack the PIN
  offline. Mitigations:
  - a slow KDF (argon2id);
  - the 14-day unlink;
  - the phone can unlink the device at any time.

## flutter_rust_bridge on the web (not exercised yet)

The bridge itself couldn't be tried yet, because core-api doesn't build for
wasm (see above). This section comes from frb 2.x's documentation:
- `flutter_rust_bridge_codegen build-web` builds with wasm-pack;
- threads need nightly Rust (`-Z build-std`, atomics);
- the page must be cross-origin isolated (COOP `same-origin`, COEP
  `require-corp`) for SharedArrayBuffer. web.siegel.schlk.in sets these
  headers in part 5.

This is the main thing left that could still go wrong. If threads become a
problem, the fallback is frb's single-threaded mode, since all our work is
async anyway.

## Sizes (release, unoptimised, no wasm-opt)

- SQLite3MC alone: 2.0 MB `.wasm`.
- core-crypto rlib: 1.0 MB.
- Expect roughly 4–6 MB in total before wasm-opt and compression.
