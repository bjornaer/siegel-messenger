//! Attachment encryption (MED-01, MED-02; CLI-01 core-media): a fresh AES-256-GCM key per file, the STREAM
//! construction over 64 KiB chunks, and padding to the next size bucket.
//!
//! Blob layout: 7-byte nonce prefix, then each chunk's ciphertext and tag, then zeros up to the
//! bucket. The plaintext size travels in the (MLS-encrypted) attachment message, which tells the
//! receiver where the chunks end.

use std::io::{self, Read, Write};

use aes_gcm::Aes256Gcm;
use aes_gcm::aead::stream::{DecryptorBE32, EncryptorBE32, NewStream, StreamBE32, StreamPrimitive};
use aes_gcm::aead::{KeyInit, generic_array::GenericArray};
use rand_core::{OsRng, RngCore};
use sha2::{Digest, Sha256};

pub const CHUNK: usize = 64 << 10;
pub const TAG: usize = 16;
pub const PREFIX: usize = 7;

/// Blobs go up and come down in parts of this size; the server uses the same (server/blobs.go).
pub const PART: usize = 8 << 20;

/// The bytes the encrypted chunks of `size` plaintext bytes take up.
fn sealed_len(size: usize) -> usize {
    PREFIX + size + size.div_ceil(CHUNK).max(1) * TAG
}

/// MED-02: the smallest bucket of at least `len` bytes; buckets grow by 5%.
pub fn padded_len(len: usize) -> usize {
    let mut b = 1;
    while b < len {
        b += (b / 20).max(1);
    }
    b
}

/// The blob's length for `size` plaintext bytes.
pub fn blob_len(size: usize) -> usize {
    padded_len(sealed_len(size))
}

fn bad(_: aes_gcm::aead::Error) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "attachment_corrupt")
}

/// Encrypts `size` bytes from `src` into `dst`, a chunk at a time, so a 1 GB video never sits in
/// memory. Returns the key and the blob's SHA-256 (MED-05).
pub fn encrypt_stream(
    mut src: impl Read,
    size: u64,
    mut dst: impl Write,
) -> io::Result<([u8; 32], [u8; 32])> {
    let mut e = Encryptor::new(size);
    let mut buf = vec![0u8; CHUNK];
    while !e.sealed() {
        let n = e.left.min(CHUNK as u64) as usize;
        src.read_exact(&mut buf[..n])?;
        dst.write_all(&e.push(&buf[..n])?)?;
    }
    loop {
        let pad = e.pad(CHUNK);
        if pad.is_empty() {
            break;
        }
        dst.write_all(&pad)?;
    }
    Ok((e.key, e.finish()))
}

/// The same blob as `encrypt_stream`, from plaintext handed over in pieces (the browser reads a
/// file a slice at a time): every piece but the last a whole number of chunks.
pub struct Encryptor {
    key: [u8; 32],
    prefix: Option<[u8; PREFIX]>,
    enc: Option<EncryptorBE32<Aes256Gcm>>,
    hash: Sha256,
    size: u64,
    left: u64,
    written: usize,
}

impl Encryptor {
    pub fn new(size: u64) -> Self {
        let mut key = [0u8; 32];
        let mut prefix = [0u8; PREFIX];
        OsRng.fill_bytes(&mut key); // CRY-16
        OsRng.fill_bytes(&mut prefix);
        let enc = EncryptorBE32::from_aead(
            Aes256Gcm::new(&key.into()),
            GenericArray::from_slice(&prefix),
        );
        Self {
            key,
            prefix: Some(prefix),
            enc: Some(enc),
            hash: Sha256::new(),
            size,
            left: size,
            written: 0,
        }
    }

    pub fn key(&self) -> [u8; 32] {
        self.key
    }

    /// All the plaintext is in.
    pub fn sealed(&self) -> bool {
        self.enc.is_none()
    }

    /// The blob's next bytes for this piece of plaintext.
    pub fn push(&mut self, plain: &[u8]) -> io::Result<Vec<u8>> {
        let n = plain.len() as u64;
        if self.sealed() || n > self.left || (n < self.left && !plain.len().is_multiple_of(CHUNK)) {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "piece"));
        }
        let mut out = Vec::with_capacity(PREFIX + plain.len() + (plain.len() / CHUNK + 1) * TAG);
        if let Some(p) = self.prefix.take() {
            out.extend(p);
        }
        let mut rest = plain;
        loop {
            let (c, tail) = rest.split_at(rest.len().min(CHUNK));
            self.left -= c.len() as u64;
            if self.left == 0 {
                let enc = self.enc.take().expect("not sealed");
                out.extend(enc.encrypt_last(c).map_err(bad)?);
                break;
            }
            if c.is_empty() {
                break; // a whole number of chunks, more to come
            }
            out.extend(
                self.enc
                    .as_mut()
                    .expect("not sealed")
                    .encrypt_next(c)
                    .map_err(bad)?,
            );
            rest = tail;
        }
        self.written += out.len();
        self.hash.update(&out);
        Ok(out)
    }

    /// Sealed and padded: the blob is all out.
    pub fn padded(&self) -> bool {
        self.sealed() && self.written == blob_len(self.size as usize)
    }

    /// Once sealed: up to `max` bytes of the padding to the size bucket; empty when it's all out.
    pub fn pad(&mut self, max: usize) -> Vec<u8> {
        if !self.sealed() {
            return vec![];
        }
        let pad = vec![0u8; (blob_len(self.size as usize) - self.written).min(max)];
        self.written += pad.len();
        self.hash.update(&pad);
        pad
    }

    /// The whole blob's SHA-256 (MED-05), once sealed and padded.
    pub fn finish(self) -> [u8; 32] {
        self.hash.finalize().into()
    }
}

/// Decrypts a blob from `src` into `dst`, a chunk at a time. An error if it was tampered with,
/// truncated, or `size` is wrong.
pub fn decrypt_stream(
    key: &[u8],
    mut src: impl Read,
    size: u64,
    mut dst: impl Write,
) -> io::Result<()> {
    let key: [u8; 32] = key
        .try_into()
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    let mut prefix = [0u8; PREFIX];
    src.read_exact(&mut prefix)?;
    let mut dec = DecryptorBE32::from_aead(
        Aes256Gcm::new(&key.into()),
        GenericArray::from_slice(&prefix),
    );
    let (mut left, mut buf) = (size, vec![0u8; CHUNK + TAG]);
    loop {
        let n = left.min(CHUNK as u64) as usize;
        src.read_exact(&mut buf[..n + TAG])?;
        left -= n as u64;
        if left == 0 {
            dst.write_all(&dec.decrypt_last(&buf[..n + TAG]).map_err(bad)?)?;
            return Ok(());
        }
        dst.write_all(&dec.decrypt_next(&buf[..n + TAG]).map_err(bad)?)?;
    }
}

/// Chunk `index` of a blob on its own (`ct`: its ciphertext and tag), for playing a video from
/// the middle without decrypting what comes before. `last` for the final chunk.
pub fn decrypt_chunk(
    key: &[u8],
    prefix: &[u8],
    index: u32,
    last: bool,
    ct: &[u8],
) -> Option<Vec<u8>> {
    let key: [u8; 32] = key.try_into().ok()?;
    let s = StreamBE32::from_aead(
        Aes256Gcm::new(&key.into()),
        GenericArray::from_slice(prefix),
    );
    s.decrypt(index, last, ct).ok()
}

/// Where chunk `index` of a blob of `size` plaintext bytes starts, its ciphertext length, and
/// whether it is the last.
pub fn chunk_at(size: u64, index: u64) -> (u64, usize, bool) {
    let chunks = size.div_ceil(CHUNK as u64).max(1);
    let last = index + 1 == chunks;
    let len = if last {
        (size - index * CHUNK as u64) as usize
    } else {
        CHUNK
    };
    (
        PREFIX as u64 + index * (CHUNK + TAG) as u64,
        len + TAG,
        last,
    )
}

/// Returns (key, blob).
pub fn encrypt(plain: &[u8]) -> ([u8; 32], Vec<u8>) {
    let mut blob = Vec::with_capacity(blob_len(plain.len()));
    let (key, _) = encrypt_stream(plain, plain.len() as u64, &mut blob).expect("in memory");
    (key, blob)
}

/// None if the blob was tampered with, truncated, or the size is wrong.
pub fn decrypt(key: &[u8], blob: &[u8], size: usize) -> Option<Vec<u8>> {
    if blob.len() < sealed_len(size) {
        return None;
    }
    let mut plain = Vec::with_capacity(size);
    decrypt_stream(key, blob, size as u64, &mut plain).ok()?;
    Some(plain)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_any_size_and_rejects_tampering() {
        for size in [0, 1, CHUNK - 1, CHUNK, CHUNK + 1, 3 * CHUNK + 5] {
            let plain: Vec<u8> = (0..size).map(|i| i as u8).collect();
            let (key, mut blob) = encrypt(&plain);
            assert_eq!(blob.len(), padded_len(sealed_len(size)), "{size}");
            assert_eq!(
                decrypt(&key, &blob, size).as_deref(),
                Some(&plain[..]),
                "{size}"
            );
            assert!(
                decrypt(&key, &blob, size + 1).is_none(),
                "wrong size {size}"
            );
            blob[PREFIX] ^= 1;
            assert!(decrypt(&key, &blob, size).is_none(), "tampered {size}");
        }
        // Buckets hide the exact size: neighbours share one, and they grow by about 5%.
        assert_eq!(padded_len(1_000_000), padded_len(1_000_001));
        let b = padded_len(10_000_000);
        assert!((10_000_000..10_500_001).contains(&b));
    }

    #[test]
    fn pieces_make_the_same_kind_of_blob() {
        for (size, piece) in [
            (0, CHUNK),
            (5, CHUNK),
            (3 * CHUNK, CHUNK),
            (5 * CHUNK + 9, 2 * CHUNK),
        ] {
            let plain: Vec<u8> = (0..size).map(|i| (i * 3) as u8).collect();
            let mut e = Encryptor::new(size as u64);
            let mut blob = vec![];
            for p in plain.chunks(piece) {
                blob.extend(e.push(p).unwrap());
            }
            if size == 0 {
                blob.extend(e.push(&[]).unwrap());
            }
            assert!(e.push(&[1]).is_err(), "sealed");
            loop {
                let pad = e.pad(1000);
                if pad.is_empty() {
                    break;
                }
                blob.extend(pad);
            }
            let key = e.key();
            assert_eq!(e.finish(), <[u8; 32]>::from(Sha256::digest(&blob)));
            assert_eq!(blob.len(), blob_len(size));
            assert_eq!(
                decrypt(&key, &blob, size).as_deref(),
                Some(&plain[..]),
                "{size}"
            );
        }
        let mut e = Encryptor::new(3 * CHUNK as u64);
        assert!(
            e.push(&[0; 100]).is_err(),
            "a piece that isn't whole chunks"
        );
    }

    #[test]
    fn streams_hash_and_open_any_chunk_alone() {
        for size in [0, 1, CHUNK, 2 * CHUNK + 7] {
            let plain: Vec<u8> = (0..size).map(|i| (i * 7) as u8).collect();
            let mut blob = vec![];
            let (key, hash) = encrypt_stream(&plain[..], size as u64, &mut blob).unwrap();
            assert_eq!(blob.len(), blob_len(size));
            assert_eq!(hash, <[u8; 32]>::from(Sha256::digest(&blob)));
            let mut back = vec![];
            decrypt_stream(&key, &blob[..], size as u64, &mut back).unwrap();
            assert_eq!(back, plain);
            let chunks = (size as u64).div_ceil(CHUNK as u64).max(1);
            let mut joined = vec![];
            for i in 0..chunks {
                let (at, len, last) = chunk_at(size as u64, i);
                let ct = &blob[at as usize..at as usize + len];
                joined.extend(decrypt_chunk(&key, &blob[..PREFIX], i as u32, last, ct).unwrap());
                assert!(decrypt_chunk(&key, &blob[..PREFIX], i as u32, !last, ct).is_none());
            }
            assert_eq!(joined, plain, "{size}");
        }
    }
}
