//! Phone-number discovery, client side (DISC-05, docs/discovery.md): blind a number, unblind the
//! server's answer, and open the directory entry it points to. Mirrors server/discovery.go.

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use curve25519_dalek::ristretto::{CompressedRistretto, RistrettoPoint};
use curve25519_dalek::scalar::Scalar;
use rand_core::{OsRng, RngCore};
use sha2::{Digest, Sha256, Sha512};

const LABEL: &str = "siegel-disc-v1";

fn point(phone: &str) -> RistrettoPoint {
    let h: [u8; 64] = Sha512::digest(format!("{LABEL}:{phone}")).into();
    RistrettoPoint::from_uniform_bytes(&h)
}

/// A number hidden by a random factor, to send for evaluation; keep the factor to unblind.
pub fn blind(phone: &str) -> (Scalar, [u8; 32]) {
    let mut b = [0u8; 64];
    OsRng.fill_bytes(&mut b); // CRY-16
    let r = Scalar::from_bytes_mod_order_wide(&b);
    (r, (r * point(phone)).compress().to_bytes())
}

/// The OPRF output O for the number, from the server's answer; None if it isn't a valid point.
pub fn finalize(r: &Scalar, evaluated: &[u8]) -> Option<[u8; 32]> {
    let p = CompressedRistretto::from_slice(evaluated)
        .ok()?
        .decompress()?;
    let k_h = r.invert() * p;
    let mut h = Sha256::new();
    h.update(LABEL.as_bytes());
    h.update(k_h.compress().as_bytes());
    Some(h.finalize().into())
}

fn tagged(tag: &[u8], o: &[u8; 32]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(tag);
    h.update(o);
    h.finalize().into()
}

/// Where the number's directory entry would be.
pub fn entry_id(o: &[u8; 32]) -> [u8; 16] {
    tagged(b"id", o)[..16].try_into().expect("16 bytes")
}

/// `bits` comes from the server: more than 32 means every bucket (found by fuzzing, SEC-08).
pub fn bucket_of(id: &[u8], bits: u32) -> u32 {
    if bits == 0 || id.len() < 4 {
        return 0;
    }
    u32::from_be_bytes(id[..4].try_into().expect("4 bytes")) >> (32 - bits.min(32))
}

/// The @username in an entry, if this output opens it.
pub fn open(o: &[u8; 32], sealed: &[u8]) -> Option<String> {
    let (nonce, ct) = sealed.split_at_checked(12)?;
    let key = tagged(b"key", o);
    let plain = Aes256Gcm::new(&key.into())
        .decrypt(Nonce::from_slice(nonce), ct)
        .ok()?;
    String::from_utf8(plain).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bucket_bits_from_the_server_are_clamped() {
        let id = [0xff; 16];
        assert_eq!(bucket_of(&id, 32), u32::MAX);
        assert_eq!(bucket_of(&id, 200), u32::MAX);
        assert_eq!(bucket_of(&id, 1), 1);
    }

    /// The whole exchange with a stand-in server key: blinding hides the number, and the result
    /// matches what the server computes from the number directly.
    #[test]
    fn blind_evaluate_unblind_open() {
        let k = Scalar::from_bytes_mod_order_wide(&[3; 64]);
        let (r, blinded) = blind("+34600000001");
        let evaluated = k * CompressedRistretto(blinded).decompress().unwrap();
        let o = finalize(&r, evaluated.compress().as_bytes()).unwrap();
        let direct = {
            let mut h = Sha256::new();
            h.update(LABEL.as_bytes());
            h.update((k * point("+34600000001")).compress().as_bytes());
            <[u8; 32]>::from(h.finalize())
        };
        assert_eq!(o, direct);
        let (_, again) = blind("+34600000001");
        assert_ne!(blinded, again, "each request looks different");

        let key = tagged(b"key", &o);
        let sealed = [
            &[0u8; 12][..],
            &Aes256Gcm::new(&key.into())
                .encrypt(Nonce::from_slice(&[0; 12]), &b"bobby"[..])
                .unwrap(),
        ]
        .concat();
        assert_eq!(open(&o, &sealed).as_deref(), Some("bobby"));
        assert_eq!(open(&[9; 32], &sealed), None, "other numbers can't read it");
        assert_eq!(bucket_of(&[0xC0, 0, 0, 0], 2), 3);
    }
}
