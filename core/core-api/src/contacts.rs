//! Profiles and contacts (MSG-10, MSG-15, MSG-16): our encrypted profile and profile key,
//! contacts' profiles, and accepting, deleting and blocking.

use core_crypto::profile::ProfileKey;
use core_net::pb;
use core_store::{Contact, ContactState, Store};
use prost::Message as _;

use crate::{CoreError, SiegelCore, storage};

const PROFILE_KEY: &str = "profile_key";
/// Profiles are padded to this bucket so name length stays hidden.
const PROFILE_BUCKET: usize = 256;

impl SiegelCore {
    /// Our profile key, created on first use (CRY-16).
    fn profile_key(&self) -> Result<ProfileKey, CoreError> {
        if let Some(k) = self.get(PROFILE_KEY)?
            && let Ok(k) = <[u8; 32]>::try_from(k.as_slice())
        {
            return Ok(ProfileKey(k));
        }
        let k = ProfileKey::generate();
        self.put(PROFILE_KEY, &k.0)?;
        Ok(k)
    }

    /// Encrypts our name and @username under the profile key and uploads it with the
    /// delivery-token verifier (MSG-10). The server stores only ciphertext.
    pub async fn publish_profile(&self) -> Result<(), CoreError> {
        let token = self.token()?;
        let key = self.profile_key()?;
        let mut p = pb::Profile {
            display_name: self.display_name().unwrap_or_default(),
            username: self.username().unwrap_or_default(),
            padding: vec![],
        };
        let len = p.encoded_len();
        p.padding = vec![0; PROFILE_BUCKET - len % PROFILE_BUCKET];
        self.net
            .set_profile(
                &token,
                key.encrypt(&p.encode_to_vec()),
                key.verifier().to_vec(),
            )
            .await?;
        Ok(())
    }

    /// Shares our profile key with a group, so they see who we are and can send sealed.
    pub(crate) async fn share_profile_key(&self, group_id: &[u8]) -> Result<(), CoreError> {
        let key = self.profile_key()?;
        let update = pb::ProfileKeyUpdate {
            profile_key: key.0.to_vec(),
        };
        self.send_content(group_id, pb::content::Body::ProfileKeyUpdate(update))
            .await?;
        Ok(())
    }

    /// Fetches and decrypts a contact's profile with the key they shared.
    pub(crate) async fn refresh_profile(&self, account: &[u8]) -> Result<(), CoreError> {
        let token = self.token()?;
        let Some(c) = self.contact(account) else {
            return Ok(());
        };
        let Some(key) = c
            .profile_key
            .as_deref()
            .and_then(|k| <[u8; 32]>::try_from(k).ok())
        else {
            return Ok(());
        };
        let encrypted = self.net.get_profile(&token, account).await?;
        let p = ProfileKey(key)
            .decrypt(&encrypted)
            .and_then(|b| pb::Profile::decode(b.as_slice()).ok())
            .ok_or(CoreError::new("profile_invalid"))?;
        self.with_store(|s| {
            // Re-read: the state may have changed while we were on the network.
            let mut c = storage(s.contact(account))?.unwrap_or(c);
            c.display_name = Some(p.display_name).filter(|n| !n.is_empty());
            c.username = Some(p.username).filter(|n| !n.is_empty());
            storage(s.save_contact(&c))
        })
    }

    pub fn contact(&self, account: &[u8]) -> Option<Contact> {
        self.with_store(|s| storage(s.contact(account)))
            .ok()
            .flatten()
    }

    fn peer_contact(&self, group_id: &[u8]) -> Result<Contact, CoreError> {
        let peer = self
            .conversations()?
            .into_iter()
            .find(|c| c.group_id == group_id)
            .ok_or(CoreError::new("unknown_group"))?
            .peer_account;
        self.contact(&peer).ok_or(CoreError::new("unknown_group"))
    }

    /// True while the chat is an unaccepted message request (MSG-15).
    pub fn is_request(&self, group_id: &[u8]) -> Result<bool, CoreError> {
        Ok(self.peer_contact(group_id)?.state != ContactState::Accepted)
    }

    /// Accepts a message request: they become a contact and get our profile key.
    pub async fn accept(&self, group_id: &[u8]) -> Result<(), CoreError> {
        let mut c = self.peer_contact(group_id)?;
        c.state = ContactState::Accepted;
        self.with_store(|s| storage(s.save_contact(&c)))?;
        self.share_profile_key(group_id).await
    }

    /// Deletes a chat from this device (declining a request, or MSG-12 for a whole chat).
    pub fn delete_chat(&self, group_id: &[u8]) -> Result<(), CoreError> {
        let peer = self.peer_contact(group_id).ok();
        let _ = self.with_mls(|m, _| m.forget(group_id).map_err(|e| CoreError::new(&e.0)));
        self.with_store(|s| storage(s.delete_conversation(group_id)))?;
        if let Some(c) = peer.filter(|c| c.state == ContactState::Request) {
            // A declined requester can write again later; forget what we cached about them.
            self.with_store(|s| {
                storage(s.save_contact(&Contact {
                    profile_key: None,
                    display_name: None,
                    ..c
                }))
            })?;
        }
        Ok(())
    }

    /// Blocks an account (MSG-16): local, plus a profile-key rotation that invalidates their
    /// delivery token. They are not notified; remaining contacts get the new key.
    pub async fn block(&self, account: &[u8]) -> Result<(), CoreError> {
        let mut c = self
            .contact(account)
            .ok_or(CoreError::new("unknown_contact"))?;
        c.state = ContactState::Blocked;
        self.with_store(|s| storage(s.save_contact(&c)))?;
        self.put(PROFILE_KEY, &ProfileKey::generate().0)?;
        self.publish_profile().await?;
        for conv in self.conversations()? {
            if self
                .contact(&conv.peer_account)
                .is_some_and(|c| c.state == ContactState::Accepted)
            {
                self.share_profile_key(&conv.group_id).await?;
            }
        }
        Ok(())
    }
}
