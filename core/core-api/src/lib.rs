//! The only public surface of the Rust core (CLI-01). The Flutter app and the iOS
//! notification extension call this; nothing else touches keys or storage.

use std::path::Path;
use std::sync::Mutex;

use core_crypto::IdentityKey;
use core_net::{Client, pb};
use core_store::{SqlCipher, Store};

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

fn storage<T>(r: core_store::Result<T>) -> Result<T, CoreError> {
    r.map_err(|_| CoreError {
        code: "storage".into(),
    })
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

pub struct SiegelCore {
    store: Mutex<Option<Box<dyn Store>>>,
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
            store: Mutex::new(Some(Box::new(store))),
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

    fn token(&self) -> Result<String, CoreError> {
        let t = self.get(TOKEN)?.ok_or(CoreError {
            code: "not_registered".into(),
        })?;
        String::from_utf8(t).map_err(|_| CoreError {
            code: "storage".into(),
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
        let guard = self.store.lock().unwrap();
        let s = guard.as_ref().ok_or(CoreError {
            code: "wiped".into(),
        })?;
        for (k, v) in [
            (IDENTITY, &id.to_bytes()[..]),
            (ACCOUNT, &res.account_id[..]),
            (DEVICE, &res.device_id[..]),
            (TOKEN, res.device_token.as_bytes()),
        ] {
            storage(s.put(k, v))?;
        }
        Ok(res.existing_account)
    }

    pub async fn set_username(&self, username: &str) -> Result<(), CoreError> {
        Ok(self.net.set_username(&self.token()?, username).await?)
    }

    /// Exact @username lookup (ID-08). Returns the account ID.
    pub async fn lookup_username(&self, username: &str) -> Result<Vec<u8>, CoreError> {
        Ok(self
            .net
            .lookup_username(&self.token()?, username)
            .await?
            .account_id)
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
            Some(s) => storage(s.wipe()),
            None => Ok(()),
        }
    }
}
