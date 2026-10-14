//! Flutter binding over core-api (CLI-02). Thin by design: no logic lives here.

use flutter_rust_bridge::frb;

/// Thrown in Dart with a stable machine code ("otp_invalid", "network", ...).
pub struct CoreError {
    pub code: String,
}

impl From<core_api::CoreError> for CoreError {
    fn from(e: core_api::CoreError) -> Self {
        Self { code: e.code }
    }
}

pub enum DevicePlatform {
    Ios,
    Android,
}

#[frb(opaque)]
pub struct Core(core_api::SiegelCore);

impl Core {
    #[frb(sync)]
    pub fn open(db_path: String, db_key: Vec<u8>, server_url: String) -> Result<Core, CoreError> {
        Ok(Core(core_api::SiegelCore::open(&db_path, &db_key, &server_url)?))
    }

    #[frb(sync)]
    pub fn is_registered(&self) -> bool {
        self.0.is_registered()
    }

    pub async fn request_otp(&self, phone_e164: String, attestation_token: String) -> Result<(), CoreError> {
        Ok(self.0.request_otp(&phone_e164, &attestation_token).await?)
    }

    /// Returns true when the number already had an account (re-registration).
    pub async fn verify(&self, phone_e164: String, otp: String, pin: String, platform: DevicePlatform) -> Result<bool, CoreError> {
        let p = match platform {
            DevicePlatform::Ios => core_api::Platform::Ios,
            DevicePlatform::Android => core_api::Platform::Android,
        };
        Ok(self.0.verify(&phone_e164, &otp, &pin, p).await?)
    }

    pub async fn set_username(&self, username: String) -> Result<(), CoreError> {
        Ok(self.0.set_username(&username).await?)
    }

    #[frb(sync)]
    pub fn username(&self) -> Option<String> {
        self.0.username()
    }

    #[frb(sync)]
    pub fn set_display_name(&self, name: String) -> Result<(), CoreError> {
        Ok(self.0.set_display_name(&name)?)
    }

    #[frb(sync)]
    pub fn display_name(&self) -> Option<String> {
        self.0.display_name()
    }

    #[frb(sync)]
    pub fn setting(&self, key: String) -> Option<String> {
        self.0.setting(&key)
    }

    #[frb(sync)]
    pub fn set_setting(&self, key: String, value: String) -> Result<(), CoreError> {
        Ok(self.0.set_setting(&key, &value)?)
    }

    pub async fn set_registration_lock(&self, pin: String) -> Result<(), CoreError> {
        Ok(self.0.set_registration_lock(&pin).await?)
    }

    pub async fn delete_account(&self) -> Result<(), CoreError> {
        Ok(self.0.delete_account().await?)
    }
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
