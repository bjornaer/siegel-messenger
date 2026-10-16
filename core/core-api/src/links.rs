//! Personal contact links (DISC-08) and the share link they extend (DISC-02):
//! `https://<server>/u/<username>#<fingerprint>.<secret>`. The fragment never reaches the server.
//! The fingerprint lets the opener check they got the right key (and marks the contact
//! verified); the secret lets the owner's app accept the chat without a message request.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use core_net::pb;
use core_store::{ContactState, SqlCipher, Store};
use sha2::{Digest, Sha256};

use crate::{CoreError, IDENTITY, SiegelCore, USERNAME, storage};

/// The owner's current link secret; absent when the link is turned off.
const LINK_SECRET: &str = "contact_link_secret";
/// 96 bits of the identity key's hash: enough that no one can make a key that matches.
const FINGERPRINT_LEN: usize = 12;

fn fingerprint(identity_pub: &[u8]) -> String {
    B64.encode(&Sha256::digest(identity_pub)[..FINGERPRINT_LEN])
}

/// What a link says: username, fingerprint, secret.
pub(crate) fn parse(link: &str) -> Option<(String, String, Vec<u8>)> {
    let rest = link.split("/u/").nth(1)?;
    let (user, frag) = rest.split_once('#')?;
    let (fp, secret) = frag.split_once('.')?;
    let user = user.trim_end_matches('/').to_lowercase();
    if user.is_empty() || fp.is_empty() {
        return None;
    }
    Some((user, fp.to_string(), B64.decode(secret).ok()?))
}

/// DISC-08 on the owner's side: a chat from someone who presented our current secret skips the
/// message request. Returns whether it accepted them.
pub(crate) fn accept_by_link(s: &SqlCipher, from: &[u8], secret: &[u8]) -> Result<bool, CoreError> {
    let Some(ours) = storage(s.get(LINK_SECRET))?.filter(|o| !o.is_empty()) else {
        return Ok(false); // link turned off
    };
    let mut c = match storage(s.contact(from))? {
        Some(c) if c.state == ContactState::Request => c,
        _ => return Ok(false), // already a contact, or blocked
    };
    if !constant_time_eq(&ours, secret) {
        return Ok(false);
    }
    c.state = ContactState::Accepted;
    storage(s.save_contact(&c))?;
    Ok(true)
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |d, (x, y)| d | (x ^ y)) == 0
}

impl SiegelCore {
    /// Our contact link, or None when it is turned off (or before we have a username).
    pub fn contact_link(&self) -> Result<Option<String>, CoreError> {
        let secret = self.get(LINK_SECRET)?.filter(|s| !s.is_empty());
        let (Some(user), Some(secret)) = (self.get(USERNAME)?, secret) else {
            return Ok(None);
        };
        let id = self
            .get(IDENTITY)?
            .ok_or(CoreError::new("not_registered"))?;
        let key: [u8; 32] = id
            .try_into()
            .map_err(|_| CoreError::new("not_registered"))?;
        let public = core_crypto::IdentityKey::from_bytes(&key).public();
        Ok(Some(format!(
            "{}/u/{}#{}.{}",
            self.server_url,
            String::from_utf8_lossy(&user),
            fingerprint(&public),
            B64.encode(secret)
        )))
    }

    /// Turns the link on (a fresh secret if it had none) or off.
    pub fn set_contact_link(&self, on: bool) -> Result<(), CoreError> {
        let has = self.get(LINK_SECRET)?.is_some_and(|s| !s.is_empty());
        match (on, has) {
            (true, true) => Ok(()),
            (true, false) => self.reset_contact_link(),
            (false, _) => self.put(LINK_SECRET, b""), // empty = off
        }
    }

    /// A new secret: links shared before lead to ordinary message requests again.
    pub fn reset_contact_link(&self) -> Result<(), CoreError> {
        use rand_core::RngCore as _;
        let mut secret = [0u8; 16];
        rand_core::OsRng.fill_bytes(&mut secret);
        self.put(LINK_SECRET, &secret)
    }

    /// Opens someone's link: checks the key against the fingerprint, starts (or reopens) the
    /// chat, marks them verified (DISC-02) and proves we were given the link (DISC-08).
    pub async fn open_contact_link(&self, link: &str) -> Result<Vec<u8>, CoreError> {
        let (user, fp, secret) = parse(link).ok_or(CoreError::new("link_invalid"))?;
        let found = self.net.lookup_username(&self.token()?, &user).await?;
        if fingerprint(&found.identity_pub) != fp {
            // The server handed us a different key than the one in the link: never trust it.
            return Err(CoreError::new("link_key_mismatch"));
        }
        let chat = self.start_chat(&user).await?;
        if let Some(mut c) = self.contact(&found.account_id)
            && c.identity_key.as_deref() == Some(found.identity_pub.as_slice())
        {
            c.verified = true;
            self.with_store(|s| storage(s.save_contact(&c)))?;
        }
        let proof = pb::ContactLinkProof { secret };
        self.send_content(&chat, pb::content::Body::ContactLink(proof))
            .await?;
        Ok(chat)
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn parses_links_and_rejects_junk() {
        let (u, fp, secret) = super::parse("https://siegel.schlk.in/u/Ana.B#abc123.AQID").unwrap();
        assert_eq!(
            (u.as_str(), fp.as_str(), secret),
            ("ana.b", "abc123", vec![1, 2, 3])
        );
        for junk in [
            "https://x/u/ana",
            "https://x/g/ana#a.b",
            "https://x/u/#a.AQID",
            "nonsense",
        ] {
            assert!(super::parse(junk).is_none(), "{junk}");
        }
        assert!(super::constant_time_eq(b"ab", b"ab") && !super::constant_time_eq(b"ab", b"ac"));
    }
}
