//! Profiles and contacts (MSG-10, MSG-15, MSG-16): our encrypted profile and profile key,
//! contacts' profiles, and accepting, deleting and blocking.

use core_crypto::IdentityKey;
use core_crypto::profile::ProfileKey;
use core_net::pb;
use core_store::{Contact, ContactState, Store};
use prost::Message as _;

use crate::chat::note_identity;
use crate::{ACCOUNT, CoreError, IDENTITY, SiegelCore, storage};

pub(crate) const PROFILE_KEY: &str = "profile_key";
/// Profiles are padded to this bucket so name length stays hidden.
const PROFILE_BUCKET: usize = 256;
/// MED-15: our picture (plaintext) and its uploaded reference (an encoded pb::Attachment).
const MY_AVATAR: &str = "my_avatar";
const MY_AVATAR_REF: &str = "my_avatar_ref";
/// Pictures are small: the app sends a 512 px square.
pub(crate) const MAX_AVATAR: usize = 1 << 20;

/// A contact's picture: their blob ID (16 bytes) followed by the plaintext; empty when none.
fn avatar_key(account: &[u8]) -> String {
    let hex: String = account.iter().map(|b| format!("{b:02x}")).collect();
    format!("avatar:{hex}")
}

impl SiegelCore {
    /// Our profile key, created on first use (CRY-16).
    pub(crate) fn profile_key(&self) -> Result<ProfileKey, CoreError> {
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
        if self.is_linked_device() {
            return Ok(()); // M8: the phone owns our profile; linked devices read it back
        }
        let token = self.token()?;
        let key = self.profile_key()?;
        let avatar = self
            .get(MY_AVATAR_REF)?
            .and_then(|b| pb::Attachment::decode(b.as_slice()).ok());
        let avatar_blob_id = avatar
            .as_ref()
            .map(|a| a.blob_id.clone())
            .unwrap_or_default();
        let mut p = pb::Profile {
            display_name: self.display_name().unwrap_or_default(),
            username: self.username().unwrap_or_default(),
            avatar,
            padding: vec![],
        };
        let len = p.encoded_len();
        p.padding = vec![0; PROFILE_BUCKET - len % PROFILE_BUCKET];
        self.net
            .set_profile(
                &token,
                key.encrypt(&p.encode_to_vec()),
                key.verifier().to_vec(),
                avatar_blob_id,
            )
            .await?;
        Ok(())
    }

    /// MED-15: sets (Some) or removes (None) our picture, then tells our contacts.
    pub async fn set_avatar(&self, image: Option<Vec<u8>>) -> Result<(), CoreError> {
        match image {
            Some(img) => {
                if img.is_empty() || img.len() > MAX_AVATAR {
                    return Err(CoreError::new("avatar_invalid"));
                }
                let (mut a, _) = self.upload(&img, false).await?;
                a.mime_type = "image/png".into();
                self.put(MY_AVATAR_REF, &a.encode_to_vec())?;
                self.put(MY_AVATAR, &img)?;
            }
            None => {
                self.put(MY_AVATAR_REF, b"")?;
                self.put(MY_AVATAR, b"")?;
            }
        }
        self.announce_profile().await
    }

    pub fn my_avatar(&self) -> Option<Vec<u8>> {
        self.get(MY_AVATAR).ok().flatten().filter(|a| !a.is_empty())
    }

    /// A contact's picture, once their profile has been fetched.
    pub fn avatar(&self, account: &[u8]) -> Option<Vec<u8>> {
        let v = self.get(&avatar_key(account)).ok().flatten()?;
        (v.len() > 16).then(|| v[16..].to_vec())
    }

    /// Publishes our profile and re-shares the profile key with every chat, which makes
    /// contacts fetch it again: how a new name or picture reaches them.
    pub async fn announce_profile(&self) -> Result<(), CoreError> {
        self.publish_profile().await?;
        self.share_profile_key_everywhere(None).await
    }

    /// Our profile key to every accepted chat and joined group, leaving out `except`.
    async fn share_profile_key_everywhere(&self, except: Option<&[u8]>) -> Result<(), CoreError> {
        for conv in self.conversations()? {
            if conv.is_group {
                if conv.invite || conv.left {
                    continue;
                }
                let others: Vec<[u8; 16]> = self
                    .group_info(&conv.group_id)?
                    .members
                    .into_iter()
                    // Our own account too: our linked devices need the new key (M8).
                    .filter(|m| Some(m.account.as_slice()) != except)
                    .filter_map(|m| m.account.try_into().ok())
                    .collect();
                self.share_profile_key_with(&conv.group_id, &others).await?;
            } else if Some(conv.peer_account.as_slice()) != except
                && self
                    .contact(&conv.peer_account)
                    .is_some_and(|c| c.state == ContactState::Accepted)
            {
                self.share_profile_key(&conv.group_id).await?;
            }
        }
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

    /// M8: a linked device reads our own profile back (name, @username), as the phone set it.
    pub(crate) async fn refresh_own_profile(&self) -> Result<(), CoreError> {
        let me = self.me()?;
        let encrypted = self.net.get_profile(&self.token()?, &me).await?;
        let p = self
            .profile_key()?
            .decrypt(&encrypted)
            .and_then(|b| pb::Profile::decode(b.as_slice()).ok())
            .ok_or(CoreError::new("profile_invalid"))?;
        self.put(crate::DISPLAY_NAME, p.display_name.as_bytes())?;
        if !p.username.is_empty() {
            self.put(crate::USERNAME, p.username.as_bytes())?;
        }
        // The phone's picture too (MED-15), fetched again only when it changed.
        let current = self.get(MY_AVATAR_REF)?.unwrap_or_default();
        match p.avatar {
            Some(a) if crate::media::valid(&a) && a.size as usize <= MAX_AVATAR => {
                if pb::Attachment::decode(current.as_slice())
                    .ok()
                    .map(|c| c.blob_id)
                    != Some(a.blob_id.clone())
                    && let Ok(blob) = self.download(&a).await
                    && let Some(img) = core_media::decrypt(&a.key, &blob, a.size as usize)
                {
                    self.put(MY_AVATAR_REF, &a.encode_to_vec())?;
                    self.put(MY_AVATAR, &img)?;
                }
            }
            _ => {
                self.put(MY_AVATAR_REF, b"")?;
                self.put(MY_AVATAR, b"")?;
            }
        }
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
        // MED-15: fetch the picture when it changed. Best effort: the name still updates.
        let cached = self.get(&avatar_key(account))?.unwrap_or_default();
        match &p.avatar {
            Some(a) if crate::media::valid(a) && a.size as usize <= MAX_AVATAR => {
                if cached.get(..16) != Some(a.blob_id.as_slice())
                    && let Ok(blob) = self.download(a).await
                    && let Some(img) = core_media::decrypt(&a.key, &blob, a.size as usize)
                {
                    self.put(&avatar_key(account), &[a.blob_id.as_slice(), &img].concat())?;
                }
            }
            _ => self.put(&avatar_key(account), b"")?,
        }
        self.with_store(|s| {
            // Re-read: the state may have changed while we were on the network.
            let mut c = storage(s.contact(account))?.unwrap_or(c);
            c.display_name = Some(p.display_name).filter(|n| !n.is_empty());
            c.username = Some(p.username).filter(|n| !n.is_empty());
            storage(s.save_contact(&c))
        })
    }

    /// Profiles fetched by an app without pictures (before build 12) never stored one, and
    /// nothing fetches them again until the contact changes theirs: fetch those once.
    pub(crate) async fn refresh_missing_profiles(&self) {
        let Ok(contacts) = self.with_store(|s| storage(s.contacts())) else {
            return;
        };
        for c in contacts {
            if c.profile_key.is_some() && matches!(self.get(&avatar_key(&c.account_id)), Ok(None)) {
                let _ = self.refresh_profile(&c.account_id).await;
            }
        }
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
    /// Also true for a group invite we haven't accepted (GRP-11).
    pub fn is_request(&self, group_id: &[u8]) -> Result<bool, CoreError> {
        let conv = self.conversation(group_id)?;
        if conv.is_group {
            return Ok(conv.invite);
        }
        Ok(self.peer_contact(group_id)?.state != ContactState::Accepted)
    }

    /// Accepts a message request: they become a contact and get our profile key.
    pub async fn accept(&self, group_id: &[u8]) -> Result<(), CoreError> {
        if self.conversation(group_id)?.is_group {
            return self.accept_invite(group_id).await;
        }
        let mut c = self.peer_contact(group_id)?;
        c.state = ContactState::Accepted;
        self.with_store(|s| storage(s.save_contact(&c)))?;
        self.share_profile_key(group_id).await?;
        self.sync(
            group_id,
            pb::sync::Kind::Contact(pb::SyncContact { state: 1 }),
        )
        .await; // M8
        Ok(())
    }

    /// Deletes every message of a chat from this device but keeps the chat's keys, so the next
    /// message from the other side still arrives (deleting an ongoing 1:1 chat).
    pub fn clear_chat(&self, group_id: &[u8]) -> Result<(), CoreError> {
        for m in self.with_store(|s| storage(s.messages(group_id, u32::MAX)))? {
            self.delete_for_me(&m.message_id)?;
        }
        Ok(())
    }

    /// Deletes a chat from this device (declining a request, or MSG-12 for a whole chat).
    pub fn delete_chat(&self, group_id: &[u8]) -> Result<(), CoreError> {
        let peer = self.peer_contact(group_id).ok();
        let _ = self.with_mls(|m, s| {
            for g in storage(s.mls_groups(group_id))? {
                let _ = m.forget(&g);
            }
            Ok(())
        });
        for m in self.with_store(|s| storage(s.messages(group_id, u32::MAX)))? {
            self.forget_media(&m.message_id);
        }
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
        if let Some(chat) = self.chat_with(account) {
            // M8: our other devices block them too; the phone rotates the key either way.
            self.sync(&chat, pb::sync::Kind::Contact(pb::SyncContact { state: 2 }))
                .await;
        }
        if self.is_linked_device() {
            return Ok(()); // the phone rotates our profile key when the sync reaches it
        }
        self.rotate_after_block(account).await
    }

    /// MSG-16: a new profile key, so the blocked account's delivery token stops working; every
    /// remaining contact (and our own other devices) get it.
    pub(crate) async fn rotate_after_block(&self, account: &[u8]) -> Result<(), CoreError> {
        self.put(PROFILE_KEY, &ProfileKey::generate().0)?;
        self.publish_profile().await?;
        self.share_profile_key_everywhere(Some(account)).await
    }

    /// Blocked accounts, for the list in Settings (MSG-16).
    pub fn blocked(&self) -> Result<Vec<Contact>, CoreError> {
        Ok(self
            .with_store(|s| storage(s.contacts()))?
            .into_iter()
            .filter(|c| c.state == ContactState::Blocked)
            .collect())
    }

    /// Unblocks an account: they are a contact again and get our current profile key, so their
    /// messages arrive and they can send sealed (MSG-10, MSG-16).
    pub async fn unblock(&self, account: &[u8]) -> Result<(), CoreError> {
        let mut c = self
            .contact(account)
            .filter(|c| c.state == ContactState::Blocked)
            .ok_or(CoreError::new("unknown_contact"))?;
        c.state = ContactState::Accepted;
        self.with_store(|s| storage(s.save_contact(&c)))?;
        for conv in self.conversations()? {
            if conv.peer_account == account {
                self.share_profile_key(&conv.group_id).await?;
                self.sync(
                    &conv.group_id,
                    pb::sync::Kind::Contact(pb::SyncContact { state: 1 }),
                )
                .await; // M8
            }
        }
        Ok(())
    }

    /// CRY-12: the chat's 60-digit safety number, also what its QR code encodes. None until we
    /// have the peer's identity key.
    pub fn safety_number(&self, group_id: &[u8]) -> Result<Option<String>, CoreError> {
        let mut peer = self.peer_contact(group_id)?;
        if peer.identity_key.is_none() {
            // Chats from before identity pinning: take the key from the MLS group.
            let mls_group = self.conversation(group_id)?.mls_group;
            self.with_mls(|m, s| {
                if let Some(o) = m.others(&mls_group).ok().and_then(|o| o.into_iter().next()) {
                    note_identity(s, &peer.account_id, &o.identity_pub)?;
                }
                Ok(())
            })?;
            peer = self.peer_contact(group_id)?;
        }
        let missing = || CoreError::new("not_registered");
        let me: [u8; 16] = self
            .get(ACCOUNT)?
            .ok_or_else(missing)?
            .try_into()
            .map_err(|_| missing())?;
        let secret: [u8; 32] = self
            .get(IDENTITY)?
            .ok_or_else(missing)?
            .try_into()
            .map_err(|_| missing())?;
        let mine = IdentityKey::from_bytes(&secret).public();
        let (Ok(account), Some(Ok(key))) = (
            <[u8; 16]>::try_from(peer.account_id.as_slice()),
            peer.identity_key.as_deref().map(<[u8; 32]>::try_from),
        ) else {
            return Ok(None);
        };
        Ok(Some(core_crypto::safety_number(
            (&me, &mine),
            (&account, &key),
        )))
    }

    /// CRY-12: a scanned QR code that matches marks the contact verified. False on mismatch.
    pub fn verify_safety_number(&self, group_id: &[u8], scanned: &str) -> Result<bool, CoreError> {
        if self.safety_number(group_id)?.as_deref() != Some(scanned.trim()) {
            return Ok(false);
        }
        let mut c = self.peer_contact(group_id)?;
        c.verified = true;
        self.with_store(|s| storage(s.save_contact(&c)))?;
        Ok(true)
    }
}
