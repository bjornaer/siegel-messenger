//! Profile key (MSG-10, TRUST-01): encrypts the user's profile and derives the delivery token
//! that lets contacts send sealed. Shared only with contacts, inside MLS.

use aes_gcm::aead::{Aead, AeadCore, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use hkdf::Hkdf;
use rand_core::{OsRng, RngCore};
use sha2::{Digest, Sha256};

#[derive(Clone, Debug, PartialEq)]
pub struct ProfileKey(pub [u8; 32]);

impl ProfileKey {
    pub fn generate() -> Self {
        let mut k = [0u8; 32];
        OsRng.fill_bytes(&mut k); // CRY-16
        Self(k)
    }

    fn derive(&self, info: &[u8]) -> [u8; 32] {
        let mut out = [0u8; 32];
        Hkdf::<Sha256>::new(None, &self.0)
            .expand(info, &mut out)
            .expect("32 bytes");
        out
    }

    /// Proves to the server that the sender holds this profile key (MSG-10).
    pub fn delivery_token(&self) -> [u8; 32] {
        self.derive(b"siegel-delivery-token-v1")
    }

    /// What the server stores to check delivery tokens without learning them.
    pub fn verifier(&self) -> [u8; 32] {
        Sha256::digest(self.delivery_token()).into()
    }

    /// AES-256-GCM, random nonce prepended.
    pub fn encrypt(&self, plaintext: &[u8]) -> Vec<u8> {
        let cipher = Aes256Gcm::new(&self.derive(b"siegel-profile-v1").into());
        let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
        let ct = cipher.encrypt(&nonce, plaintext).expect("encrypt");
        [nonce.as_slice(), &ct].concat()
    }

    pub fn decrypt(&self, data: &[u8]) -> Option<Vec<u8>> {
        if data.len() < 12 {
            return None;
        }
        let cipher = Aes256Gcm::new(&self.derive(b"siegel-profile-v1").into());
        cipher
            .decrypt(Nonce::from_slice(&data[..12]), &data[12..])
            .ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_roundtrip_and_tokens() {
        let k = ProfileKey::generate();
        let ct = k.encrypt(b"Ana");
        assert_eq!(k.decrypt(&ct).as_deref(), Some(&b"Ana"[..]));
        assert_eq!(ProfileKey::generate().decrypt(&ct), None, "other key");
        assert_ne!(k.encrypt(b"Ana"), ct, "fresh nonce");
        assert_ne!(
            k.delivery_token(),
            k.derive(b"siegel-profile-v1"),
            "separate keys"
        );
        assert_eq!(
            k.verifier(),
            <[u8; 32]>::from(Sha256::digest(k.delivery_token()))
        );
        assert_ne!(ProfileKey::generate().delivery_token(), k.delivery_token());
    }
}
