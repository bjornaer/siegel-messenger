//! M8 part 1: linked devices. The phone (primary) links a browser or tablet by scanning its QR
//! code, hands it the account's keys sealed to it, and adds it to every conversation. Linked
//! devices see messages from the moment they're linked (W1), never history.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use core_net::pb;
use core_store::{Contact, ContactState, Store as _};
use prost::Message as _;

use crate::{CoreError, SiegelCore, storage};

/// Where a device being linked keeps its age secret and link ID until the phone approves.
const LINKING: &str = "linking";
/// This device is a linked one (it can't link others).
const LINKED: &str = "linked";
const QR_PREFIX: &str = "siegel-link:";

/// One of the account's devices, as Settings → Linked devices lists them.
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceInfo {
    pub id: Vec<u8>,
    pub name: String,
    pub linked: bool,
    pub last_seen_day: String,
    pub this_device: bool,
}

fn state_of(n: i32) -> ContactState {
    match n {
        1 => ContactState::Accepted,
        2 => ContactState::Blocked,
        _ => ContactState::Request,
    }
}

impl SiegelCore {
    pub fn is_linked_device(&self) -> bool {
        self.get(LINKED).ok().flatten().as_deref() == Some(b"1")
    }

    pub async fn devices(&self) -> Result<Vec<DeviceInfo>, CoreError> {
        Ok(self
            .net
            .list_devices(&self.token()?)
            .await?
            .into_iter()
            .map(|d| DeviceInfo {
                id: d.device_id,
                name: d.name,
                linked: d.linked,
                last_seen_day: d.last_seen_day,
                this_device: d.this_device,
            })
            .collect())
    }

    // --- On the device being linked ---

    /// Starts linking this (new, unregistered) device: returns the text for its QR code.
    pub async fn link_begin(&self, device_name: &str) -> Result<String, CoreError> {
        let (secret, recipient) = core_crypto::reports::new_identity();
        let id = self.net.link_begin(&recipient).await?;
        self.put(LINKING, format!("{}\n{secret}", B64.encode(&id)).as_bytes())?;
        Ok(format!(
            "{QR_PREFIX}{}.{recipient}.{}",
            B64.encode(&id),
            B64.encode(device_name.trim())
        ))
    }

    /// Asks whether the phone approved; once it has, sets this device up as part of the account.
    /// Returns true when linked; call again every couple of seconds until then.
    pub async fn link_wait(&self) -> Result<bool, CoreError> {
        let pending = self
            .get_string(LINKING)
            .ok_or(CoreError::new("link_expired"))?;
        let (id, secret) = pending
            .split_once('\n')
            .ok_or(CoreError::new("link_expired"))?;
        let id = B64.decode(id).map_err(|_| CoreError::new("link_expired"))?;
        let sealed = self.net.link_collect(&id).await?;
        if sealed.is_empty() {
            return Ok(false);
        }
        let plain =
            core_crypto::reports::open(secret, &sealed).ok_or(CoreError::new("link_invalid"))?;
        let b =
            pb::LinkBundle::decode(plain.as_slice()).map_err(|_| CoreError::new("link_invalid"))?;
        self.install_bundle(b)?;
        self.put(LINKING, b"")?;
        let _ = self.ensure_key_packages().await; // the phone waits for these to add us
        Ok(true)
    }

    fn install_bundle(&self, b: pb::LinkBundle) -> Result<(), CoreError> {
        let bad = || CoreError::new("link_invalid");
        let account: [u8; 16] = b.account_id.as_slice().try_into().map_err(|_| bad())?;
        let device: [u8; 16] = b.device_id.as_slice().try_into().map_err(|_| bad())?;
        let secret: [u8; 32] = b.identity_secret.as_slice().try_into().map_err(|_| bad())?;
        let as_pub: [u8; 32] = b.as_public_key.as_slice().try_into().map_err(|_| bad())?;
        let as_sig: [u8; 64] = b.as_signature.as_slice().try_into().map_err(|_| bad())?;
        let id = core_crypto::IdentityKey::from_bytes(&secret);
        // The binding the phone holds must verify under the AS key we now pin (CRY-08).
        if !core_crypto::verify_as_binding(&as_pub, &account, &id.public(), &as_sig) {
            return Err(CoreError::new("as_signature_invalid"));
        }
        self.with_store(|s| {
            let signer = crate::chat::new_signer(s)?; // this device's own MLS key (CRY-07)
            let credential = core_crypto::mls::DeviceCredential::issue(
                &id,
                account,
                device,
                signer.public(),
                as_sig,
            );
            for (k, v) in [
                (crate::PHONE, b.phone_e164.as_bytes()),
                (crate::IDENTITY, &secret[..]),
                (crate::ACCOUNT, &account[..]),
                (crate::DEVICE, &device[..]),
                (crate::TOKEN, b.device_token.as_bytes()),
                (crate::AS_PUBLIC, &as_pub[..]),
                (crate::SIGNER, signer.public()),
                (crate::CREDENTIAL, &credential.encode()),
                (crate::USERNAME, b.username.as_bytes()),
                (crate::DISPLAY_NAME, b.display_name.as_bytes()),
                (crate::contacts::PROFILE_KEY, &b.profile_key[..]),
                (LINKED, b"1"),
            ] {
                storage(s.put(k, v))?;
            }
            for c in &b.contacts {
                storage(s.save_contact(&Contact {
                    account_id: c.account_id.clone(),
                    state: state_of(c.state),
                    profile_key: (!c.profile_key.is_empty()).then(|| c.profile_key.clone()),
                    display_name: (!c.display_name.is_empty()).then(|| c.display_name.clone()),
                    username: (!c.username.is_empty()).then(|| c.username.clone()),
                    identity_key: (!c.identity_key.is_empty()).then(|| c.identity_key.clone()),
                    verified: c.verified,
                }))?;
            }
            Ok(())
        })
    }

    // --- On the phone ---

    /// Links the device whose QR code was scanned: creates it on the server, hands it the
    /// account's keys sealed to it, then adds it to every conversation once its keys are up.
    pub async fn link_device(&self, qr: &str) -> Result<(), CoreError> {
        if self.is_linked_device() {
            return Err(CoreError::new("primary_only"));
        }
        let bad = || CoreError::new("link_invalid");
        let rest = qr.trim().strip_prefix(QR_PREFIX).ok_or_else(bad)?;
        let mut parts = rest.splitn(3, '.');
        let (Some(id), Some(recipient), Some(name)) = (parts.next(), parts.next(), parts.next())
        else {
            return Err(bad());
        };
        let id = B64.decode(id).map_err(|_| bad())?;
        let name = String::from_utf8(B64.decode(name).map_err(|_| bad())?).map_err(|_| bad())?;
        let token = self.token()?;
        let (device_id, device_token) = self
            .net
            .add_device(&token, &name, pb::Platform::Web)
            .await?;
        let credential = core_crypto::mls::DeviceCredential::decode(
            &self
                .get(crate::CREDENTIAL)?
                .ok_or(CoreError::new("not_registered"))?,
        )
        .ok_or(CoreError::new("not_registered"))?;
        let contacts = self.with_store(|s| storage(s.contacts()))?;
        let bundle = pb::LinkBundle {
            account_id: self.me()?,
            device_id: device_id.clone(),
            device_token,
            identity_secret: self.get(crate::IDENTITY)?.unwrap_or_default(),
            as_public_key: self.get(crate::AS_PUBLIC)?.unwrap_or_default(),
            as_signature: credential.as_sig.to_vec(),
            phone_e164: self.get_string(crate::PHONE).unwrap_or_default(),
            username: self.username().unwrap_or_default(),
            display_name: self.display_name().unwrap_or_default(),
            profile_key: self.profile_key()?.0.to_vec(),
            contacts: contacts
                .into_iter()
                .map(|c| pb::LinkedContact {
                    account_id: c.account_id,
                    state: c.state as i32,
                    profile_key: c.profile_key.unwrap_or_default(),
                    display_name: c.display_name.unwrap_or_default(),
                    username: c.username.unwrap_or_default(),
                    identity_key: c.identity_key.unwrap_or_default(),
                    verified: c.verified,
                })
                .collect(),
        };
        let sealed =
            core_crypto::reports::seal(recipient, &bundle.encode_to_vec()).ok_or_else(bad)?;
        if let Err(e) = self.net.link_complete(&token, &id, sealed).await {
            let _ = self.net.remove_device(&token, &device_id).await; // never left half-linked
            return Err(e.into());
        }
        // The new device uploads its keys once it opens the bundle; add it as soon as they're up.
        for _ in 0..60 {
            if self.ensure_own_devices().await? {
                return Ok(());
            }
            crate::rt::sleep(std::time::Duration::from_secs(2)).await;
        }
        Ok(()) // upkeep finishes the job on the next connect
    }

    /// Unlinks a device: the server forgets it, and it leaves every conversation.
    pub async fn unlink_device(&self, device_id: &[u8]) -> Result<(), CoreError> {
        self.net.remove_device(&self.token()?, device_id).await?;
        let d: [u8; 16] = device_id
            .try_into()
            .map_err(|_| CoreError::new("device_invalid"))?;
        for c in self.conversations()? {
            if c.left {
                continue;
            }
            if self.own_leaves(&c.mls_group)?.contains(&d) {
                let _ = self
                    .commit_full(&c.group_id, vec![], &[], &[d], |s| s, false)
                    .await;
            }
        }
        Ok(())
    }

    /// On a linked device: leaves the account and forgets everything here. The phone drops it
    /// from conversations the next time it sends.
    pub async fn unlink_this_device(&self) -> Result<(), CoreError> {
        let device = self.get(crate::DEVICE)?.unwrap_or_default();
        self.net.remove_device(&self.token()?, &device).await?;
        self.wipe()
    }

    /// KeyPackages of our other devices (M8), for a new chat or group; none when we have none.
    pub(crate) async fn own_other_key_packages(&self) -> Vec<Vec<u8>> {
        let (Ok(token), Ok(me)) = (self.token(), self.me()) else {
            return vec![];
        };
        self.net
            .claim_key_packages(&token, &me)
            .await
            .map(|v| v.into_iter().map(|k| k.key_package).collect())
            .unwrap_or_default()
    }

    /// Our devices present in an MLS group (by device ID).
    fn own_leaves(&self, mls_group: &[u8]) -> Result<Vec<[u8; 16]>, CoreError> {
        let me = self.me()?;
        Ok(self
            .with_mls(|m, _| m.roster(mls_group).map_err(crate::chat::mls_err))?
            .into_iter()
            .filter(|r| r.account_id.as_slice() == me.as_slice())
            .map(|r| r.device_id)
            .collect())
    }

    /// Adds our other devices to every conversation missing them (the phone's job). Returns
    /// whether every conversation now has all of them.
    pub(crate) async fn ensure_own_devices(&self) -> Result<bool, CoreError> {
        if self.is_linked_device() {
            return Ok(true);
        }
        let token = self.token()?;
        let mine: Vec<[u8; 16]> = self
            .net
            .list_devices(&token)
            .await?
            .into_iter()
            .filter(|d| !d.this_device)
            .filter_map(|d| d.device_id.as_slice().try_into().ok())
            .collect();
        if mine.is_empty() {
            return Ok(true);
        }
        let mut complete = true;
        let me = self.me()?;
        for c in self.conversations()? {
            if c.left || c.peer_account.is_empty() && !c.is_group {
                continue;
            }
            let present = self.own_leaves(&c.mls_group)?;
            let missing: Vec<[u8; 16]> = mine
                .iter()
                .filter(|d| !present.contains(d))
                .copied()
                .collect();
            if missing.is_empty() {
                continue;
            }
            // No keys yet (the new device hasn't uploaded them): try again later.
            let kps: Vec<Vec<u8>> = self
                .net
                .claim_key_packages(&token, &me)
                .await
                .unwrap_or_default()
                .into_iter()
                .filter(|k| {
                    missing
                        .iter()
                        .any(|d| d.as_slice() == k.device_id.as_slice())
                })
                .map(|k| k.key_package)
                .collect();
            if kps.len() < missing.len() {
                complete = false; // a device without keys yet
            }
            if !kps.is_empty()
                && self
                    .commit_with(&c.group_id, kps, &[], |s| s, false)
                    .await
                    .is_err()
            {
                complete = false;
            }
        }
        Ok(complete)
    }
}
