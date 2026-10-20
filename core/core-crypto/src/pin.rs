//! M8 (W3): a browser has no Keystore, so its database key is kept wrapped by the PIN chosen
//! on that browser: argon2id stretches the PIN, AES-256-GCM seals the key. A copied browser
//! profile can still be attacked offline, which is why the PIN slows each guess down and the
//! phone can unlink the browser at any time.

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use argon2::{Algorithm, Argon2, Params, Version};
use rand_core::{OsRng, RngCore};

const VERSION: u8 = 1;

fn stretch(pin: &str, salt: &[u8]) -> [u8; 32] {
    // OWASP's argon2id floor (19 MiB, 2 passes): about a second in a browser.
    let params = Params::new(19 * 1024, 2, 1, Some(32)).expect("argon2 params");
    let mut out = [0u8; 32];
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(pin.as_bytes(), salt, &mut out)
        .expect("argon2");
    out
}

/// version | salt (16) | nonce (12) | sealed key
pub fn wrap(pin: &str, key: &[u8]) -> Vec<u8> {
    let mut salt = [0u8; 16];
    let mut nonce = [0u8; 12];
    OsRng.fill_bytes(&mut salt);
    OsRng.fill_bytes(&mut nonce);
    let sealed = Aes256Gcm::new(&stretch(pin, &salt).into())
        .encrypt(Nonce::from_slice(&nonce), key)
        .expect("aes-gcm");
    [&[VERSION][..], &salt, &nonce, &sealed].concat()
}

/// The key, or None for a wrong PIN (or a damaged blob).
pub fn unwrap(pin: &str, wrapped: &[u8]) -> Option<Vec<u8>> {
    let (&[VERSION], rest) = wrapped.split_at_checked(1)? else {
        return None;
    };
    let (salt, rest) = rest.split_at_checked(16)?;
    let (nonce, sealed) = rest.split_at_checked(12)?;
    Aes256Gcm::new(&stretch(pin, salt).into())
        .decrypt(Nonce::from_slice(nonce), sealed)
        .ok()
}

#[cfg(test)]
mod tests {
    #[test]
    fn right_pin_only() {
        let w = super::wrap("4821", &[7; 32]);
        assert_eq!(super::unwrap("4821", &w), Some(vec![7; 32]));
        assert_eq!(super::unwrap("4822", &w), None);
        assert_eq!(super::unwrap("4821", &w[..20]), None);
        assert_ne!(super::wrap("4821", &[7; 32]), w, "fresh salt each time");
    }
}
