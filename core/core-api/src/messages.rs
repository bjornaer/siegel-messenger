//! Message features (MSG-04, MSG-07..09, MSG-11..14): replies, reactions, edits, deletes,
//! receipts and typing. Changes to a message go through `apply_change` on both the sending
//! and the receiving side, so everyone enforces the same rules.

use core_net::pb;
use core_store::{Message, SqlCipher, Status, Store};
use prost::Message as _;

use crate::chat::{ChatMessage, chat_message, now_ms};
use crate::{ACCOUNT, CoreError, SiegelCore, storage};

/// MSG-05.
pub(crate) const MAX_TEXT: usize = 64 * 1024;
/// MSG-09 and MSG-11 windows, on the sender's clock (like `sent_at`).
const EDIT_WINDOW_MS: i64 = 15 * 60 * 1000;
const DELETE_WINDOW_MS: i64 = 48 * 60 * 60 * 1000;
/// One emoji, including skin tone and ZWJ sequences, fits easily.
const MAX_REACTION: usize = 32;
/// A typing event that sat in the queue longer than this is stale.
pub(crate) const TYPING_STALE_MS: i64 = 10_000;

/// Settings keys (MSG-13, MSG-14). Both default to on.
pub const READ_RECEIPTS: &str = "read_receipts";
pub const TYPING: &str = "typing_indicators";

/// Checks a reaction, edit or delete from `from` against the stored message and, when
/// `commit`, applies it. False when the target is unknown or the change isn't allowed.
pub(crate) fn apply_change(
    s: &SqlCipher,
    group_id: &[u8],
    from: &[u8],
    c: &pb::Content,
    commit: bool,
) -> Result<bool, CoreError> {
    use pb::content::Body;
    let target = match &c.body {
        Some(Body::Reaction(r)) => &r.message_id,
        Some(Body::Edit(e)) => &e.message_id,
        Some(Body::Delete(d)) => &d.message_id,
        _ => return Ok(false),
    };
    let Some(mut m) = storage(s.message(target))? else {
        return Ok(false);
    };
    if m.group_id != group_id || m.deleted {
        return Ok(false);
    }
    let own = m.sender_account == from;
    let age = c.sent_at - m.sent_at;
    match &c.body {
        Some(Body::Reaction(r)) => {
            if r.emoji.len() > MAX_REACTION {
                return Ok(false);
            }
            if commit {
                storage(s.set_reaction(target, from, &r.emoji))?;
            }
        }
        Some(Body::Edit(e)) => {
            let Ok(mut orig) = pb::Content::decode(m.body.as_slice()) else {
                return Ok(false);
            };
            let Some(Body::Text(t)) = &mut orig.body else {
                return Ok(false);
            };
            if !own || age > EDIT_WINDOW_MS || e.body.is_empty() || e.body.len() > MAX_TEXT {
                return Ok(false);
            }
            if commit {
                storage(s.save_version(target, &m.body))?;
                t.body = e.body.clone();
                m.body = orig.encode_to_vec();
                m.edited = true;
                storage(s.update_message(&m))?;
            }
        }
        _ => {
            if !own || age > DELETE_WINDOW_MS {
                return Ok(false);
            }
            if commit {
                m.body = Vec::new();
                m.deleted = true;
                storage(s.update_message(&m))?;
            }
        }
    }
    Ok(true)
}

impl SiegelCore {
    /// Off on our side also hides the other side's receipts or typing (reciprocal).
    pub(crate) fn enabled(&self, setting: &str) -> bool {
        self.setting(setting).as_deref() != Some("off")
    }

    pub(crate) fn me(&self) -> Result<Vec<u8>, CoreError> {
        self.get(ACCOUNT)?.ok_or(CoreError::new("not_registered"))
    }

    /// Sends a text, optionally replying to `reply_to` (MSG-07). The message is stored as
    /// Sending first; a network failure leaves it Failed for `retry` (MSG-04).
    pub async fn send_text(
        &self,
        group_id: &[u8],
        text: &str,
        reply_to: Option<&[u8]>,
    ) -> Result<ChatMessage, CoreError> {
        self.send_text_mentioning(group_id, text, reply_to, &[])
            .await
    }

    /// GRP-15: a text that @mentions these accounts (in groups).
    pub async fn send_text_mentioning(
        &self,
        group_id: &[u8],
        text: &str,
        reply_to: Option<&[u8]>,
        mentions: &[Vec<u8>],
    ) -> Result<ChatMessage, CoreError> {
        if text.is_empty() || text.len() > MAX_TEXT {
            return Err(CoreError::new("text_invalid"));
        }
        self.check_can_send(group_id)?;
        let content = self.new_content(pb::content::Body::Text(pb::Text {
            body: text.into(),
            reply_to: reply_to.unwrap_or_default().to_vec(),
            mentions: mentions.iter().take(256).cloned().collect(),
        }));
        let mut msg = Message {
            message_id: content.message_id.clone(),
            group_id: group_id.to_vec(),
            sender_account: self.me()?,
            sent_at: content.sent_at,
            body: content.encode_to_vec(),
            outgoing: true,
            status: Status::Sending,
            edited: false,
            deleted: false,
        };
        self.with_store(|s| storage(s.save_message(&msg)))?;
        self.deliver_stored(&mut msg).await?;
        chat_message(msg, vec![]).ok_or(CoreError::new("storage"))
    }

    pub(crate) fn check_can_send(&self, group_id: &[u8]) -> Result<(), CoreError> {
        if self.is_request(group_id)? {
            return Err(CoreError::new("request_pending")); // accept first (MSG-15)
        }
        if self.conversation(group_id)?.left {
            return Err(CoreError::new("group_left"));
        }
        Ok(())
    }

    /// Sends a Failed message again with the same ID; receivers deduplicate (MSG-03).
    pub async fn retry(&self, message_id: &[u8]) -> Result<(), CoreError> {
        let mut msg = self
            .with_store(|s| storage(s.message(message_id)))?
            .filter(|m| m.outgoing && m.status == Status::Failed)
            .ok_or(CoreError::new("not_allowed"))?;
        self.deliver_stored(&mut msg).await
    }

    pub(crate) async fn deliver_stored(&self, msg: &mut Message) -> Result<(), CoreError> {
        let content =
            pb::Content::decode(msg.body.as_slice()).map_err(|_| CoreError::new("storage"))?;
        let sent = self.deliver(&msg.group_id, &content).await;
        msg.status = if sent.is_ok() {
            Status::Sent
        } else {
            Status::Failed
        };
        // A delivery receipt may already have moved it further.
        self.with_store(|s| {
            storage(s.advance_status(
                &msg.group_id,
                std::slice::from_ref(&msg.message_id),
                msg.status,
            ))?;
            if msg.status == Status::Failed {
                storage(s.update_message(msg))?;
            }
            Ok(())
        })?;
        sent
    }

    /// Sends a change to one of the chat's messages, after checking it locally, then applies it.
    async fn change(&self, group_id: &[u8], body: pb::content::Body) -> Result<(), CoreError> {
        if self.is_request(group_id)? {
            return Err(CoreError::new("request_pending"));
        }
        if self.conversation(group_id)?.left {
            return Err(CoreError::new("group_left"));
        }
        let me = self.me()?;
        let content = self.new_content(body);
        if !self.with_store(|s| apply_change(s, group_id, &me, &content, false))? {
            return Err(CoreError::new("not_allowed"));
        }
        self.deliver(group_id, &content).await?;
        self.with_store(|s| apply_change(s, group_id, &me, &content, true))?;
        Ok(())
    }

    /// MSG-08: replaces our reaction; empty removes it.
    pub async fn react(
        &self,
        group_id: &[u8],
        message_id: &[u8],
        emoji: &str,
    ) -> Result<(), CoreError> {
        let r = pb::Reaction {
            message_id: message_id.to_vec(),
            emoji: emoji.into(),
        };
        self.change(group_id, pb::content::Body::Reaction(r)).await
    }

    /// MSG-09: our own text, within 15 minutes.
    pub async fn edit(
        &self,
        group_id: &[u8],
        message_id: &[u8],
        text: &str,
    ) -> Result<(), CoreError> {
        let e = pb::Edit {
            message_id: message_id.to_vec(),
            body: text.into(),
        };
        self.change(group_id, pb::content::Body::Edit(e)).await
    }

    /// MSG-11: our own message, within 48 hours.
    pub async fn delete_for_everyone(
        &self,
        group_id: &[u8],
        message_id: &[u8],
    ) -> Result<(), CoreError> {
        let d = pb::Delete {
            message_id: message_id.to_vec(),
        };
        self.change(group_id, pb::content::Body::Delete(d)).await?;
        self.forget_media(message_id);
        Ok(())
    }

    /// MSG-12: local only, any time.
    pub fn delete_for_me(&self, message_id: &[u8]) -> Result<(), CoreError> {
        self.with_store(|s| storage(s.delete_message(message_id)))?;
        self.forget_media(message_id);
        Ok(())
    }

    /// MSG-09: earlier texts of an edited message, oldest first.
    pub fn versions(&self, message_id: &[u8]) -> Result<Vec<String>, CoreError> {
        Ok(self
            .with_store(|s| storage(s.versions(message_id)))?
            .into_iter()
            .filter_map(|b| match pb::Content::decode(b.as_slice()).ok()?.body? {
                pb::content::Body::Text(t) => Some(t.body),
                _ => None,
            })
            .collect())
    }

    /// Unread incoming messages in the chat, for the chat list.
    pub fn unread(&self, group_id: &[u8]) -> Result<u32, CoreError> {
        self.with_store(|s| storage(s.unread(group_id)))
    }

    /// Marks the chat read; tells the sender unless read receipts are off or the chat is
    /// still a request (MSG-13, MSG-15).
    pub async fn mark_read(&self, group_id: &[u8]) -> Result<(), CoreError> {
        let ids = self.with_store(|s| storage(s.mark_read(group_id)))?;
        if ids.is_empty() || !self.enabled(READ_RECEIPTS) || self.is_request(group_id)? {
            return Ok(());
        }
        // One receipt per sender: in groups each goes to that sender only (GRP-13).
        let mut by_sender: Vec<(Vec<u8>, Vec<Vec<u8>>)> = Vec::new();
        for id in ids {
            let Some(m) = self.with_store(|s| storage(s.message(&id)))? else {
                continue;
            };
            match by_sender.iter_mut().find(|(a, _)| *a == m.sender_account) {
                Some((_, v)) => v.push(id),
                None => by_sender.push((m.sender_account, vec![id])),
            }
        }
        for (sender, ids) in by_sender {
            self.send_receipt(group_id, pb::receipt::Kind::Read, ids, &sender)
                .await?;
        }
        Ok(())
    }

    pub(crate) async fn send_receipt(
        &self,
        group_id: &[u8],
        kind: pb::receipt::Kind,
        message_ids: Vec<Vec<u8>>,
        to: &[u8],
    ) -> Result<(), CoreError> {
        let r = pb::Receipt {
            kind: kind as i32,
            message_ids,
        };
        let content = self.new_content(pb::content::Body::Receipt(r));
        let Ok(to) = <[u8; 16]>::try_from(to) else {
            return Ok(()); // system lines have no sender
        };
        self.deliver_to(group_id, &content, Some(&[to])).await
    }

    /// MSG-14: call at most every 3 seconds while the user types.
    pub async fn send_typing(&self, group_id: &[u8]) -> Result<(), CoreError> {
        if !self.enabled(TYPING) || self.is_request(group_id)? {
            return Ok(());
        }
        self.send_content(group_id, pb::content::Body::Typing(pb::Typing {}))
            .await
            .map(|_| ())
    }

    pub(crate) fn new_content(&self, body: pb::content::Body) -> pb::Content {
        pb::Content {
            message_id: uuid::Uuid::now_v7().as_bytes().to_vec(), // MSG-01
            sent_at: now_ms(),
            body: Some(body),
        }
    }
}
