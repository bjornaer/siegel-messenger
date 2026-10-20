//! M8 part 2: keeping our own devices in step. Sync messages travel in the conversation they're
//! about, addressed to our own account only, so no one else's devices ever receive them.

use base64::Engine as _;
use core_net::pb;
use core_store::{ContactState, SqlCipher, Store as _};

use crate::{CoreError, SiegelCore, storage};

/// Per-chat settings the app keeps under "<name>.<chat ID>" and shares between devices.
const SHARED_SETTINGS: [&str; 3] = ["archive", "mute", "hidden"];

impl SiegelCore {
    /// Sends a sync message to our other devices through this conversation. Best effort.
    pub(crate) async fn sync(&self, group_id: &[u8], kind: pb::sync::Kind) {
        let Ok(me) = self
            .me()
            .and_then(|m| <[u8; 16]>::try_from(m).map_err(|_| CoreError::new("not_registered")))
        else {
            return;
        };
        let content = self.new_content(pb::content::Body::Sync(pb::Sync { kind: Some(kind) }));
        let _ = self.deliver_to(group_id, &content, Some(&[me])).await;
    }

    /// The app changed a shared per-chat setting (archive, mute, hidden): tell our other devices.
    pub async fn share_chat_setting(
        &self,
        group_id: &[u8],
        name: &str,
        value: &str,
    ) -> Result<(), CoreError> {
        if !SHARED_SETTINGS.contains(&name) {
            return Err(CoreError::new("setting_invalid"));
        }
        self.sync(
            group_id,
            pb::sync::Kind::Setting(pb::SyncSetting {
                name: name.into(),
                value: value.into(),
            }),
        )
        .await;
        Ok(())
    }

    /// The conversation with this account, if we have one (1:1).
    pub(crate) fn chat_with(&self, account: &[u8]) -> Option<Vec<u8>> {
        self.conversations()
            .ok()?
            .into_iter()
            .find(|c| !c.is_group && c.peer_account == account)
            .map(|c| c.group_id)
    }
}

/// What applying a sync message from our own device asks the caller to do next.
pub(crate) enum Applied {
    Done,
    /// Blocked on a linked device: the phone also rotates our profile key (MSG-16).
    Block(Vec<u8>),
}

/// Applies a sync message from another of our devices to this conversation.
pub(crate) fn apply(
    s: &SqlCipher,
    group_id: &[u8],
    peer: &[u8],
    linked: bool,
    sync: pb::Sync,
) -> Result<Applied, CoreError> {
    match sync.kind {
        Some(pb::sync::Kind::Read(r)) => storage(s.mark_read_until(group_id, r.up_to))?,
        Some(pb::sync::Kind::Contact(c)) if !peer.is_empty() => {
            let Some(mut contact) = storage(s.contact(peer))? else {
                return Ok(Applied::Done);
            };
            let state = match c.state {
                1 => ContactState::Accepted,
                2 => ContactState::Blocked,
                _ => return Ok(Applied::Done),
            };
            let newly_blocked = state == ContactState::Blocked && contact.state != state;
            contact.state = state;
            storage(s.save_contact(&contact))?;
            if newly_blocked && !linked {
                return Ok(Applied::Block(peer.to_vec()));
            }
        }
        Some(pb::sync::Kind::Setting(x)) if SHARED_SETTINGS.contains(&x.name.as_str()) => {
            let key = format!(
                "setting.{}.{}",
                x.name,
                base64::engine::general_purpose::STANDARD.encode(group_id)
            );
            storage(s.put(&key, x.value.as_bytes()))?;
            if x.name == "hidden" && x.value == "1" {
                // Deleted on another device: its messages go here too (the chat comes back with
                // the next message, as there).
                for m in storage(s.messages(group_id, u32::MAX))? {
                    storage(s.delete_message(&m.message_id))?;
                }
            }
        }
        _ => {}
    }
    Ok(Applied::Done)
}
