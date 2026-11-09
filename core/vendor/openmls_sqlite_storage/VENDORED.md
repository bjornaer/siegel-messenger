openmls_sqlite_storage 0.3.0 from crates.io, unchanged except rusqlite 0.37 → 0.41 and
refinery 0.9 → 0.10: 0.39 is the first rusqlite that builds for the browser (sqlite-wasm-rs),
and 0.41 bundles the SQLite fix for RUSTSEC-2026-0459. refinery 0.10 keeps 0.9's history table. Drop this copy and the [patch] once a release takes rusqlite ≥ 0.39.
