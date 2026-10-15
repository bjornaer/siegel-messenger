//! Flutter binding over core-api (CLI-02). Thin by design: no logic lives here.

use flutter_rust_bridge::frb;

use crate::frb_generated::StreamSink;

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
        Ok(Core(core_api::SiegelCore::open(
            &db_path,
            &db_key,
            &server_url,
        )?))
    }

    #[frb(sync)]
    pub fn is_registered(&self) -> bool {
        self.0.is_registered()
    }

    pub async fn request_otp(
        &self,
        phone_e164: String,
        attestation_token: String,
    ) -> Result<(), CoreError> {
        Ok(self.0.request_otp(&phone_e164, &attestation_token).await?)
    }

    /// Returns true when the number already had an account (re-registration).
    pub async fn verify(
        &self,
        phone_e164: String,
        otp: String,
        pin: String,
        platform: DevicePlatform,
    ) -> Result<bool, CoreError> {
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

/// A conversation for the chat list.
pub struct ChatSummary {
    pub group_id: Vec<u8>,
    pub peer_account: Vec<u8>,
    /// Known when we started the chat; otherwise null until profiles land.
    pub peer_username: Option<String>,
    pub last: Option<MessageView>,
}

pub struct MessageView {
    pub group_id: Vec<u8>,
    pub message_id: Vec<u8>,
    pub sender_account: Vec<u8>,
    /// Sender clock, ms since the Unix epoch.
    pub sent_at: i64,
    pub text: String,
    pub outgoing: bool,
}

impl From<core_api::ChatMessage> for MessageView {
    fn from(m: core_api::ChatMessage) -> Self {
        Self {
            group_id: m.group_id,
            message_id: m.message_id,
            sender_account: m.sender_account,
            sent_at: m.sent_at,
            text: m.text,
            outgoing: m.outgoing,
        }
    }
}

pub enum CoreEventKind {
    ConversationStarted,
    Message,
    /// Local data is already wiped (ID-12): return to onboarding.
    Deregistered,
}

/// Flat on purpose: data-carrying enums would need an extra Dart codegen (freezed).
pub struct CoreEvent {
    pub kind: CoreEventKind,
    pub group_id: Option<Vec<u8>>,
    pub message: Option<MessageView>,
}

impl Core {
    /// Starts (or reopens) a 1:1 chat with @username; returns its ID.
    pub async fn start_chat(&self, username: String) -> Result<Vec<u8>, CoreError> {
        Ok(self.0.start_chat(&username).await?)
    }

    #[frb(sync)]
    pub fn chats(&self) -> Result<Vec<ChatSummary>, CoreError> {
        let mut out = Vec::new();
        for c in self.0.conversations()? {
            let last = self
                .0
                .messages(&c.group_id, 1)?
                .pop()
                .map(MessageView::from);
            out.push(ChatSummary {
                peer_username: self.0.peer_username(&c.peer_account),
                group_id: c.group_id,
                peer_account: c.peer_account,
                last,
            });
        }
        out.sort_by_key(|c| std::cmp::Reverse(c.last.as_ref().map_or(0, |m| m.sent_at)));
        Ok(out)
    }

    #[frb(sync)]
    pub fn messages(&self, group_id: Vec<u8>, limit: u32) -> Result<Vec<MessageView>, CoreError> {
        Ok(self
            .0
            .messages(&group_id, limit)?
            .into_iter()
            .map(MessageView::from)
            .collect())
    }

    pub async fn send_text(
        &self,
        group_id: Vec<u8>,
        text: String,
    ) -> Result<MessageView, CoreError> {
        Ok(self.0.send_text(&group_id, &text).await?.into())
    }

    /// Streams events until the connection closes; the caller reconnects with backoff.
    pub async fn run_stream(&self, sink: StreamSink<CoreEvent>) -> Result<(), CoreError> {
        Ok(self
            .0
            .run_stream(move |e| {
                let (kind, group_id, message) = match e {
                    core_api::Event::ConversationStarted { group_id, .. } => {
                        (CoreEventKind::ConversationStarted, Some(group_id), None)
                    }
                    core_api::Event::Message(m) => (
                        CoreEventKind::Message,
                        Some(m.group_id.clone()),
                        Some(m.into()),
                    ),
                    core_api::Event::Deregistered => (CoreEventKind::Deregistered, None, None),
                };
                let _ = sink.add(CoreEvent {
                    kind,
                    group_id,
                    message,
                });
            })
            .await?)
    }
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
