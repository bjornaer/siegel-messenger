//! Local storage. SQLCipher-encrypted SQLite (CRY-15, CLI-05) behind a trait so the web
//! client can swap in browser storage later (CLI-04).

use std::path::{Path, PathBuf};

pub type Result<T> = std::result::Result<T, rusqlite::Error>;

pub trait Store: Send {
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>>;
    fn put(&self, key: &str, value: &[u8]) -> Result<()>;
    /// Deletes everything on this device (ID-12, ID-16).
    fn wipe(self: Box<Self>) -> Result<()>;
}

pub struct SqlCipher {
    conn: rusqlite::Connection,
    path: PathBuf,
}

impl SqlCipher {
    /// `key` is 32 random bytes held in the iOS Keychain / Android Keystore by the app (CRY-15).
    pub fn open(path: &Path, key: &[u8; 32]) -> Result<Self> {
        let conn = rusqlite::Connection::open(path)?;
        // Raw key syntax: SQLCipher skips its passphrase KDF since the key is already random.
        let hex: String = key.iter().map(|b| format!("{b:02x}")).collect();
        conn.pragma_update(None, "key", format!("x'{hex}'"))?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL)",
        )?;
        Ok(Self {
            conn,
            path: path.to_owned(),
        })
    }
}

impl Store for SqlCipher {
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>> {
        match self
            .conn
            .query_row("SELECT value FROM kv WHERE key = ?1", [key], |r| r.get(0))
        {
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            r => r.map(Some),
        }
    }

    fn put(&self, key: &str, value: &[u8]) -> Result<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?1, ?2)",
            (key, value),
        )?;
        Ok(())
    }

    fn wipe(self: Box<Self>) -> Result<()> {
        let path = self.path.clone();
        drop(self.conn);
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypted_roundtrip_wrong_key_and_wipe() {
        let dir = std::env::temp_dir().join(format!("siegel-store-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("db");
        let s = SqlCipher::open(&path, &[1; 32]).unwrap();
        s.put("token", b"canary-secret").unwrap();
        assert_eq!(
            s.get("token").unwrap().as_deref(),
            Some(&b"canary-secret"[..])
        );
        assert_eq!(s.get("missing").unwrap(), None);
        drop(s);

        let raw = std::fs::read(&path).unwrap();
        assert!(
            !raw.windows(13).any(|w| w == b"canary-secret"),
            "plaintext on disk"
        );
        assert!(
            SqlCipher::open(&path, &[2; 32]).is_err(),
            "wrong key must fail"
        );

        let s: Box<dyn Store> = Box::new(SqlCipher::open(&path, &[1; 32]).unwrap());
        s.wipe().unwrap();
        assert!(!path.exists());
    }
}
