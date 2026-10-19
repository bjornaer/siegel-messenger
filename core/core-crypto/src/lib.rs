//! Cryptography. No platform-specific code here (CLI-04).

pub mod discovery;
pub mod groups;
pub mod mls;
pub mod profile;
pub mod reports;

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use rand_core::OsRng;

/// The Account Identity Key (CRY-06). Generated from the OS CSPRNG (CRY-16); never leaves the device.
pub struct IdentityKey(SigningKey);

impl IdentityKey {
    pub fn generate() -> Self {
        Self(SigningKey::generate(&mut OsRng))
    }

    pub fn from_bytes(secret: &[u8; 32]) -> Self {
        Self(SigningKey::from_bytes(secret))
    }

    pub fn to_bytes(&self) -> [u8; 32] {
        self.0.to_bytes()
    }

    pub fn public(&self) -> [u8; 32] {
        self.0.verifying_key().to_bytes()
    }

    pub fn sign(&self, msg: &[u8]) -> [u8; 64] {
        self.0.sign(msg).to_bytes()
    }

    /// Checks a signature made with the identity key whose public half is `public`.
    pub fn verify(public: &[u8; 32], msg: &[u8], sig: &[u8]) -> bool {
        let (Ok(key), Ok(sig)) = (VerifyingKey::from_bytes(public), Signature::from_slice(sig))
        else {
            return false;
        };
        key.verify(msg, &sig).is_ok()
    }
}

/// Checks the Authentication Service binding of an account to its identity key (CRY-08):
/// Ed25519 over "siegel-as-v1" || account_id || identity_pub.
pub fn verify_as_binding(
    as_pub: &[u8; 32],
    account_id: &[u8],
    identity_pub: &[u8; 32],
    sig: &[u8],
) -> bool {
    let (Ok(key), Ok(sig)) = (VerifyingKey::from_bytes(as_pub), Signature::from_slice(sig)) else {
        return false;
    };
    let msg = [b"siegel-as-v1".as_slice(), account_id, identity_pub].concat();
    key.verify(&msg, &sig).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_roundtrip_and_as_binding() {
        let id = IdentityKey::generate();
        assert_eq!(
            IdentityKey::from_bytes(&id.to_bytes()).public(),
            id.public()
        );
        assert_ne!(IdentityKey::generate().public(), id.public());

        let as_key = IdentityKey::generate();
        let account = [7u8; 16];
        let sig = as_key.sign(&[b"siegel-as-v1".as_slice(), &account, &id.public()].concat());
        assert!(verify_as_binding(
            &as_key.public(),
            &account,
            &id.public(),
            &sig
        ));
        assert!(!verify_as_binding(
            &as_key.public(),
            &[8u8; 16],
            &id.public(),
            &sig
        ));
    }
}

/// CRY-12: 60-digit safety number for a pair of accounts, the same on both sides. Each half is
/// 30 digits from 5200 rounds of SHA-512 over the account's identity key and ID (the
/// construction Signal uses); the halves are sorted so the order doesn't depend on who looks.
pub fn safety_number(a: (&[u8; 16], &[u8; 32]), b: (&[u8; 16], &[u8; 32])) -> String {
    use sha2::{Digest, Sha512};
    let half = |(account, key): (&[u8; 16], &[u8; 32])| {
        let mut h = Sha512::new()
            .chain_update(0u16.to_be_bytes())
            .chain_update(key)
            .chain_update(account)
            .finalize();
        for _ in 1..5200 {
            h = Sha512::new().chain_update(h).chain_update(key).finalize();
        }
        h[..30]
            .chunks(5)
            .map(|c| {
                let n = c.iter().fold(0u64, |n, b| n << 8 | *b as u64);
                format!("{:05}", n % 100_000)
            })
            .collect::<String>()
    };
    let (x, y) = (half(a), half(b));
    if x <= y { x + &y } else { y + &x }
}

#[cfg(test)]
mod safety_number_tests {
    #[test]
    fn symmetric_sixty_digits_and_key_bound() {
        let (a, b) = (([1; 16], [2; 32]), ([3; 16], [4; 32]));
        let n = super::safety_number((&a.0, &a.1), (&b.0, &b.1));
        assert_eq!(n.len(), 60);
        assert!(n.bytes().all(|c| c.is_ascii_digit()));
        assert_eq!(n, super::safety_number((&b.0, &b.1), (&a.0, &a.1)));
        assert_ne!(n, super::safety_number((&a.0, &a.1), (&b.0, &[5; 32])));
    }
}
