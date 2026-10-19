//! The sticker collection: stickers made from photos, saved from chats, or imported in packs.
//! Kept in the encrypted database like messages; sending one is an ordinary attachment.

use sha2::{Digest, Sha256};

use crate::{CoreError, SiegelCore};

const INDEX: &str = "stickers";
/// WhatsApp's limits are 100 KB static and 500 KB animated; leave some room.
const MAX_STICKER: usize = 1 << 20;

/// One sticker in the collection. `pack` is empty for "My stickers".
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Sticker {
    pub id: String,
    pub pack: String,
    pub mime_type: String,
}

fn data_key(id: &str) -> String {
    format!("sticker:{id}")
}

impl SiegelCore {
    fn sticker_index(&self) -> Result<Vec<Sticker>, CoreError> {
        Ok(self
            .get(INDEX)?
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default())
    }

    fn save_sticker_index(&self, all: &[Sticker]) -> Result<(), CoreError> {
        let b = serde_json::to_vec(all).map_err(|_| CoreError::new("storage"))?;
        self.put(INDEX, &b)
    }

    /// Adds a WebP or PNG sticker to `pack` ("" for my own). The same image twice is kept once.
    pub fn add_sticker(
        &self,
        data: &[u8],
        mime_type: &str,
        pack: &str,
    ) -> Result<Sticker, CoreError> {
        if data.is_empty()
            || data.len() > MAX_STICKER
            || !matches!(mime_type, "image/webp" | "image/png")
        {
            return Err(CoreError::new("sticker_invalid"));
        }
        let id: String = Sha256::digest(data)[..12]
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let mut all = self.sticker_index()?;
        if let Some(s) = all.iter().find(|s| s.id == id && s.pack == pack) {
            return Ok(s.clone());
        }
        self.put(&data_key(&id), data)?;
        let s = Sticker {
            id,
            pack: pack.into(),
            mime_type: mime_type.into(),
        };
        all.push(s.clone());
        self.save_sticker_index(&all)?;
        Ok(s)
    }

    /// The collection, oldest first; my own stickers have an empty pack.
    pub fn stickers(&self) -> Result<Vec<Sticker>, CoreError> {
        self.sticker_index()
    }

    pub fn sticker_data(&self, id: &str) -> Result<Option<Vec<u8>>, CoreError> {
        self.get(&data_key(id))
    }

    /// Removes one sticker from a pack, or a whole pack when `id` is empty.
    pub fn remove_stickers(&self, pack: &str, id: &str) -> Result<(), CoreError> {
        let (gone, kept): (Vec<Sticker>, Vec<Sticker>) = self
            .sticker_index()?
            .into_iter()
            .partition(|s| s.pack == pack && (id.is_empty() || s.id == id));
        self.save_sticker_index(&kept)?;
        // The same image may sit in another pack; its data goes with the last copy.
        for s in gone.iter().filter(|g| !kept.iter().any(|k| k.id == g.id)) {
            self.put(&data_key(&s.id), b"")?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn core() -> SiegelCore {
        let dir = std::env::temp_dir().join(format!("siegel-stickers-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        SiegelCore::open(
            dir.join("c.db").to_str().unwrap(),
            &[7; 32],
            "http://localhost:1",
        )
        .unwrap()
    }

    #[test]
    fn collection_add_dedupe_remove() {
        let c = core();
        let a = c.add_sticker(b"webp-a", "image/webp", "").unwrap();
        assert_eq!(
            c.add_sticker(b"webp-a", "image/webp", "").unwrap(),
            a,
            "kept once"
        );
        c.add_sticker(b"webp-a", "image/webp", "Cats").unwrap();
        c.add_sticker(b"png-b", "image/png", "Cats").unwrap();
        assert_eq!(c.stickers().unwrap().len(), 3);
        assert!(c.add_sticker(b"gif", "image/gif", "").is_err());
        assert!(
            c.add_sticker(&vec![0; MAX_STICKER + 1], "image/png", "")
                .is_err()
        );

        c.remove_stickers("Cats", "").unwrap();
        assert_eq!(c.stickers().unwrap(), vec![a.clone()]);
        assert_eq!(
            c.sticker_data(&a.id).unwrap().as_deref(),
            Some(b"webp-a".as_slice()),
            "still mine"
        );
        c.remove_stickers("", &a.id).unwrap();
        assert!(c.stickers().unwrap().is_empty());
        assert_eq!(
            c.sticker_data(&a.id).unwrap().as_deref(),
            Some(b"".as_slice())
        );
    }
}
