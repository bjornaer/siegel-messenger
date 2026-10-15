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

/// A chat. `group_id` is its stable local ID (the first MLS group's ID); `mls_group` is the
/// MLS group we currently send in, which changes when the peer re-registers (ID-09).
#[derive(Debug, Clone, PartialEq)]
pub struct Conversation {
    pub group_id: Vec<u8>,
    pub peer_account: Vec<u8>,
    pub mls_group: Vec<u8>,
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
    pub status: Status,
    /// MSG-09: earlier versions are kept, see `versions`.
    pub edited: bool,
    /// MSG-11: the body is already erased.
    pub deleted: bool,
}

/// MSG-04 for outgoing messages; incoming ones are Delivered until read. Ordered, so a
/// receipt only moves a message forward.
#[derive(Debug, Clone, Copy, PartialEq, PartialOrd)]
pub enum Status {
    Failed = 0,
    Sending = 1,
    Sent = 2,
    Delivered = 3,
    Read = 4,
}

impl Status {
    fn from_i64(v: i64) -> Self {
        match v {
            0 => Self::Failed,
            1 => Self::Sending,
            2 => Self::Sent,
            4 => Self::Read,
            _ => Self::Delivered,
        }
    }
}

/// MSG-15/16: someone who wrote to us first is a Request until we accept them.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum ContactState {
    #[default]
    Request = 0,
    Accepted = 1,
    Blocked = 2,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Contact {
    pub account_id: Vec<u8>,
    pub state: ContactState,
    /// Their profile key, once they shared it (MSG-02 profile_key_update).
    pub profile_key: Option<Vec<u8>>,
    pub display_name: Option<String>,
    pub username: Option<String>,
    /// Their Account Identity Key as first seen (CRY-13 compares later ones against it).
    pub identity_key: Option<Vec<u8>>,
    /// Safety number checked in person (CRY-12); cleared when the key changes.
    pub verified: bool,
}

pub trait Store: Send {
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>>;
    fn put(&self, key: &str, value: &[u8]) -> Result<()>;
    fn save_conversation(&self, c: &Conversation) -> Result<()>;
    fn conversations(&self) -> Result<Vec<Conversation>>;
    /// The chat an MLS group belongs to; old groups stay mapped so late messages still land.
    fn conversation_for_mls(&self, mls_group: &[u8]) -> Result<Option<Vec<u8>>>;
    /// Makes `mls_group` the one the chat sends in.
    fn set_mls_group(&self, group_id: &[u8], mls_group: &[u8]) -> Result<()>;
    /// Every MLS group the chat ever used.
    fn mls_groups(&self, group_id: &[u8]) -> Result<Vec<Vec<u8>>>;
    /// False when the message ID was already stored (MSG-03 deduplication).
    fn save_message(&self, m: &Message) -> Result<bool>;
    /// Oldest first, in arrival order (MSG-03).
    fn messages(&self, group_id: &[u8], limit: u32) -> Result<Vec<Message>>;
    fn message(&self, message_id: &[u8]) -> Result<Option<Message>>;
    /// Rewrites body, status and the edited/deleted flags; deleting also drops reactions
    /// and earlier versions.
    fn update_message(&self, m: &Message) -> Result<()>;
    /// MSG-12 delete for me, with its reactions and earlier versions.
    fn delete_message(&self, message_id: &[u8]) -> Result<()>;
    /// Moves our messages in the group forward to `status` (receipts); never backwards.
    fn advance_status(
        &self,
        group_id: &[u8],
        message_ids: &[Vec<u8>],
        status: Status,
    ) -> Result<()>;
    /// Marks incoming messages read and returns their IDs.
    fn mark_read(&self, group_id: &[u8]) -> Result<Vec<Vec<u8>>>;
    /// MSG-09: keeps a superseded body.
    fn save_version(&self, message_id: &[u8], body: &[u8]) -> Result<()>;
    /// Superseded bodies, oldest first.
    fn versions(&self, message_id: &[u8]) -> Result<Vec<Vec<u8>>>;
    /// MSG-08: one reaction per account; empty removes it.
    fn set_reaction(&self, message_id: &[u8], account: &[u8], emoji: &str) -> Result<()>;
    fn reactions(&self, message_id: &[u8]) -> Result<Vec<(Vec<u8>, String)>>;
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
        // Schema changes after the first release, applied once each (PRAGMA user_version).
        const MIGRATIONS: &[&str] = &[
            "ALTER TABLE messages ADD COLUMN status INTEGER NOT NULL DEFAULT 3;
             ALTER TABLE messages ADD COLUMN edited INTEGER NOT NULL DEFAULT 0;
             ALTER TABLE messages ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0;
             CREATE TABLE reactions (message_id BLOB NOT NULL, account BLOB NOT NULL,
               emoji TEXT NOT NULL, PRIMARY KEY (message_id, account));
             CREATE TABLE versions (seq INTEGER PRIMARY KEY AUTOINCREMENT,
               message_id BLOB NOT NULL, body BLOB NOT NULL);
             CREATE INDEX versions_message ON versions (message_id);",
            "ALTER TABLE contacts ADD COLUMN identity_key BLOB;
             ALTER TABLE contacts ADD COLUMN verified INTEGER NOT NULL DEFAULT 0;
             ALTER TABLE conversations ADD COLUMN mls_group BLOB;
             UPDATE conversations SET mls_group = group_id;
             CREATE TABLE mls_groups (mls_group BLOB PRIMARY KEY, conversation BLOB NOT NULL);
             INSERT INTO mls_groups SELECT group_id, group_id FROM conversations;",
        ];
        let version: usize = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        for (i, m) in MIGRATIONS.iter().enumerate().skip(version) {
            conn.execute_batch(&format!(
                "BEGIN; {m} PRAGMA user_version = {}; COMMIT;",
                i + 1
            ))?;
        }
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
            "SELECT account_id, state, profile_key, display_name, username, identity_key, verified
             FROM contacts {filter}"
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
                identity_key: r.get(5)?,
                verified: r.get(6)?,
            })
        })?
        .collect()
    }

    fn messages_where(&self, filter: &str, params: impl rusqlite::Params) -> Result<Vec<Message>> {
        let mut q = self.conn.prepare(&format!(
            "SELECT message_id, group_id, sender_account, sent_at, body, outgoing, status, edited, deleted
             FROM messages {filter}"
        ))?;
        q.query_map(params, |r| {
            Ok(Message {
                message_id: r.get(0)?,
                group_id: r.get(1)?,
                sender_account: r.get(2)?,
                sent_at: r.get(3)?,
                body: r.get(4)?,
                outgoing: r.get(5)?,
                status: Status::from_i64(r.get(6)?),
                edited: r.get(7)?,
                deleted: r.get(8)?,
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
            "INSERT OR IGNORE INTO conversations (group_id, peer_account, mls_group) VALUES (?1, ?2, ?3)",
            (&c.group_id, &c.peer_account, &c.mls_group),
        )?;
        self.conn.execute(
            "INSERT OR IGNORE INTO mls_groups (mls_group, conversation) VALUES (?1, ?2)",
            (&c.mls_group, &c.group_id),
        )?;
        Ok(())
    }

    fn conversations(&self) -> Result<Vec<Conversation>> {
        let mut q = self
            .conn
            .prepare("SELECT group_id, peer_account, mls_group FROM conversations")?;
        q.query_map([], |r| {
            Ok(Conversation {
                group_id: r.get(0)?,
                peer_account: r.get(1)?,
                mls_group: r.get(2)?,
            })
        })?
        .collect()
    }

    fn conversation_for_mls(&self, mls_group: &[u8]) -> Result<Option<Vec<u8>>> {
        match self.conn.query_row(
            "SELECT conversation FROM mls_groups WHERE mls_group = ?1",
            [mls_group],
            |r| r.get(0),
        ) {
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            r => r.map(Some),
        }
    }

    fn set_mls_group(&self, group_id: &[u8], mls_group: &[u8]) -> Result<()> {
        self.conn.execute(
            "UPDATE conversations SET mls_group = ?2 WHERE group_id = ?1",
            (group_id, mls_group),
        )?;
        self.conn.execute(
            "INSERT OR REPLACE INTO mls_groups (mls_group, conversation) VALUES (?1, ?2)",
            (mls_group, group_id),
        )?;
        Ok(())
    }

    fn mls_groups(&self, group_id: &[u8]) -> Result<Vec<Vec<u8>>> {
        let mut q = self
            .conn
            .prepare("SELECT mls_group FROM mls_groups WHERE conversation = ?1")?;
        q.query_map([group_id], |r| r.get(0))?.collect()
    }

    fn save_message(&self, m: &Message) -> Result<bool> {
        let n = self.conn.execute(
            "INSERT OR IGNORE INTO messages
               (message_id, group_id, sender_account, sent_at, body, outgoing, status, edited, deleted)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            rusqlite::params![
                &m.message_id,
                &m.group_id,
                &m.sender_account,
                m.sent_at,
                &m.body,
                m.outgoing,
                m.status as i64,
                m.edited,
                m.deleted
            ],
        )?;
        Ok(n == 1)
    }

    fn messages(&self, group_id: &[u8], limit: u32) -> Result<Vec<Message>> {
        let mut m = self.messages_where(
            "WHERE group_id = ?1 ORDER BY seq DESC LIMIT ?2",
            (group_id, limit),
        )?;
        m.reverse();
        Ok(m)
    }

    fn message(&self, message_id: &[u8]) -> Result<Option<Message>> {
        Ok(self
            .messages_where("WHERE message_id = ?1", [message_id])?
            .pop())
    }

    fn update_message(&self, m: &Message) -> Result<()> {
        self.conn.execute(
            "UPDATE messages SET body = ?2, status = ?3, edited = ?4, deleted = ?5 WHERE message_id = ?1",
            (&m.message_id, &m.body, m.status as i64, m.edited, m.deleted),
        )?;
        if m.deleted {
            // MSG-11: nothing of a deleted message stays behind.
            for t in ["reactions", "versions"] {
                self.conn.execute(
                    &format!("DELETE FROM {t} WHERE message_id = ?1"),
                    [&m.message_id],
                )?;
            }
        }
        Ok(())
    }

    fn delete_message(&self, message_id: &[u8]) -> Result<()> {
        for t in ["messages", "reactions", "versions"] {
            self.conn.execute(
                &format!("DELETE FROM {t} WHERE message_id = ?1"),
                [message_id],
            )?;
        }
        Ok(())
    }

    fn advance_status(
        &self,
        group_id: &[u8],
        message_ids: &[Vec<u8>],
        status: Status,
    ) -> Result<()> {
        for id in message_ids {
            self.conn.execute(
                "UPDATE messages SET status = ?3
                 WHERE message_id = ?1 AND group_id = ?2 AND outgoing = 1 AND status < ?3",
                (id, group_id, status as i64),
            )?;
        }
        Ok(())
    }

    fn mark_read(&self, group_id: &[u8]) -> Result<Vec<Vec<u8>>> {
        let mut q = self.conn.prepare(
            "UPDATE messages SET status = 4 WHERE group_id = ?1 AND outgoing = 0 AND status < 4
             RETURNING message_id",
        )?;
        q.query_map([group_id], |r| r.get(0))?.collect()
    }

    fn save_version(&self, message_id: &[u8], body: &[u8]) -> Result<()> {
        self.conn.execute(
            "INSERT INTO versions (message_id, body) VALUES (?1, ?2)",
            (message_id, body),
        )?;
        Ok(())
    }

    fn versions(&self, message_id: &[u8]) -> Result<Vec<Vec<u8>>> {
        let mut q = self
            .conn
            .prepare("SELECT body FROM versions WHERE message_id = ?1 ORDER BY seq")?;
        q.query_map([message_id], |r| r.get(0))?.collect()
    }

    fn set_reaction(&self, message_id: &[u8], account: &[u8], emoji: &str) -> Result<()> {
        if emoji.is_empty() {
            self.conn.execute(
                "DELETE FROM reactions WHERE message_id = ?1 AND account = ?2",
                (message_id, account),
            )?;
        } else {
            self.conn.execute(
                "INSERT OR REPLACE INTO reactions (message_id, account, emoji) VALUES (?1, ?2, ?3)",
                (message_id, account, emoji),
            )?;
        }
        Ok(())
    }

    fn reactions(&self, message_id: &[u8]) -> Result<Vec<(Vec<u8>, String)>> {
        let mut q = self
            .conn
            .prepare("SELECT account, emoji FROM reactions WHERE message_id = ?1")?;
        q.query_map([message_id], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect()
    }

    fn contact(&self, account_id: &[u8]) -> Result<Option<Contact>> {
        Ok(self
            .contacts_where("WHERE account_id = ?1", account_id)?
            .pop())
    }

    fn save_contact(&self, c: &Contact) -> Result<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO contacts
               (account_id, state, profile_key, display_name, username, identity_key, verified)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            (
                &c.account_id,
                c.state as i64,
                &c.profile_key,
                &c.display_name,
                &c.username,
                &c.identity_key,
                c.verified,
            ),
        )?;
        Ok(())
    }

    fn contacts(&self) -> Result<Vec<Contact>> {
        self.contacts_where("WHERE ?1 IS NOT NULL", &[])
    }

    fn delete_conversation(&self, group_id: &[u8]) -> Result<()> {
        for t in ["reactions", "versions"] {
            self.conn.execute(
                &format!(
                    "DELETE FROM {t} WHERE message_id IN (SELECT message_id FROM messages WHERE group_id = ?1)"
                ),
                [group_id],
            )?;
        }
        self.conn
            .execute("DELETE FROM messages WHERE group_id = ?1", [group_id])?;
        self.conn
            .execute("DELETE FROM conversations WHERE group_id = ?1", [group_id])?;
        self.conn
            .execute("DELETE FROM mls_groups WHERE conversation = ?1", [group_id])?;
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
            status: Status::Delivered,
            edited: false,
            deleted: false,
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
        s.update_message(&Message {
            body: b"edited".to_vec(),
            edited: true,
            ..m.clone()
        })
        .unwrap();
        assert!(s.message(&[1]).unwrap().unwrap().edited);
        assert_eq!(
            s.messages(&[9], 1).unwrap()[0].message_id,
            vec![2],
            "limit keeps the newest"
        );

        // Receipts only move our own messages forward; mark_read returns what it changed.
        let mine = Message {
            message_id: vec![3],
            outgoing: true,
            status: Status::Sent,
            ..m.clone()
        };
        s.save_message(&mine).unwrap();
        s.advance_status(&[9], &[vec![3], vec![1]], Status::Read)
            .unwrap();
        s.advance_status(&[9], &[vec![3]], Status::Delivered)
            .unwrap();
        assert_eq!(s.message(&[3]).unwrap().unwrap().status, Status::Read);
        assert_eq!(s.message(&[1]).unwrap().unwrap().status, Status::Delivered);
        assert_eq!(s.mark_read(&[9]).unwrap(), vec![vec![1], vec![2]]);
        assert!(s.mark_read(&[9]).unwrap().is_empty());
        s.set_reaction(&[1], &[2], "👍").unwrap();
        s.set_reaction(&[1], &[2], "❤️").unwrap();
        assert_eq!(s.reactions(&[1]).unwrap(), vec![(vec![2], "❤️".into())]);
        s.save_version(&[1], b"old").unwrap();
        assert_eq!(s.versions(&[1]).unwrap(), vec![b"old".to_vec()]);
        s.delete_message(&[1]).unwrap();
        assert!(s.message(&[1]).unwrap().is_none());
        assert!(s.reactions(&[1]).unwrap().is_empty() && s.versions(&[1]).unwrap().is_empty());
        drop(s);
        let s = SqlCipher::open(&path, &[1; 32]).unwrap(); // migrations run only once

        let c = Contact {
            account_id: vec![2],
            state: ContactState::Request,
            profile_key: None,
            username: Some("bob".into()),
            ..Default::default()
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
        s.save_conversation(&Conversation {
            group_id: vec![9],
            peer_account: vec![2],
            mls_group: vec![9],
        })
        .unwrap();
        s.set_mls_group(&[9], &[10]).unwrap();
        assert_eq!(s.conversations().unwrap()[0].mls_group, vec![10]);
        assert_eq!(
            s.conversation_for_mls(&[9]).unwrap(),
            Some(vec![9]),
            "old group still maps"
        );
        assert_eq!(s.conversation_for_mls(&[10]).unwrap(), Some(vec![9]));
        assert_eq!(s.mls_groups(&[9]).unwrap().len(), 2);
        s.delete_conversation(&[9]).unwrap();
        assert_eq!(s.conversation_for_mls(&[10]).unwrap(), None);
        assert!(s.messages(&[9], 10).unwrap().is_empty());

        let s: Box<dyn Store> = Box::new(s);
        s.wipe().unwrap();
        assert!(!path.exists());
    }
}
