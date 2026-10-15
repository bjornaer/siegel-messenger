//! The only public surface of the Rust core (CLI-01). The Flutter app and the iOS
//! notification extension call this; nothing else touches keys or storage.

use std::path::Path;
use std::sync::Mutex;

use core_crypto::IdentityKey;
use core_net::{Client, pb};
use core_store::{SqlCipher, Store};

mod chat;
pub use chat::{ChatMessage, Event};
pub use core_store::Conversation;

/// Machine-readable failure, e.g. "otp_invalid", "registration_lock_required", "network".
#[derive(Debug, Clone, PartialEq)]
pub struct CoreError {
    pub code: String,
}

impl From<core_net::Error> for CoreError {
    fn from(e: core_net::Error) -> Self {
        Self { code: e.code }
    }
}

impl CoreError {
    fn new(code: &str) -> Self {
        Self { code: code.into() }
    }
}

fn storage<T>(r: core_store::Result<T>) -> Result<T, CoreError> {
    r.map_err(|_| CoreError::new("storage"))
}

#[derive(Clone, Copy)]
pub enum Platform {
    Ios,
    Android,
}

const IDENTITY: &str = "identity_secret";
const ACCOUNT: &str = "account_id";
const DEVICE: &str = "device_id";
const TOKEN: &str = "device_token";
const USERNAME: &str = "username";
const DISPLAY_NAME: &str = "display_name";
const AS_PUBLIC: &str = "as_public_key";
const SIGNER: &str = "mls_signer_public";
const CREDENTIAL: &str = "mls_credential";

pub struct SiegelCore {
    store: Mutex<Option<SqlCipher>>,
    net: Client,
}

impl SiegelCore {
    /// `db_key`: 32 bytes the app keeps in the Keychain/Keystore (CRY-15).
    pub fn open(db_path: &str, db_key: &[u8], server_url: &str) -> Result<Self, CoreError> {
        let key: &[u8; 32] = db_key.try_into().map_err(|_| CoreError {
            code: "db_key_invalid".into(),
        })?;
        let store = storage(SqlCipher::open(Path::new(db_path), key))?;
        Ok(Self {
            store: Mutex::new(Some(store)),
            net: Client::new(server_url),
        })
    }

    fn get(&self, key: &str) -> Result<Option<Vec<u8>>, CoreError> {
        match self.store.lock().unwrap().as_ref() {
            Some(s) => storage(s.get(key)),
            None => Err(CoreError {
                code: "wiped".into(),
            }),
        }
    }

    fn put(&self, key: &str, value: &[u8]) -> Result<(), CoreError> {
        match self.store.lock().unwrap().as_ref() {
            Some(s) => storage(s.put(key, value)),
            None => Err(CoreError {
                code: "wiped".into(),
            }),
        }
    }

    fn get_string(&self, key: &str) -> Option<String> {
        self.get(key)
            .ok()
            .flatten()
            .and_then(|v| String::from_utf8(v).ok())
    }

    fn token(&self) -> Result<String, CoreError> {
        self.get_string(TOKEN).ok_or(CoreError {
            code: "not_registered".into(),
        })
    }

    pub fn is_registered(&self) -> bool {
        matches!(self.get(TOKEN), Ok(Some(_)))
    }

    pub async fn request_otp(
        &self,
        phone_e164: &str,
        attestation_token: &str,
    ) -> Result<(), CoreError> {
        Ok(self.net.request_otp(phone_e164, attestation_token).await?)
    }

    /// Verifies the OTP (and Registration Lock PIN if the account has one). Every registration
    /// creates a fresh Account Identity Key (CRY-06, ID-09). Returns true for an existing account.
    pub async fn verify(
        &self,
        phone_e164: &str,
        otp: &str,
        pin: &str,
        platform: Platform,
    ) -> Result<bool, CoreError> {
        let id = IdentityKey::generate();
        let res = self
            .net
            .verify(pb::VerifyRequest {
                phone_e164: phone_e164.into(),
                otp: otp.into(),
                identity_pub: id.public().to_vec(),
                registration_lock_pin: pin.into(),
                platform: match platform {
                    Platform::Ios => pb::Platform::Ios,
                    Platform::Android => pb::Platform::Android,
                } as i32,
            })
            .await?;
        let account: [u8; 16] = res
            .account_id
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::new("bad_response"))?;
        let device: [u8; 16] = res
            .device_id
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::new("bad_response"))?;
        let as_sig: [u8; 64] = res
            .as_signature
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::new("bad_response"))?;
        let as_pub: [u8; 32] = res
            .as_public_key
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::new("bad_response"))?;
        // CRY-08: the binding we just got must verify under the AS key we now pin.
        if !core_crypto::verify_as_binding(&as_pub, &account, &id.public(), &as_sig) {
            return Err(CoreError::new("as_signature_invalid"));
        }
        {
            let guard = self.store.lock().unwrap();
            let s = guard.as_ref().ok_or(CoreError::new("wiped"))?;
            let signer = chat::new_signer(s)?; // CRY-07: this device's MLS signing key
            let credential = core_crypto::mls::DeviceCredential::issue(
                &id,
                account,
                device,
                signer.public(),
                as_sig,
            );
            for (k, v) in [
                (IDENTITY, &id.to_bytes()[..]),
                (ACCOUNT, &account[..]),
                (DEVICE, &device[..]),
                (TOKEN, res.device_token.as_bytes()),
                (AS_PUBLIC, &as_pub[..]),
                (SIGNER, signer.public()),
                (CREDENTIAL, &credential.encode()),
            ] {
                storage(s.put(k, v))?;
            }
        }
        // A failed upload is retried when the stream connects (refill below 20, CRY-09).
        let _ = self.ensure_key_packages().await;
        Ok(res.existing_account)
    }

    pub async fn set_username(&self, username: &str) -> Result<(), CoreError> {
        self.net.set_username(&self.token()?, username).await?;
        self.put(USERNAME, username.to_lowercase().as_bytes())
    }

    pub fn username(&self) -> Option<String> {
        self.get_string(USERNAME)
    }

    /// 1 to 64 characters. Stays on this device until encrypted profiles ship (M2).
    pub fn set_display_name(&self, name: &str) -> Result<(), CoreError> {
        let name = name.trim();
        if !(1..=64).contains(&name.chars().count()) {
            return Err(CoreError {
                code: "display_name_invalid".into(),
            });
        }
        self.put(DISPLAY_NAME, name.as_bytes())
    }

    pub fn display_name(&self) -> Option<String> {
        self.get_string(DISPLAY_NAME)
    }

    /// Exact @username lookup (ID-08). Returns the account ID.
    pub async fn lookup_username(&self, username: &str) -> Result<Vec<u8>, CoreError> {
        Ok(self
            .net
            .lookup_username(&self.token()?, username)
            .await?
            .account_id)
    }

    /// Local UI preferences (app lock, screen security...), kept in the encrypted DB.
    pub fn setting(&self, key: &str) -> Option<String> {
        self.get_string(&format!("setting.{key}"))
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<(), CoreError> {
        self.put(&format!("setting.{key}"), value.as_bytes())
    }

    /// 4-digit PIN, or empty to remove the lock (ID-10).
    pub async fn set_registration_lock(&self, pin: &str) -> Result<(), CoreError> {
        Ok(self.net.set_registration_lock(&self.token()?, pin).await?)
    }

    /// Deletes the account on the server (ID-16), then everything on this device.
    pub async fn delete_account(&self) -> Result<(), CoreError> {
        self.net.delete_account(&self.token()?).await?;
        self.wipe()
    }

    /// Erases keys and the local database (ID-12). This instance is unusable afterwards.
    pub fn wipe(&self) -> Result<(), CoreError> {
        match self.store.lock().unwrap().take() {
            Some(s) => storage(Box::new(s).wipe()),
            None => Ok(()),
        }
    }
}
