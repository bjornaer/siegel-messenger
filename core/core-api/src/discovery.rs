//! Phone-number discovery (DISC-03..07): opt in with our own number, and find which of our
//! contacts' numbers belong to people who opted in. Numbers stay on this phone; the server
//! only sees blinded points (docs/discovery.md).

use std::collections::{BTreeMap, BTreeSet};

use core_crypto::discovery as d;
use sha2::{Digest, Sha256};

use crate::{CoreError, PHONE, SiegelCore};

/// Evaluated outputs for contacts we already checked this key period, so re-checks don't spend
/// the daily allowance (DISC-06): JSON {period, outputs: {hex(SHA-256(number)): hex(O)}}. Keyed by
/// hash so contacts' numbers aren't kept on the phone.
// ponytail: a plain hash of a phone number can be brute-forced; the DB is SQLCipher-encrypted anyway.
const CACHE: &str = "discovery_cache";
/// One request at most this many numbers (the server's first-sync allowance).
const CHUNK: usize = 5000;

#[derive(serde::Serialize, serde::Deserialize, Default)]
struct Cache {
    period: i64,
    bits: u32,
    outputs: BTreeMap<String, String>,
}

/// A contact who uses Siegel and can be found by number (DISC-07: the @username, nothing else).
#[derive(Debug, Clone, PartialEq)]
pub struct Found {
    pub phone: String,
    pub username: String,
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// The cache key for a number.
fn key(number: &str) -> String {
    hex(&Sha256::digest(number))
}

fn unhex(s: &str) -> Option<[u8; 32]> {
    let v: Vec<u8> = (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok())
        .collect::<Option<_>>()?;
    v.try_into().ok()
}

impl SiegelCore {
    pub fn my_phone(&self) -> Option<String> {
        self.get_string(PHONE)
    }

    /// For accounts from before the number was kept: the server checks it is really ours.
    pub fn set_my_phone(&self, phone: &str) -> Result<(), CoreError> {
        self.put(PHONE, phone.as_bytes())
    }

    /// DISC-03: "Let people who have my number find me".
    pub async fn set_discoverable(&self, on: bool) -> Result<(), CoreError> {
        let phone = if on {
            Some(self.my_phone().ok_or(CoreError::new("phone_unknown"))?)
        } else {
            None
        };
        Ok(self
            .net
            .set_discoverable(&self.token()?, phone.as_deref())
            .await?)
    }

    pub async fn discoverable(&self) -> Result<bool, CoreError> {
        Ok(self.net.discoverable(&self.token()?).await?)
    }

    /// DISC-05: which of these E.164 numbers belong to people who can be found. Only numbers
    /// not checked before in this key period count against the limit (DISC-06).
    pub async fn find_contacts(&self, numbers: &[String]) -> Result<Vec<Found>, CoreError> {
        let token = self.token()?;
        let mut cache: Cache = self
            .get(CACHE)?
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        // Caches from before build 14 were keyed by the number itself.
        cache.outputs = std::mem::take(&mut cache.outputs)
            .into_iter()
            .map(|(k, v)| (if k.starts_with('+') { key(&k) } else { k }, v))
            .collect();
        let wanted: BTreeSet<&String> = numbers
            .iter()
            .filter(|n| Some(n.as_str()) != self.my_phone().as_deref())
            .collect();
        let mut todo: Vec<&String> = wanted
            .iter()
            .filter(|n| !cache.outputs.contains_key(&key(n)))
            .copied()
            .collect();
        loop {
            for chunk in todo.chunks(CHUNK) {
                let blinded: Vec<_> = chunk.iter().map(|n| d::blind(n)).collect();
                let res = self
                    .net
                    .evaluate(&token, blinded.iter().map(|(_, b)| b.to_vec()).collect())
                    .await?;
                if res.period != cache.period {
                    // New key period: everything we had is stale.
                    cache = Cache {
                        period: res.period,
                        ..Default::default()
                    };
                }
                cache.bits = res.bucket_bits;
                for ((n, (r, _)), ev) in chunk.iter().zip(&blinded).zip(&res.evaluated) {
                    if let Some(o) = d::finalize(r, ev) {
                        cache.outputs.insert(key(n), hex(&o));
                    }
                }
            }
            // A rotation mid-way leaves some numbers unevaluated: do them again under the new key.
            let missing: Vec<&String> = wanted
                .iter()
                .filter(|n| !cache.outputs.contains_key(&key(n)))
                .copied()
                .collect();
            if missing.is_empty() || missing.len() == todo.len() {
                break;
            }
            todo = missing;
        }
        let save = serde_json::to_vec(&cache).map_err(|_| CoreError::new("storage"))?;
        self.put(CACHE, &save)?;

        let ours: Vec<(&String, [u8; 32])> = wanted
            .iter()
            .filter_map(|n| Some((*n, unhex(cache.outputs.get(&key(n))?)?)))
            .collect();
        let buckets: BTreeSet<u32> = ours
            .iter()
            .map(|(_, o)| d::bucket_of(&d::entry_id(o), cache.bits))
            .collect();
        if buckets.is_empty() {
            return Ok(vec![]);
        }
        let entries = match self
            .net
            .buckets(&token, cache.period, buckets.into_iter().collect())
            .await
        {
            Err(e) if e.code == "period_changed" => {
                // The key rotated since we evaluated: start over under the new one.
                self.put(CACHE, b"")?;
                return Box::pin(self.find_contacts(numbers)).await;
            }
            r => r?,
        };
        let mut found = Vec::new();
        for (n, o) in ours {
            let id = d::entry_id(&o);
            if let Some(name) = entries
                .iter()
                .filter(|e| e.id == id)
                .find_map(|e| d::open(&o, &e.r#box))
            {
                found.push(Found {
                    phone: n.clone(),
                    username: name,
                });
            }
        }
        Ok(found)
    }
}
