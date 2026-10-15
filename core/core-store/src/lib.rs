//! Local storage. SQLCipher-encrypted SQLite (CRY-15, CLI-05) behind a trait so the web
//! client can swap in browser storage later (CLI-04).

use std::path::{Path, PathBuf};

use openmls_sqlite_storage::{Codec, SqliteStorageProvider};

pub type Result<T> = std::result::Result<T, rusqlite::Error>;

/// OpenMLS group state in the same encrypted database.
pub type MlsStorage<'a> = SqliteStorageProvider<JsonCodec, &'a rusqlite::Connection>;

#[derive(Default)]
pub struct JsonCodec;

impl Codec for JsonCodec {
    type Error = serde_json::Error;
    fn to_vec<T: serde::Serialize>(value: &T) -> std::result::Result<Vec<u8>, Self::Error> {
        serde_json::to_vec(value)
    }
    fn from_slice<T: serde::de::DeserializeOwned>(
        slice: &[u8],
    ) -> std::result::Result<T, Self::Error> {
        serde_json::from_slice(slice)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Conversation {
    pub group_id: Vec<u8>,
    pub peer_account: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Message {
    pub message_id: Vec<u8>,
    pub group_id: Vec<u8>,
    pub sender_account: Vec<u8>,
    pub sent_at: i64,
    /// The decrypted MSG-01 content payload. Never leaves the device.
    pub body: Vec<u8>,
    pub outgoing: bool,
}

/// MSG-15/16: someone who wrote to us first is a Request until we accept them.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ContactState {
    Request = 0,
    Accepted = 1,
    Blocked = 2,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Contact {
    pub account_id: Vec<u8>,
    pub state: ContactState,
    /// Their profile key, once they shared it (MSG-02 profile_key_update).
    pub profile_key: Option<Vec<u8>>,
    pub display_name: Option<String>,
    pub username: Option<String>,
}

pub trait Store: Send {
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>>;
    fn put(&self, key: &str, value: &[u8]) -> Result<()>;
    fn save_conversation(&self, c: &Conversation) -> Result<()>;
    fn conversations(&self) -> Result<Vec<Conversation>>;
    /// False when the message ID was already stored (MSG-03 deduplication).
    fn save_message(&self, m: &Message) -> Result<bool>;
    /// Oldest first, in arrival order (MSG-03).
    fn messages(&self, group_id: &[u8], limit: u32) -> Result<Vec<Message>>;
    fn contact(&self, account_id: &[u8]) -> Result<Option<Contact>>;
    fn save_contact(&self, c: &Contact) -> Result<()>;
    fn contacts(&self) -> Result<Vec<Contact>>;
    /// Removes a conversation and its messages from this device (declined request, MSG-12).
    fn delete_conversation(&self, group_id: &[u8]) -> Result<()>;
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
            "CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL);
             CREATE TABLE IF NOT EXISTS conversations (group_id BLOB PRIMARY KEY, peer_account BLOB NOT NULL);
             CREATE TABLE IF NOT EXISTS messages (
               seq INTEGER PRIMARY KEY AUTOINCREMENT,
               message_id BLOB NOT NULL UNIQUE,
               group_id BLOB NOT NULL,
               sender_account BLOB NOT NULL,
               sent_at INTEGER NOT NULL,
               body BLOB NOT NULL,
               outgoing INTEGER NOT NULL);
             CREATE INDEX IF NOT EXISTS messages_group ON messages (group_id, seq);
             CREATE TABLE IF NOT EXISTS contacts (
               account_id BLOB PRIMARY KEY,
               state INTEGER NOT NULL,
               profile_key BLOB,
               display_name TEXT,
               username TEXT);",
        )?;
        let mut conn = conn;
        SqliteStorageProvider::<JsonCodec, &mut rusqlite::Connection>::new(&mut conn)
            .run_migrations()
            .map_err(|e| {
                rusqlite::Error::InvalidParameterName(format!("openmls migrations: {e}"))
            })?;
        Ok(Self {
            conn,
            path: path.to_owned(),
        })
    }

    fn contacts_where(&self, filter: &str, arg: &[u8]) -> Result<Vec<Contact>> {
        let mut q = self.conn.prepare(&format!(
            "SELECT account_id, state, profile_key, display_name, username FROM contacts {filter}"
        ))?;
        q.query_map([arg], |r| {
            Ok(Contact {
                account_id: r.get(0)?,
                state: match r.get::<_, i64>(1)? {
                    1 => ContactState::Accepted,
                    2 => ContactState::Blocked,
                    _ => ContactState::Request,
                },
                profile_key: r.get(2)?,
                display_name: r.get(3)?,
                username: r.get(4)?,
            })
        })?
        .collect()
    }

    pub fn mls(&self) -> MlsStorage<'_> {
        SqliteStorageProvider::new(&self.conn)
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

    fn save_conversation(&self, c: &Conversation) -> Result<()> {
        self.conn.execute(
            "INSERT OR IGNORE INTO conversations (group_id, peer_account) VALUES (?1, ?2)",
            (&c.group_id, &c.peer_account),
        )?;
        Ok(())
    }

    fn conversations(&self) -> Result<Vec<Conversation>> {
        let mut q = self
            .conn
            .prepare("SELECT group_id, peer_account FROM conversations")?;
        q.query_map([], |r| {
            Ok(Conversation {
                group_id: r.get(0)?,
                peer_account: r.get(1)?,
            })
        })?
        .collect()
    }

    fn save_message(&self, m: &Message) -> Result<bool> {
        let n = self.conn.execute(
            "INSERT OR IGNORE INTO messages (message_id, group_id, sender_account, sent_at, body, outgoing)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            (&m.message_id, &m.group_id, &m.sender_account, m.sent_at, &m.body, m.outgoing),
        )?;
        Ok(n == 1)
    }

    fn messages(&self, group_id: &[u8], limit: u32) -> Result<Vec<Message>> {
        let mut q = self.conn.prepare(
            "SELECT message_id, group_id, sender_account, sent_at, body, outgoing FROM (
               SELECT * FROM messages WHERE group_id = ?1 ORDER BY seq DESC LIMIT ?2) ORDER BY seq",
        )?;
        q.query_map((group_id, limit), |r| {
            Ok(Message {
                message_id: r.get(0)?,
                group_id: r.get(1)?,
                sender_account: r.get(2)?,
                sent_at: r.get(3)?,
                body: r.get(4)?,
                outgoing: r.get(5)?,
            })
        })?
        .collect()
    }

    fn contact(&self, account_id: &[u8]) -> Result<Option<Contact>> {
        Ok(self
            .contacts_where("WHERE account_id = ?1", account_id)?
            .pop())
    }

    fn save_contact(&self, c: &Contact) -> Result<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO contacts (account_id, state, profile_key, display_name, username)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            (&c.account_id, c.state as i64, &c.profile_key, &c.display_name, &c.username),
        )?;
        Ok(())
    }

    fn contacts(&self) -> Result<Vec<Contact>> {
        self.contacts_where("WHERE ?1 IS NOT NULL", &[])
    }

    fn delete_conversation(&self, group_id: &[u8]) -> Result<()> {
        self.conn
            .execute("DELETE FROM messages WHERE group_id = ?1", [group_id])?;
        self.conn
            .execute("DELETE FROM conversations WHERE group_id = ?1", [group_id])?;
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

        let s = SqlCipher::open(&path, &[1; 32]).unwrap();
        let m = Message {
            message_id: vec![1],
            group_id: vec![9],
            sender_account: vec![2],
            sent_at: 5,
            body: b"hi".to_vec(),
            outgoing: false,
        };
        assert!(s.save_message(&m).unwrap());
        assert!(!s.save_message(&m).unwrap(), "MSG-03: duplicate ignored");
        assert!(
            s.save_message(&Message {
                message_id: vec![2],
                ..m.clone()
            })
            .unwrap()
        );
        let got = s.messages(&[9], 10).unwrap();
        assert_eq!((got.len(), got[0].message_id.clone()), (2, vec![1]));
        assert_eq!(
            s.messages(&[9], 1).unwrap()[0].message_id,
            vec![2],
            "limit keeps the newest"
        );

        let c = Contact {
            account_id: vec![2],
            state: ContactState::Request,
            profile_key: None,
            display_name: None,
            username: Some("bob".into()),
        };
        s.save_contact(&c).unwrap();
        s.save_contact(&Contact {
            state: ContactState::Blocked,
            ..c.clone()
        })
        .unwrap();
        assert_eq!(
            s.contact(&[2]).unwrap().unwrap().state,
            ContactState::Blocked
        );
        assert_eq!(s.contacts().unwrap().len(), 1);
        assert_eq!(s.contact(&[3]).unwrap(), None);
        s.delete_conversation(&[9]).unwrap();
        assert!(s.messages(&[9], 10).unwrap().is_empty());

        let s: Box<dyn Store> = Box::new(s);
        s.wipe().unwrap();
        assert!(!path.exists());
    }
}
