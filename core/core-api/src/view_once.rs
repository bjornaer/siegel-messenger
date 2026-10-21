//! M9: view-once photos. The recipient's phone opens one once; then it is gone there, and the
//! sender never sees it again after sending. "Gone" means the message keeps its place in the
//! chat, but its key, blob reference and file are erased, so nothing on the device (or a
//! download from the server, before the blob expires) can show it again. Unopened ones go after
//! 14 days. Linked devices (a browser) never open them: they can't stop screenshots.

use core_net::pb;
use core_store::{Message, Status, Store as _};
use prost::Message as _;

use crate::{CoreError, SiegelCore, storage};

/// Unopened view-once photos are erased after this long.
pub(crate) const UNOPENED_MS: i64 = 14 * 24 * 3600 * 1000;
/// kv: the view-once messages on this device that still hold their key, as hex IDs.
const PENDING: &str = "view_once_pending";

/// The view-once attachment of a stored message, if it is one.
pub(crate) fn of(m: &Message) -> Option<pb::Attachment> {
    match pb::Content::decode(m.body.as_slice()).ok()?.body? {
        pb::content::Body::Attachment(a) if a.view_once => Some(a),
        _ => None,
    }
}

/// Whether a view-once attachment was already erased here.
pub(crate) fn gone(a: &pb::Attachment) -> bool {
    a.view_once && a.key.is_empty()
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|b| format!("{b:02x}")).collect()
}

/// Erases what could show the photo: its key, blob reference and preview, in the stored body.
fn stripped(m: &Message) -> Option<Vec<u8>> {
    let mut c = pb::Content::decode(m.body.as_slice()).ok()?;
    let Some(pb::content::Body::Attachment(a)) = c.body.as_mut() else {
        return None;
    };
    a.key.clear();
    a.blob_id.clear();
    a.sha256.clear();
    a.thumbnail.clear();
    Some(c.encode_to_vec())
}

impl SiegelCore {
    fn pending(&self) -> Vec<String> {
        self.get_string(PENDING)
            .map(|s| {
                s.split(',')
                    .filter(|x| !x.is_empty())
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default()
    }

    fn set_pending(&self, ids: &[String]) -> Result<(), CoreError> {
        self.put(PENDING, ids.join(",").as_bytes())
    }

    /// A view-once message arrived or was sent: remember it for the 14-day expiry. On a linked
    /// device it is erased at once, since it can't be opened there.
    pub(crate) fn view_once_arrived(&self, message_id: &[u8]) -> Result<(), CoreError> {
        if self.is_linked_device() {
            return self.erase_view_once(message_id, None);
        }
        let mut p = self.pending();
        p.push(hex(message_id));
        self.set_pending(&p)
    }

    /// Erases the photo here, keeping the message as a placeholder; `status` marks it opened.
    pub(crate) fn erase_view_once(
        &self,
        message_id: &[u8],
        status: Option<Status>,
    ) -> Result<(), CoreError> {
        if let Some(mut m) = self.with_store(|s| storage(s.message(message_id)))?
            && let Some(body) = stripped(&m)
        {
            m.body = body;
            if let Some(st) = status {
                m.status = st;
            }
            self.with_store(|s| storage(s.update_message(&m)))?;
        }
        self.forget_media(message_id);
        let id = hex(message_id);
        let p: Vec<String> = self.pending().into_iter().filter(|x| *x != id).collect();
        self.set_pending(&p)
    }

    /// Opens a view-once photo: its bytes, this once. Then it is erased here and, unless read
    /// receipts are off, the sender learns it was opened.
    pub async fn open_view_once(&self, message_id: &[u8]) -> Result<Vec<u8>, CoreError> {
        if self.is_linked_device() {
            return Err(CoreError::new("view_once_phone_only"));
        }
        let m = self
            .with_store(|s| storage(s.message(message_id)))?
            .filter(|m| !m.deleted && !m.outgoing)
            .ok_or(CoreError::new("not_found"))?;
        let a = of(&m).ok_or(CoreError::new("not_found"))?;
        if gone(&a) {
            return Err(CoreError::new("view_once_gone"));
        }
        let data = self.attachment_bytes(message_id, &a).await;
        // Erased whatever happened: a failed download isn't a second chance.
        self.erase_view_once(message_id, Some(Status::Opened))?;
        let data = data?;
        if self.enabled(crate::messages::READ_RECEIPTS) && !self.is_request(&m.group_id)? {
            let _ = self
                .send_receipt(
                    &m.group_id,
                    pb::receipt::Kind::Opened,
                    vec![message_id.to_vec()],
                    &m.sender_account,
                )
                .await;
        }
        Ok(data)
    }

    /// Upkeep: erases view-once photos nobody opened within 14 days, on both sides.
    pub(crate) fn expire_view_once(&self) -> Result<(), CoreError> {
        let cutoff = crate::chat::now_ms() - UNOPENED_MS;
        for id in self.pending() {
            let Ok(raw) = (0..id.len())
                .step_by(2)
                .map(|i| u8::from_str_radix(&id[i..i + 2], 16))
                .collect::<Result<Vec<u8>, _>>()
            else {
                continue;
            };
            match self.with_store(|s| storage(s.message(&raw)))? {
                Some(m) if m.sent_at >= cutoff => {}
                _ => self.erase_view_once(&raw, None)?,
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stripped_keeps_the_placeholder_only() {
        let c = pb::Content {
            message_id: vec![1; 16],
            body: Some(pb::content::Body::Attachment(pb::Attachment {
                blob_id: vec![2; 16],
                key: vec![3; 32],
                sha256: vec![4; 32],
                thumbnail: vec![5; 10],
                mime_type: "image/jpeg".into(),
                view_once: true,
                ..Default::default()
            })),
            ..Default::default()
        };
        let m = Message {
            message_id: vec![1; 16],
            group_id: vec![9; 16],
            sender_account: vec![7; 16],
            sent_at: 0,
            body: c.encode_to_vec(),
            outgoing: false,
            status: Status::Delivered,
            edited: false,
            deleted: false,
        };
        let a = of(&m).unwrap();
        assert!(!gone(&a));
        let after = Message {
            body: stripped(&m).unwrap(),
            ..m
        };
        let a = of(&after).unwrap();
        assert!(gone(&a));
        assert!(a.blob_id.is_empty() && a.sha256.is_empty() && a.thumbnail.is_empty());
        assert_eq!(a.mime_type, "image/jpeg");
    }
}
