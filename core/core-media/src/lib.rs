//! Attachment encryption (MED-01, MED-02; CLI-01 core-media): a fresh AES-256-GCM key per file, the STREAM
//! construction over 64 KiB chunks, and padding to the next size bucket.
//!
//! Blob layout: 7-byte nonce prefix, then each chunk's ciphertext and tag, then zeros up to the
//! bucket. The plaintext size travels in the (MLS-encrypted) attachment message, which tells the
//! receiver where the chunks end.

use aes_gcm::Aes256Gcm;
use aes_gcm::aead::stream::{DecryptorBE32, EncryptorBE32};
use aes_gcm::aead::{KeyInit, generic_array::GenericArray};
use rand_core::{OsRng, RngCore};

const CHUNK: usize = 64 << 10;
const TAG: usize = 16;
const PREFIX: usize = 7;

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

/// Returns (key, blob).
/// ponytail: whole file in memory; stream from disk if 100 MB videos strain phones (M4 video).
pub fn encrypt(plain: &[u8]) -> ([u8; 32], Vec<u8>) {
    let mut key = [0u8; 32];
    let mut prefix = [0u8; PREFIX];
    OsRng.fill_bytes(&mut key); // CRY-16
    OsRng.fill_bytes(&mut prefix);
    let cipher = Aes256Gcm::new(&key.into());
    let mut enc = EncryptorBE32::from_aead(cipher, GenericArray::from_slice(&prefix));
    let mut blob = Vec::with_capacity(padded_len(sealed_len(plain.len())));
    blob.extend_from_slice(&prefix);
    let mut chunks = plain.chunks(CHUNK).peekable();
    let mut last: &[u8] = &[];
    while let Some(c) = chunks.next() {
        if chunks.peek().is_none() {
            last = c;
            break;
        }
        blob.extend(enc.encrypt_next(c).expect("encrypt"));
    }
    blob.extend(enc.encrypt_last(last).expect("encrypt"));
    blob.resize(padded_len(blob.len()), 0);
    (key, blob)
}

/// None if the blob was tampered with, truncated, or the size is wrong.
pub fn decrypt(key: &[u8], blob: &[u8], size: usize) -> Option<Vec<u8>> {
    let key: [u8; 32] = key.try_into().ok()?;
    let end = sealed_len(size);
    if blob.len() < end {
        return None;
    }
    let cipher = Aes256Gcm::new(&key.into());
    let mut dec = DecryptorBE32::from_aead(cipher, GenericArray::from_slice(&blob[..PREFIX]));
    let mut chunks = blob[PREFIX..end].chunks(CHUNK + TAG).peekable();
    let mut plain = Vec::with_capacity(size);
    while let Some(c) = chunks.next() {
        if chunks.peek().is_none() {
            plain.extend(dec.decrypt_last(c).ok()?);
            break;
        }
        plain.extend(dec.decrypt_next(c).ok()?);
    }
    (plain.len() == size).then_some(plain)
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
}
