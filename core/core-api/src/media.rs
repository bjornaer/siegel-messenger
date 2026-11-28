//! Attachments (MED-01..06, MED-09): encrypted on this device, uploaded as an opaque blob, and
//! announced inside MLS. The blob is kept here as ciphertext (its key lives only in the
//! encrypted database); the app gets plaintext in memory, never as a file.

#[cfg(not(target_family = "wasm"))]
use std::path::PathBuf;

use core_net::pb;
use core_store::{Message, Status, Store};
use prost::Message as _;
use sha2::{Digest, Sha256};

use crate::chat::{ChatMessage, chat_message};
use crate::{CoreError, SiegelCore, storage};

fn hex(b: &[u8]) -> String {
    b.iter().map(|b| format!("{b:02x}")).collect()
}

/// MED-06.
pub(crate) const MAX_ATTACHMENT: usize = 1 << 30;
/// Beyond this an attachment is only handled as a file (`attachment_file`), never in memory.
const MAX_IN_MEMORY: usize = 100 << 20;
/// Where decrypted copies for opening and playing go, under the media directory; cleared at
/// each start.
#[cfg(not(target_family = "wasm"))]
pub(crate) const OPEN: &str = "open";
use core_media::PART;
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
    /// Images and video (MED-04).
    pub width: u32,
    pub height: u32,
    /// A small JPEG preview (images and video), at most 20 KB.
    pub thumbnail: Vec<u8>,
    pub sticker: bool,
    /// M9: opens once, on the recipient's phone.
    pub view_once: bool,
    /// M9: a view-once photo already opened or expired here: only its placeholder is left.
    pub gone: bool,
}

/// A file to send.
#[derive(Default)]
pub struct OutgoingAttachment {
    pub data: Vec<u8>,
    pub mime_type: String,
    pub file_name: String,
    pub duration_ms: u32,
    pub voice_note: bool,
    pub waveform: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub thumbnail: Vec<u8>,
    pub sticker: bool,
    pub view_once: bool,
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
        width: a.width,
        height: a.height,
        thumbnail: a.thumbnail.clone(),
        sticker: a.sticker,
        view_once: a.view_once,
        gone: crate::view_once::gone(a),
    }
}

impl SiegelCore {
    #[cfg(not(target_family = "wasm"))]
    fn media_path(&self, message_id: &[u8]) -> PathBuf {
        self.media_dir.join(hex(message_id))
    }

    /// The kept ciphertext of a message's attachment. A file on phones; in the browser, which
    /// has no files, a row in the encrypted database (M8).
    fn media_read(&self, message_id: &[u8]) -> Option<Vec<u8>> {
        #[cfg(not(target_family = "wasm"))]
        return std::fs::read(self.media_path(message_id)).ok();
        #[cfg(target_family = "wasm")]
        return self
            .get(&format!("media/{}", hex(message_id)))
            .ok()
            .flatten();
    }

    fn media_write(&self, message_id: &[u8], blob: &[u8]) -> Result<(), CoreError> {
        #[cfg(not(target_family = "wasm"))]
        {
            std::fs::create_dir_all(&self.media_dir).map_err(|_| CoreError::new("storage"))?;
            std::fs::write(self.media_path(message_id), blob).map_err(|_| CoreError::new("storage"))
        }
        #[cfg(target_family = "wasm")]
        self.put(&format!("media/{}", hex(message_id)), blob)
    }

    /// Drops a message's blob from this device (MSG-11, MSG-12).
    pub(crate) fn forget_media(&self, message_id: &[u8]) {
        #[cfg(not(target_family = "wasm"))]
        let _ = std::fs::remove_file(self.media_path(message_id));
        #[cfg(target_family = "wasm")]
        let _ = self.put(&format!("media/{}", hex(message_id)), b"");
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
        self.put_parts(&upload, blob.len() as u64, 0, &[], |off, n| {
            Ok(blob[off as usize..off as usize + n].to_vec())
        })
        .await?;
        Ok((a, blob))
    }

    /// Uploads a blob of `len` bytes in parts from `read(offset, length)`, from part `from` (or
    /// wherever the server says it got to). `done(next)` after each part, to resume from.
    async fn put_parts(
        &self,
        upload_path: &str,
        len: u64,
        from: usize,
        track: &[u8],
        read: impl Fn(u64, usize) -> Result<Vec<u8>, CoreError>,
    ) -> Result<(), CoreError> {
        self.put_parts_saving(upload_path, len, from, track, read, |_| Ok(()))
            .await
    }

    async fn put_parts_saving(
        &self,
        upload_path: &str,
        len: u64,
        from: usize,
        track: &[u8],
        read: impl Fn(u64, usize) -> Result<Vec<u8>, CoreError>,
        done: impl Fn(usize) -> Result<(), CoreError>,
    ) -> Result<(), CoreError> {
        let parts = (len as usize).div_ceil(PART).max(1);
        let mut n = from;
        while n < parts {
            let off = (n * PART) as u64;
            let part = read(off, PART.min((len - off) as usize))?;
            match self.net.put_part(upload_path, n, part).await {
                Ok(None) => n += 1,
                Ok(Some(next)) if next != n => n = next, // it has more (or less) than we thought
                Ok(Some(_)) => return Err(CoreError::new("upload_failed")),
                // The last part landed but its answer was lost: the upload is complete.
                Err(e) if e.code == "upload_gone" && n + 1 == parts && n > from => n += 1,
                Err(e) => return Err(e.into()),
            }
            done(n)?;
            self.track(track, (n * PART).min(len as usize) as u64, len);
        }
        Ok(())
    }

    /// Records a transfer's progress for `transfer_progress`; done once all bytes are there.
    fn track(&self, message_id: &[u8], done: u64, total: u64) {
        if message_id.is_empty() {
            return;
        }
        let mut t = self.transfers.lock().unwrap();
        if done >= total {
            t.remove(message_id);
        } else {
            t.insert(message_id.to_vec(), (done, total));
        }
    }

    /// An upload or download under way: (bytes done, bytes in all).
    pub fn transfer_progress(&self, message_id: &[u8]) -> Option<(u64, u64)> {
        self.transfers.lock().unwrap().get(message_id).copied()
    }

    /// Downloads a blob, part by part, into memory, and checks it against its reference (MED-05).
    pub(crate) async fn download(&self, a: &pb::Attachment) -> Result<Vec<u8>, CoreError> {
        let len = core_media::blob_len(a.size as usize);
        let token = self.token()?;
        let mut b = Vec::with_capacity(len);
        for n in 0..len.div_ceil(PART) {
            b.extend(self.net.get_part(&token, &a.blob_id, n).await?);
        }
        if b.len() != len || Sha256::digest(&b).as_slice() != a.sha256 {
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
        self.send_attachment_as(group_id, a, reply_to, false).await
    }

    async fn send_attachment_as(
        &self,
        group_id: &[u8],
        a: OutgoingAttachment,
        reply_to: Option<&[u8]>,
        forwarded: bool,
    ) -> Result<ChatMessage, CoreError> {
        if a.data.len() > MAX_ATTACHMENT {
            return Err(CoreError::new("attachment_too_large"));
        }
        if a.thumbnail.len() > MAX_THUMBNAIL {
            return Err(CoreError::new("attachment_invalid"));
        }
        self.check_can_send(group_id)?;
        let (uploaded, blob) = self.upload(&a.data, false).await?;
        let view_once = a.view_once;
        let mut content = self.new_content(pb::content::Body::Attachment(pb::Attachment {
            view_once,
            mime_type: a.mime_type,
            file_name: a.file_name,
            duration_ms: a.duration_ms,
            voice_note: a.voice_note,
            waveform: a.waveform.into_iter().take(MAX_WAVEFORM).collect(),
            width: a.width,
            height: a.height,
            // M9: no preview of a view-once photo, not even blurred.
            thumbnail: if view_once { vec![] } else { a.thumbnail },
            sticker: a.sticker,
            reply_to: reply_to.unwrap_or_default().to_vec(),
            ..uploaded
        }));
        content.forwarded = forwarded;
        if !view_once {
            self.media_write(&content.message_id, &blob)?; // a view-once one isn't kept here
        }
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
        if view_once {
            // Sent: the sender keeps the placeholder only (until then a retry needs the key).
            self.erase_view_once(&msg.message_id, None)?;
            msg = self
                .with_store(|s| storage(s.message(&msg.message_id)))?
                .unwrap_or(msg);
        }
        chat_message(msg, vec![]).ok_or(CoreError::new("storage"))
    }

    /// MED-12: downloads an attachment ahead of time, without opening it.
    pub async fn fetch_attachment(&self, message_id: &[u8]) -> Result<(), CoreError> {
        #[cfg(not(target_family = "wasm"))]
        {
            let a = self.attachment_of(message_id)?;
            if a.view_once {
                return Ok(()); // fetched when opened, once
            }
            self.fetch_blob(message_id, &a).await
        }
        #[cfg(target_family = "wasm")]
        self.attachment_data(message_id).await.map(|_| ())
    }

    /// Whether the attachment is on this device already (sent, or downloaded before).
    pub fn attachment_downloaded(&self, message_id: &[u8]) -> bool {
        #[cfg(not(target_family = "wasm"))]
        return self.media_path(message_id).exists();
        #[cfg(target_family = "wasm")]
        return self.media_read(message_id).is_some_and(|b| !b.is_empty());
    }

    /// MED-14: sends a message on to another chat. An attachment is encrypted again with a
    /// new key and uploaded again, so the two chats share nothing.
    pub async fn forward(&self, message_id: &[u8], to: &[u8]) -> Result<ChatMessage, CoreError> {
        let m = self
            .with_store(|s| storage(s.message(message_id)))?
            .filter(|m| !m.deleted)
            .ok_or(CoreError::new("not_found"))?;
        match pb::Content::decode(m.body.as_slice())
            .ok()
            .and_then(|c| c.body)
        {
            Some(pb::content::Body::Text(t)) => {
                let mut msg = self.queue(to, &t.body, None, &[])?;
                self.mark_forwarded(&mut msg)?;
                self.deliver_stored(&mut msg).await?;
                chat_message(msg, vec![]).ok_or(CoreError::new("storage"))
            }
            #[cfg(not(target_family = "wasm"))]
            Some(pb::content::Body::Attachment(a)) if !a.view_once => {
                let path = self.attachment_file(message_id).await?;
                let out = OutgoingAttachment {
                    mime_type: a.mime_type,
                    file_name: a.file_name,
                    duration_ms: a.duration_ms,
                    voice_note: a.voice_note,
                    waveform: a.waveform,
                    width: a.width,
                    height: a.height,
                    thumbnail: a.thumbnail,
                    sticker: a.sticker,
                    ..Default::default()
                };
                let m = self.queue_attachment_file(to, &path, out, None).await?;
                let mut msg = self
                    .with_store(|s| storage(s.message(&m.message_id)))?
                    .ok_or(CoreError::new("storage"))?;
                self.mark_forwarded(&mut msg)?;
                self.retry(&m.message_id).await?;
                self.with_store(|s| storage(s.message(&m.message_id)))?
                    .and_then(|m| chat_message(m, vec![]))
                    .ok_or(CoreError::new("storage"))
            }
            Some(pb::content::Body::Attachment(a)) => {
                let data = self.attachment_data(message_id).await?;
                let out = OutgoingAttachment {
                    data,
                    mime_type: a.mime_type,
                    file_name: a.file_name,
                    duration_ms: a.duration_ms,
                    voice_note: a.voice_note,
                    waveform: a.waveform,
                    width: a.width,
                    height: a.height,
                    thumbnail: a.thumbnail,
                    sticker: a.sticker,
                    view_once: false, // never reached: a view-once one can't be read here
                };
                self.send_attachment_as(to, out, None, true).await
            }
            _ => Err(CoreError::new("not_allowed")),
        }
    }

    /// Flags a message still waiting to send as forwarded, before it goes out.
    fn mark_forwarded(&self, msg: &mut Message) -> Result<(), CoreError> {
        let mut c =
            pb::Content::decode(msg.body.as_slice()).map_err(|_| CoreError::new("storage"))?;
        c.forwarded = true;
        msg.body = c.encode_to_vec();
        self.with_store(|s| storage(s.update_message(msg)))
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
        if a.view_once {
            return Err(CoreError::new("view_once")); // only open_view_once, once
        }
        self.attachment_bytes(message_id, &a).await
    }

    /// Downloads (if needed) and decrypts an attachment.
    pub(crate) async fn attachment_bytes(
        &self,
        message_id: &[u8],
        a: &pb::Attachment,
    ) -> Result<Vec<u8>, CoreError> {
        if a.size as usize > MAX_IN_MEMORY {
            return Err(CoreError::new("attachment_too_large")); // attachment_file opens these
        }
        #[cfg(not(target_family = "wasm"))]
        self.fetch_blob(message_id, a).await?;
        let blob = match self.media_read(message_id).filter(|b| !b.is_empty()) {
            Some(b) => b,
            None => {
                let b = self.download(a).await?;
                self.media_write(message_id, &b)?;
                b
            }
        };
        core_media::decrypt(&a.key, &blob, a.size as usize)
            .ok_or(CoreError::new("attachment_corrupt"))
    }
}

/// Phones: big attachments go through files, never whole in memory.
#[cfg(not(target_family = "wasm"))]
impl SiegelCore {
    /// The kept blob, downloaded part by part into a file if it isn't here yet. A dropped
    /// download resumes from the last whole part; the hash is checked before it counts as here.
    pub(crate) async fn fetch_blob(
        &self,
        message_id: &[u8],
        a: &pb::Attachment,
    ) -> Result<(), CoreError> {
        use std::io::{Seek, Write};
        let path = self.media_path(message_id);
        if path.metadata().is_ok_and(|m| m.len() > 0) {
            return Ok(());
        }
        // One download per attachment: a second caller waits for the first.
        let _going = loop {
            if let Some(c) = crate::Claim::take(&self.fetching, message_id) {
                break c;
            }
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            if path.exists() {
                return Ok(());
            }
        };
        let result = async {
            let io = |_| CoreError::new("storage");
            let len = core_media::blob_len(a.size as usize) as u64;
            std::fs::create_dir_all(&self.media_dir).map_err(io)?;
            let part_path = path.with_extension("part");
            let mut f = std::fs::OpenOptions::new()
                .create(true)
                .truncate(false)
                .read(true)
                .write(true)
                .open(&part_path)
                .map_err(io)?;
            let have = f.metadata().map_err(io)?.len() / PART as u64 * PART as u64;
            f.set_len(have).map_err(io)?;
            f.seek(std::io::SeekFrom::Start(have)).map_err(io)?;
            let token = self.token()?;
            for n in (have / PART as u64) as usize..(len as usize).div_ceil(PART) {
                let part = self.net.get_part(&token, &a.blob_id, n).await?;
                if part.len() as u64 != (len - (n * PART) as u64).min(PART as u64) {
                    return Err(CoreError::new("network")); // cut short
                }
                f.write_all(&part).map_err(io)?;
                self.track(message_id, (n * PART + part.len()) as u64, len + 1);
            }
            f.flush().map_err(io)?;
            f.seek(std::io::SeekFrom::Start(0)).map_err(io)?;
            let mut h = Sha256::new();
            std::io::copy(&mut std::io::BufReader::new(&f), &mut h).map_err(io)?;
            if h.finalize().as_slice() != a.sha256 {
                let _ = std::fs::remove_file(&part_path);
                return Err(CoreError::new("attachment_corrupt"));
            }
            std::fs::rename(&part_path, &path).map_err(io)
        }
        .await;
        self.track(message_id, 1, 1); // done or failed: no bar
        result
    }

    /// The attachment as a decrypted file to open or play, downloading it first if needed. The
    /// copy lives in the app's media directory until the app next starts.
    pub async fn attachment_file(&self, message_id: &[u8]) -> Result<String, CoreError> {
        let a = self.attachment_of(message_id)?;
        if a.view_once {
            return Err(CoreError::new("view_once"));
        }
        self.fetch_blob(message_id, &a).await?;
        let io = |_| CoreError::new("storage");
        let dir = self.media_dir.join(OPEN);
        std::fs::create_dir_all(&dir).map_err(io)?;
        let ext = match a.file_name.rsplit_once('.') {
            Some((_, e))
                if !e.is_empty()
                    && e.len() <= 8
                    && e.chars().all(|c| c.is_ascii_alphanumeric()) =>
            {
                e
            }
            _ => match a.mime_type.as_str() {
                "video/quicktime" => "mov",
                t => t
                    .rsplit('/')
                    .next()
                    .filter(|e| e.chars().all(|c| c.is_ascii_alphanumeric()))
                    .unwrap_or("bin"),
            },
        };
        let out = dir.join(format!("{}.{ext}", hex(message_id)));
        if out.metadata().is_ok_and(|m| m.len() == a.size as u64) {
            return Ok(out.to_string_lossy().into_owned());
        }
        let tmp = out.with_extension("tmp");
        let src = std::fs::File::open(self.media_path(message_id)).map_err(io)?;
        let dst = std::fs::File::create(&tmp).map_err(io)?;
        let mut w = std::io::BufWriter::new(dst);
        core_media::decrypt_stream(&a.key, std::io::BufReader::new(src), a.size as u64, &mut w)
            .map_err(|_| CoreError::new("attachment_corrupt"))?;
        std::io::Write::flush(&mut w).map_err(io)?;
        std::fs::rename(&tmp, &out).map_err(io)?;
        Ok(out.to_string_lossy().into_owned())
    }

    /// `len` bytes of an attachment's plaintext from `offset`, decrypting only the 64 KB chunks
    /// they span (each is authenticated on its own): a video plays from anywhere with no
    /// decrypted copy. While `fetch_attachment` is downloading it, waits for those bytes.
    pub async fn attachment_range(
        &self,
        message_id: &[u8],
        offset: u64,
        len: u64,
    ) -> Result<Vec<u8>, CoreError> {
        use std::os::unix::fs::FileExt;
        let a = self.attachment_of(message_id)?;
        if a.view_once {
            return Err(CoreError::new("view_once"));
        }
        let size = a.size as u64;
        if offset >= size || len == 0 {
            return Ok(vec![]);
        }
        let end = (offset + len).min(size);
        let chunk = core_media::CHUNK as u64;
        let (first, last) = (offset / chunk, (end - 1) / chunk);
        let (from, _, _) = core_media::chunk_at(size, first);
        let (last_at, last_len, _) = core_media::chunk_at(size, last);
        let need = last_at + last_len as u64;
        let path = self.media_path(message_id);
        let part = path.with_extension("part");
        let file = {
            let mut waited = 0;
            loop {
                if let Ok(f) = std::fs::File::open(&path) {
                    break f;
                }
                if part.metadata().is_ok_and(|m| m.len() >= need)
                    && let Ok(f) = std::fs::File::open(&part)
                {
                    break f;
                }
                // Give the download a moment to start; then only wait while it runs.
                let downloading = self.fetching.lock().unwrap().contains(message_id);
                if waited > 3000 || (!downloading && waited > 20) {
                    return Err(CoreError::new("network"));
                }
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                waited += 1;
            }
        };
        let io = |_| CoreError::new("storage");
        let mut prefix = [0u8; core_media::PREFIX];
        file.read_exact_at(&mut prefix, 0).map_err(io)?;
        let mut ct = vec![0u8; (need - from) as usize];
        file.read_exact_at(&mut ct, from).map_err(io)?;
        let mut plain = Vec::with_capacity(((last - first + 1) * chunk) as usize);
        let mut at = 0;
        for i in first..=last {
            let (_, n, is_last) = core_media::chunk_at(size, i);
            let p = core_media::decrypt_chunk(&a.key, &prefix, i as u32, is_last, &ct[at..at + n])
                .ok_or(CoreError::new("attachment_corrupt"))?;
            plain.extend(p);
            at += n;
        }
        let skip = (offset - first * chunk) as usize;
        Ok(plain[skip..skip + (end - offset) as usize].to_vec())
    }

    /// Like `queue_text` for a file of up to 1 GB, read from `path` and encrypted into the
    /// media directory a chunk at a time. The message shows at once as sending; `retry` uploads
    /// it (resuming where it stopped) and sends it.
    pub async fn queue_attachment_file(
        &self,
        group_id: &[u8],
        path: &str,
        a: OutgoingAttachment,
        reply_to: Option<&[u8]>,
    ) -> Result<ChatMessage, CoreError> {
        let io = |_| CoreError::new("storage");
        let size = std::fs::metadata(path)
            .map_err(|_| CoreError::new("attachment_invalid"))?
            .len();
        if size as usize > MAX_ATTACHMENT {
            return Err(CoreError::new("attachment_too_large"));
        }
        if a.thumbnail.len() > MAX_THUMBNAIL || a.view_once {
            return Err(CoreError::new("attachment_invalid")); // view once: photos, in memory
        }
        self.check_can_send(group_id)?;
        std::fs::create_dir_all(&self.media_dir).map_err(io)?;
        let mut name = [0u8; 8];
        rand_core::RngCore::fill_bytes(&mut rand_core::OsRng, &mut name);
        let tmp = self.media_dir.join(format!("{}.tmp", hex(&name)));
        let src = std::io::BufReader::new(std::fs::File::open(path).map_err(io)?);
        let mut dst = std::io::BufWriter::new(std::fs::File::create(&tmp).map_err(io)?);
        let encrypted = core_media::encrypt_stream(src, size, &mut dst)
            .and_then(|k| std::io::Write::flush(&mut dst).map(|_| k));
        drop(dst);
        let (key, sha) = match encrypted {
            Ok(k) => k,
            Err(_) => {
                let _ = std::fs::remove_file(&tmp);
                return Err(CoreError::new("attachment_invalid"));
            }
        };
        let content = self.new_content(pb::content::Body::Attachment(pb::Attachment {
            key: key.to_vec(),
            sha256: sha.to_vec(),
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
            ..Default::default() // the blob ID comes with the upload
        }));
        std::fs::rename(&tmp, self.media_path(&content.message_id)).map_err(io)?;
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
        self.put(&upload_key(&msg.message_id), b"new")?;
        self.with_store(|s| storage(s.save_message(&msg)))?;
        chat_message(msg, vec![]).ok_or(CoreError::new("storage"))
    }

    fn attachment_of(&self, message_id: &[u8]) -> Result<pb::Attachment, CoreError> {
        let m = self
            .with_store(|s| storage(s.message(message_id)))?
            .filter(|m| !m.deleted)
            .ok_or(CoreError::new("not_found"))?;
        match pb::Content::decode(m.body.as_slice())
            .ok()
            .and_then(|c| c.body)
        {
            Some(pb::content::Body::Attachment(a)) => Ok(a),
            _ => Err(CoreError::new("not_found")),
        }
    }
}

/// Queued attachments, on phones and in the browser: shown at once, uploaded by `retry`.
impl SiegelCore {
    /// Like `queue_attachment_file` for one in memory (stickers, photos, voice notes, and all
    /// of the browser's): kept and shown as sending before it uploads, so a dropped upload
    /// resumes instead of losing it. View-once photos go through `send_attachment`.
    pub fn queue_attachment(
        &self,
        group_id: &[u8],
        a: OutgoingAttachment,
        reply_to: Option<&[u8]>,
    ) -> Result<ChatMessage, CoreError> {
        if a.data.len() > MAX_ATTACHMENT {
            return Err(CoreError::new("attachment_too_large"));
        }
        if a.thumbnail.len() > MAX_THUMBNAIL || a.view_once {
            return Err(CoreError::new("attachment_invalid"));
        }
        self.check_can_send(group_id)?;
        let (key, blob) = core_media::encrypt(&a.data);
        let content = self.new_content(pb::content::Body::Attachment(pb::Attachment {
            key: key.to_vec(),
            sha256: Sha256::digest(&blob).to_vec(),
            size: a.data.len() as i64,
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
            ..Default::default() // the blob ID comes with the upload
        }));
        self.media_write(&content.message_id, &blob)?;
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
        self.put(&upload_key(&msg.message_id), b"new")?;
        self.with_store(|s| storage(s.save_message(&msg)))?;
        chat_message(msg, vec![]).ok_or(CoreError::new("storage"))
    }

    /// Before a queued attachment is sent: uploads its blob, resuming a dropped upload at the
    /// part it stopped on. Nothing to do for other messages.
    pub(crate) async fn finish_upload(&self, msg: &mut Message) -> Result<(), CoreError> {
        let key = upload_key(&msg.message_id);
        // "new": no upload yet; "<path> <next part>": under way; empty or none: uploaded.
        let Some(state) = self.get(&key)?.filter(|s| !s.is_empty()) else {
            return Ok(());
        };
        let state = String::from_utf8_lossy(&state).into_owned();
        let (mut path, mut from) = match state.split_once(' ') {
            Some((p, n)) => (p.to_string(), n.parse().unwrap_or(0)),
            None => (String::new(), 0),
        };
        #[cfg(not(target_family = "wasm"))]
        let (file, len) = {
            let f = std::fs::File::open(self.media_path(&msg.message_id))
                .map_err(|_| CoreError::new("storage"))?;
            let len = f.metadata().map_err(|_| CoreError::new("storage"))?.len();
            (f, len)
        };
        #[cfg(not(target_family = "wasm"))]
        let read = |off: u64, n: usize| {
            let mut buf = vec![0u8; n];
            std::os::unix::fs::FileExt::read_exact_at(&file, &mut buf, off)
                .map_err(|_| CoreError::new("storage"))?;
            Ok(buf)
        };
        // The browser keeps the blob in the database: small enough to hold whole.
        #[cfg(target_family = "wasm")]
        let blob = self
            .media_read(&msg.message_id)
            .filter(|b| !b.is_empty())
            .ok_or(CoreError::new("storage"))?;
        #[cfg(target_family = "wasm")]
        let (len, read) = (blob.len() as u64, |off: u64, n: usize| {
            Ok(blob[off as usize..off as usize + n].to_vec())
        });
        if path.is_empty() {
            let (blob_id, p) = self.net.create_upload(&self.token()?, len, false).await?;
            let mut c =
                pb::Content::decode(msg.body.as_slice()).map_err(|_| CoreError::new("storage"))?;
            if let Some(pb::content::Body::Attachment(a)) = &mut c.body {
                a.blob_id = blob_id;
            }
            msg.body = c.encode_to_vec();
            self.with_store(|s| storage(s.update_message(msg)))?;
            (path, from) = (p, 0);
            self.put(&key, format!("{path} 0").as_bytes())?;
        }
        let saved = |next: usize| self.put(&key, format!("{path} {next}").as_bytes());
        let res = self
            .put_parts_saving(&path, len, from, &msg.message_id, read, saved)
            .await;
        self.transfers.lock().unwrap().remove(&msg.message_id);
        match res {
            Ok(()) => self.put(&key, b""),
            Err(e) => {
                if e.code == "upload_gone" {
                    self.put(&key, b"new")?; // expired: a fresh upload next time
                }
                Err(e)
            }
        }
    }

    /// Whether a queued file still has (some of) its upload to do.
    pub(crate) fn upload_pending(&self, message_id: &[u8]) -> bool {
        self.get(&upload_key(message_id))
            .ok()
            .flatten()
            .is_some_and(|s| !s.is_empty())
    }
}

fn upload_key(message_id: &[u8]) -> String {
    format!("upload/{}", hex(message_id))
}
