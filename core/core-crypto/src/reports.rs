//! CMP-03: reports are sealed on the phone to the moderators' age key (X25519), so the server only
//! ever holds ciphertext. Moderators open them with `age -d -i <key>` or the console (M7).

use std::io::Write as _;
use std::str::FromStr as _;

/// Seals `plaintext` to an `age1...` recipient. None for a malformed key.
pub fn seal(recipient: &str, plaintext: &[u8]) -> Option<Vec<u8>> {
    let r = age::x25519::Recipient::from_str(recipient).ok()?;
    let enc = age::Encryptor::with_recipients(std::iter::once(&r as &dyn age::Recipient)).ok()?;
    let mut out = Vec::new();
    let mut w = enc.wrap_output(&mut out).ok()?;
    w.write_all(plaintext).ok()?;
    w.finish().ok()?;
    Some(out)
}

#[cfg(test)]
mod tests {
    use std::io::Read as _;

    #[test]
    fn sealed_opens_only_with_the_moderators_key() {
        let id = age::x25519::Identity::generate();
        let sealed = super::seal(&id.to_public().to_string(), b"report").unwrap();
        assert!(sealed.starts_with(b"age-encryption.org/v1\n"));
        assert!(!sealed.windows(6).any(|w| w == b"report"));
        let dec = age::Decryptor::new(sealed.as_slice()).unwrap();
        let mut out = vec![];
        dec.decrypt(std::iter::once(&id as &dyn age::Identity))
            .unwrap()
            .read_to_end(&mut out)
            .unwrap();
        assert_eq!(out, b"report");
        assert!(super::seal("AGE-SECRET-KEY-1NOPE", b"x").is_none());
    }
}
