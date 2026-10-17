//! Attachments (MED-01..06, MED-09): encrypted on this device, uploaded as an opaque blob, and
//! announced inside MLS. The blob is kept here as ciphertext (its key lives only in the
//! encrypted database); the app gets plaintext in memory, never as a file.

use std::path::PathBuf;

use core_net::pb;
use core_store::{Message, Status, Store};
use prost::Message as _;
use sha2::{Digest, Sha256};

use crate::chat::{ChatMessage, chat_message};
use crate::{CoreError, SiegelCore, storage};

/// MED-06.
pub(crate) const MAX_ATTACHMENT: usize = 100 << 20;
/// MED-04.
const MAX_THUMBNAIL: usize = 20 << 10;
/// MED-09: one byte per waveform bar.
const MAX_WAVEFORM: usize = 256;

/// What the app knows about an attachment before it is downloaded.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct AttachmentInfo {
    pub mime_type: String,
    pub file_name: String,
    pub size: u64,
    pub duration_ms: u32,
    pub voice_note: bool,
    pub waveform: Vec<u8>,
}

/// A file to send.
pub struct OutgoingAttachment {
    pub data: Vec<u8>,
    pub mime_type: String,
    pub file_name: String,
    pub duration_ms: u32,
    pub voice_note: bool,
    pub waveform: Vec<u8>,
}

/// Rejects attachment messages no honest client sends.
pub(crate) fn valid(a: &pb::Attachment) -> bool {
    a.blob_id.len() == 16
        && a.key.len() == 32
        && a.sha256.len() == 32
        && a.size as usize <= MAX_ATTACHMENT
        && a.thumbnail.len() <= MAX_THUMBNAIL
        && a.waveform.len() <= MAX_WAVEFORM
        && a.mime_type.len() <= 255
        && a.file_name.len() <= 255
}

pub(crate) fn info(a: &pb::Attachment) -> AttachmentInfo {
    AttachmentInfo {
        mime_type: a.mime_type.clone(),
        file_name: a.file_name.clone(),
        size: a.size as u64,
        duration_ms: a.duration_ms,
        voice_note: a.voice_note,
        waveform: a.waveform.clone(),
    }
}

impl SiegelCore {
    fn media_path(&self, message_id: &[u8]) -> PathBuf {
        let name: String = message_id.iter().map(|b| format!("{b:02x}")).collect();
        self.media_dir.join(name)
    }

    /// Drops a message's blob from this device (MSG-11, MSG-12).
    pub(crate) fn forget_media(&self, message_id: &[u8]) {
        let _ = std::fs::remove_file(self.media_path(message_id));
    }

    /// MED-01..03: encrypts and uploads; returns the reference to put in a message or profile
    /// (blob ID, key, hash, size) and the ciphertext.
    pub(crate) async fn upload(
        &self,
        data: &[u8],
        renewable: bool,
    ) -> Result<(pb::Attachment, Vec<u8>), CoreError> {
        let (key, blob) = core_media::encrypt(data);
        let (blob_id, upload) = self
            .net
            .create_upload(&self.token()?, blob.len() as u64, renewable)
            .await?;
        let a = pb::Attachment {
            blob_id,
            key: key.to_vec(),
            sha256: Sha256::digest(&blob).to_vec(),
            size: data.len() as i64,
            ..Default::default()
        };
        self.net.put_blob(&upload, blob.clone()).await?;
        Ok((a, blob))
    }

    /// Downloads a blob and checks it against its reference (MED-05).
    pub(crate) async fn download(&self, a: &pb::Attachment) -> Result<Vec<u8>, CoreError> {
        let b = self.net.get_blob(&self.token()?, &a.blob_id).await?;
        if Sha256::digest(&b).as_slice() != a.sha256 {
            return Err(CoreError::new("attachment_corrupt"));
        }
        Ok(b)
    }

    /// Encrypts and uploads the file, then sends it like a text (MSG-04: Failed on a network
    /// error, `retry` resends the message; the blob is already up).
    pub async fn send_attachment(
        &self,
        group_id: &[u8],
        a: OutgoingAttachment,
        reply_to: Option<&[u8]>,
    ) -> Result<ChatMessage, CoreError> {
        if a.data.len() > MAX_ATTACHMENT {
            return Err(CoreError::new("attachment_too_large"));
        }
        self.check_can_send(group_id)?;
        let (uploaded, blob) = self.upload(&a.data, false).await?;
        let content = self.new_content(pb::content::Body::Attachment(pb::Attachment {
            mime_type: a.mime_type,
            file_name: a.file_name,
            duration_ms: a.duration_ms,
            voice_note: a.voice_note,
            waveform: a.waveform.into_iter().take(MAX_WAVEFORM).collect(),
            reply_to: reply_to.unwrap_or_default().to_vec(),
            ..uploaded
        }));
        std::fs::create_dir_all(&self.media_dir).map_err(|_| CoreError::new("storage"))?;
        std::fs::write(self.media_path(&content.message_id), &blob)
            .map_err(|_| CoreError::new("storage"))?;
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

    /// The attachment's plaintext, downloading it first if needed. "attachment_expired" once
    /// the server deleted it (MED-13); "attachment_corrupt" if it fails MED-05's hash check.
    pub async fn attachment_data(&self, message_id: &[u8]) -> Result<Vec<u8>, CoreError> {
        let m = self
            .with_store(|s| storage(s.message(message_id)))?
            .filter(|m| !m.deleted)
            .ok_or(CoreError::new("not_found"))?;
        let Some(pb::content::Body::Attachment(a)) = pb::Content::decode(m.body.as_slice())
            .ok()
            .and_then(|c| c.body)
        else {
            return Err(CoreError::new("not_found"));
        };
        let path = self.media_path(message_id);
        let blob = match std::fs::read(&path) {
            Ok(b) => b,
            Err(_) => {
                let b = self.download(&a).await?;
                std::fs::create_dir_all(&self.media_dir).map_err(|_| CoreError::new("storage"))?;
                std::fs::write(&path, &b).map_err(|_| CoreError::new("storage"))?;
                b
            }
        };
        core_media::decrypt(&a.key, &blob, a.size as usize)
            .ok_or(CoreError::new("attachment_corrupt"))
    }
}
