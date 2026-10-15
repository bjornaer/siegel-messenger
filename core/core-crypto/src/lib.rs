//! Cryptography. No platform-specific code here (CLI-04).

pub mod mls;

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
