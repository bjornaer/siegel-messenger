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
    let mut key = [0u8; 32];
    let mut prefix = [0u8; PREFIX];
    OsRng.fill_bytes(&mut key); // CRY-16
    OsRng.fill_bytes(&mut prefix);
    let mut enc = EncryptorBE32::from_aead(
        Aes256Gcm::new(&key.into()),
        GenericArray::from_slice(&prefix),
    );
    let mut hash = Sha256::new();
    let mut out = |b: &[u8]| -> io::Result<()> {
        hash.update(b);
        dst.write_all(b)
    };
    out(&prefix)?;
    let mut written = PREFIX;
    let (mut left, mut buf) = (size, vec![0u8; CHUNK]);
    loop {
        let n = left.min(CHUNK as u64) as usize;
        src.read_exact(&mut buf[..n])?;
        left -= n as u64;
        if left == 0 {
            let c = enc.encrypt_last(&buf[..n]).map_err(bad)?;
            written += c.len();
            out(&c)?;
            break;
        }
        let c = enc.encrypt_next(&buf[..n]).map_err(bad)?;
        written += c.len();
        out(&c)?;
    }
    let mut pad = blob_len(size as usize) - written;
    buf.fill(0);
    while pad > 0 {
        let n = pad.min(CHUNK);
        out(&buf[..n])?;
        pad -= n;
    }
    Ok((key, hash.finalize().into()))
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
