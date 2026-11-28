//! Big files in the browser, which has no files of its own to keep them in: sent as the page
//! reads them, a slice at a time, and received the same way, straight into a file the person
//! saves. Nothing is kept here, so a closed tab can't resume them; phones queue files instead
//! (`queue_attachment_file`).

use core_media::{CHUNK, Encryptor, PART, PREFIX};
use core_net::pb;
use core_store::{Message, Status, Store};
use prost::Message as _;

use crate::chat::{ChatMessage, chat_message};
use crate::media::{MAX_ATTACHMENT, MAX_THUMBNAIL, MAX_WAVEFORM, OutgoingAttachment, upload_key};
use crate::{CoreError, SiegelCore, storage};

/// A send under way: the blob's next bytes wait in `buf` until a whole part is there.
pub(crate) struct Upload {
    enc: Encryptor,
    buf: Vec<u8>,
    path: String,
    part: usize,
    len: u64,
}

/// A download under way: ciphertext from `buf` on is chunk `chunk` onwards.
pub(crate) struct Download {
    a: pb::Attachment,
    part: usize,
    buf: Vec<u8>,
    chunk: u64,
    prefix: Vec<u8>,
}

/// The upload state a streamed send has until all of it is up.
const STREAMING: &[u8] = b"stream";

impl SiegelCore {
    /// The browser: a file of up to 1 GB of `size` bytes, shown at once as sending. Hand it over
    /// with `push_attachment_stream`, in pieces of whole 64 KB chunks (the last any length);
    /// once that says it's all up, `retry` sends the message.
    pub async fn queue_attachment_stream(
        &self,
        group_id: &[u8],
        size: u64,
        a: OutgoingAttachment,
        reply_to: Option<&[u8]>,
    ) -> Result<ChatMessage, CoreError> {
        if size as usize > MAX_ATTACHMENT {
            return Err(CoreError::new("attachment_too_large"));
        }
        if size == 0 || a.thumbnail.len() > MAX_THUMBNAIL || a.view_once {
            return Err(CoreError::new("attachment_invalid"));
        }
        self.check_can_send(group_id)?;
        let enc = Encryptor::new(size);
        let len = core_media::blob_len(size as usize) as u64;
        let (blob_id, path) = self.net.create_upload(&self.token()?, len, false).await?;
        let content = self.new_content(pb::content::Body::Attachment(pb::Attachment {
            blob_id,
            key: enc.key().to_vec(),
            size: size as i64,
            mime_type: a.mime_type,
            file_name: a.file_name,
            duration_ms: a.duration_ms,
            voice_note: a.voice_note,
            waveform: a.waveform.into_iter().take(MAX_WAVEFORM).collect(),
            width: a.width,
            height: a.height,
            thumbnail: a.thumbnail,
            sticker: a.sticker,
            reply_to: reply_to.unwrap_or_default().to_vec(),
            ..Default::default() // the hash once it's all up
        }));
        let msg = Message {
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
        self.put(&upload_key(&msg.message_id), STREAMING)?;
        self.with_store(|s| storage(s.save_message(&msg)))?;
        let up = Upload {
            enc,
            buf: vec![],
            path,
            part: 0,
            len,
        };
        self.uploads
            .lock()
            .unwrap()
            .insert(msg.message_id.clone(), Some(up));
        chat_message(msg, vec![]).ok_or(CoreError::new("storage"))
    }

    /// The file's next piece; empty to try again after an error (nothing is lost while the
    /// page is open). True once all of it is up.
    pub async fn push_attachment_stream(
        &self,
        message_id: &[u8],
        plain: &[u8],
    ) -> Result<bool, CoreError> {
        let mut up = self
            .uploads
            .lock()
            .unwrap()
            .get_mut(message_id)
            .and_then(Option::take)
            .ok_or(CoreError::new("not_found"))?;
        let res = self.push(message_id, &mut up, plain).await;
        match res {
            Ok(false) | Err(_) => {
                self.uploads
                    .lock()
                    .unwrap()
                    .insert(message_id.to_vec(), Some(up));
                res
            }
            Ok(true) => {
                self.uploads.lock().unwrap().remove(message_id);
                self.transfers.lock().unwrap().remove(message_id);
                let sha = up.enc.finish();
                let mut msg = self
                    .with_store(|s| storage(s.message(message_id)))?
                    .ok_or(CoreError::new("not_found"))?;
                let mut c = pb::Content::decode(msg.body.as_slice())
                    .map_err(|_| CoreError::new("storage"))?;
                if let Some(pb::content::Body::Attachment(a)) = &mut c.body {
                    a.sha256 = sha.to_vec();
                }
                msg.body = c.encode_to_vec();
                self.with_store(|s| storage(s.update_message(&msg)))?;
                self.put(&upload_key(message_id), b"")?; // up: `retry` sends it
                Ok(true)
            }
        }
    }

    async fn push(
        &self,
        message_id: &[u8],
        up: &mut Upload,
        plain: &[u8],
    ) -> Result<bool, CoreError> {
        if !plain.is_empty() {
            let out = up
                .enc
                .push(plain)
                .map_err(|_| CoreError::new("attachment_invalid"))?;
            up.buf.extend(out);
        }
        loop {
            if up.buf.len() < PART {
                let pad = up.enc.pad(PART - up.buf.len());
                up.buf.extend(pad);
            }
            if up.buf.len() < PART && !(up.enc.padded() && !up.buf.is_empty()) {
                return Ok(up.enc.padded() && up.buf.is_empty());
            }
            let n = up.buf.len().min(PART);
            match self
                .net
                .put_part(&up.path, up.part, up.buf[..n].to_vec())
                .await
            {
                Ok(None) => {}
                Ok(Some(next)) if next == up.part + 1 => {} // it had this one already
                Ok(Some(_)) => return Err(CoreError::new("upload_failed")),
                Err(e) => return Err(e.into()),
            }
            up.buf.drain(..n);
            up.part += 1;
            self.track(
                message_id,
                (up.part * PART).min(up.len as usize) as u64,
                up.len,
            );
        }
    }

    /// A streamed send that `retry` found not all up (the page closed, or gave up on it): it
    /// can only fail, and the file must be sent again.
    pub(crate) fn stream_broke(&self, message_id: &[u8], state: &[u8]) -> bool {
        if state != STREAMING {
            return false;
        }
        self.uploads.lock().unwrap().remove(message_id);
        self.transfers.lock().unwrap().remove(message_id);
        true
    }

    /// A streamed send still going in this page: leave it to the page.
    pub(crate) fn streaming(&self, message_id: &[u8]) -> bool {
        self.uploads.lock().unwrap().contains_key(message_id)
    }

    /// The browser: an attachment's plaintext, the next piece of it each call (from the start
    /// when `first`), downloaded part by part; empty once it's all come. Every 64 KB chunk is
    /// authenticated as it's opened, the last one marked as last, so nothing can be cut off
    /// or changed unnoticed.
    pub async fn attachment_next(
        &self,
        message_id: &[u8],
        first: bool,
    ) -> Result<Vec<u8>, CoreError> {
        let taken = if first {
            None
        } else {
            self.downloads.lock().unwrap().remove(message_id)
        };
        let mut d = match taken {
            Some(d) => d,
            None => {
                let a = self.attachment_of(message_id)?;
                if a.view_once {
                    return Err(CoreError::new("view_once"));
                }
                Download {
                    a,
                    part: 0,
                    buf: vec![],
                    chunk: 0,
                    prefix: vec![],
                }
            }
        };
        let size = d.a.size as u64;
        let chunks = size.div_ceil(CHUNK as u64).max(1);
        if d.chunk == chunks {
            return Ok(vec![]); // all come
        }
        let token = self.token()?;
        let len = core_media::blob_len(size as usize) as u64;
        let mut plain = vec![];
        // A piece at least: empty means it has all come.
        while plain.is_empty() && d.chunk < chunks {
            let ct = match self.net.get_part(&token, &d.a.blob_id, d.part).await {
                Ok(ct) => ct,
                Err(e) => {
                    self.downloads
                        .lock()
                        .unwrap()
                        .insert(message_id.to_vec(), d); // the same part again next time
                    return Err(e.into());
                }
            };
            d.part += 1;
            d.buf.extend(ct);
            if d.prefix.is_empty() {
                if d.buf.len() < PREFIX {
                    return Err(CoreError::new("attachment_corrupt"));
                }
                d.prefix = d.buf.drain(..PREFIX).collect();
            }
            while d.chunk < chunks {
                let (_, n, last) = core_media::chunk_at(size, d.chunk);
                if d.buf.len() < n {
                    break;
                }
                let p = core_media::decrypt_chunk(
                    &d.a.key,
                    &d.prefix,
                    d.chunk as u32,
                    last,
                    &d.buf[..n],
                )
                .ok_or(CoreError::new("attachment_corrupt"))?;
                plain.extend(p);
                d.buf.drain(..n);
                d.chunk += 1;
            }
            self.track(message_id, (d.part * PART) as u64, len);
        }
        if d.chunk == chunks {
            self.transfers.lock().unwrap().remove(message_id);
            d.buf = vec![]; // kept only to say it's all come
        }
        self.downloads
            .lock()
            .unwrap()
            .insert(message_id.to_vec(), d);
        Ok(plain)
    }
}
