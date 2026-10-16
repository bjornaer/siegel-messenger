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

pub struct AppVersion {
    pub latest: u32,
    pub minimum: u32,
}

pub enum DevicePlatform {
    Ios,
    Android,
}

impl From<DevicePlatform> for core_api::Platform {
    fn from(p: DevicePlatform) -> Self {
        match p {
            DevicePlatform::Ios => Self::Ios,
            DevicePlatform::Android => Self::Android,
        }
    }
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

    /// Returns the seconds until "Resend code" may be used (ID-04).
    pub async fn request_otp(
        &self,
        phone_e164: String,
        attestation_token: String,
        platform: DevicePlatform,
    ) -> Result<u32, CoreError> {
        Ok(self
            .0
            .request_otp(&phone_e164, &attestation_token, platform.into())
            .await?)
    }

    /// Returns true when the number already had an account (re-registration).
    pub async fn verify(
        &self,
        phone_e164: String,
        otp: String,
        pin: String,
        platform: DevicePlatform,
    ) -> Result<bool, CoreError> {
        Ok(self
            .0
            .verify(&phone_e164, &otp, &pin, platform.into())
            .await?)
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

    /// Newest published build and the oldest allowed, for the update prompt.
    pub async fn app_version(&self, platform: DevicePlatform) -> Result<AppVersion, CoreError> {
        let (latest, minimum) = self.0.app_version(platform.into()).await?;
        Ok(AppVersion { latest, minimum })
    }

    /// The account already has a Registration Lock PIN (ID-10).
    #[frb(sync)]
    pub fn has_registration_lock(&self) -> bool {
        self.0.has_registration_lock()
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
    /// From their encrypted profile once they shared their profile key.
    pub peer_display_name: Option<String>,
    pub peer_username: Option<String>,
    /// An unaccepted message request (MSG-15).
    pub request: bool,
    /// Safety number checked in person (CRY-12).
    pub peer_verified: bool,
    pub last: Option<MessageView>,
    /// Group chats (M3): no peer; `group_name` is the title.
    pub is_group: bool,
    pub group_name: Option<String>,
    /// We left or were removed: read-only.
    pub left: bool,
}

/// A group's members, roles and settings (section 8).
pub struct GroupInfoView {
    pub name: String,
    pub members: Vec<GroupMemberView>,
    pub admins_only_info: bool,
    pub admins_only_add: bool,
    pub me_admin: bool,
}

pub struct GroupMemberView {
    pub account: Vec<u8>,
    pub display_name: Option<String>,
    pub username: Option<String>,
    pub admin: bool,
    pub me: bool,
}

/// GRP-12 system lines.
pub enum GroupEventKind {
    Created,
    Added,
    Removed,
    Left,
    Renamed,
    AdminAdded,
    AdminRemoved,
    Settings,
}

pub struct GroupEventView {
    pub kind: GroupEventKind,
    pub actor: Vec<u8>,
    pub targets: Vec<Vec<u8>>,
    pub name: String,
}

/// GRP-13: one member's state for one of our messages.
pub struct ReceiptView {
    pub account: Vec<u8>,
    pub status: MessageStatus,
}

fn status_view(s: core_api::Status) -> MessageStatus {
    use core_api::Status;
    match s {
        Status::Failed => MessageStatus::Failed,
        Status::Sending => MessageStatus::Sending,
        Status::Sent => MessageStatus::Sent,
        Status::Delivered => MessageStatus::Delivered,
        Status::Read => MessageStatus::Read,
    }
}

pub struct MessageView {
    pub group_id: Vec<u8>,
    pub message_id: Vec<u8>,
    pub sender_account: Vec<u8>,
    /// Sender clock, ms since the Unix epoch.
    pub sent_at: i64,
    /// Empty once deleted for everyone.
    pub text: String,
    pub outgoing: bool,
    /// MSG-07: the quoted message's ID.
    pub reply_to: Option<Vec<u8>>,
    pub status: MessageStatus,
    pub edited: bool,
    pub deleted: bool,
    pub reactions: Vec<Reaction>,
    /// CRY-13: a notice that the peer's safety number changed, not a message.
    pub key_change: bool,
    /// GRP-12: a system line, not a message.
    pub event: Option<GroupEventView>,
}

/// MSG-04. Incoming messages are Delivered until read.
pub enum MessageStatus {
    Failed,
    Sending,
    Sent,
    Delivered,
    Read,
}

pub struct Reaction {
    pub account: Vec<u8>,
    pub emoji: String,
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
            reply_to: m.reply_to,
            status: status_view(m.status),
            edited: m.edited,
            deleted: m.deleted,
            reactions: m
                .reactions
                .into_iter()
                .map(|(account, emoji)| Reaction { account, emoji })
                .collect(),
            key_change: m.key_change,
            event: m.event.map(|e| {
                use core_api::GroupEventKind as K;
                GroupEventView {
                    kind: match e.kind {
                        K::Created => GroupEventKind::Created,
                        K::Added => GroupEventKind::Added,
                        K::Removed => GroupEventKind::Removed,
                        K::Left => GroupEventKind::Left,
                        K::Renamed => GroupEventKind::Renamed,
                        K::AdminAdded => GroupEventKind::AdminAdded,
                        K::AdminRemoved => GroupEventKind::AdminRemoved,
                        K::Settings => GroupEventKind::Settings,
                    },
                    actor: e.actor,
                    targets: e.targets,
                    name: e.name,
                }
            }),
        }
    }
}

pub struct BlockedContact {
    pub account: Vec<u8>,
    pub display_name: Option<String>,
    pub username: Option<String>,
}

pub enum CoreEventKind {
    ConversationStarted,
    Message,
    ProfileUpdated,
    /// A reaction, edit, delete or receipt changed a message in `group_id`.
    Updated,
    /// The peer in `group_id` is typing (MSG-14).
    Typing,
    /// Local data is already wiped (ID-12): return to onboarding.
    Deregistered,
}

/// Flat on purpose: data-carrying enums would need an extra Dart codegen (freezed).
pub struct CoreEvent {
    pub kind: CoreEventKind,
    pub group_id: Option<Vec<u8>>,
    pub message: Option<MessageView>,
    /// Typing: who is typing (groups show the name).
    pub account: Option<Vec<u8>>,
}

impl Core {
    /// Starts (or reopens) a 1:1 chat with @username; returns its ID.
    pub async fn start_chat(&self, username: String) -> Result<Vec<u8>, CoreError> {
        Ok(self.0.start_chat(&username).await?)
    }

    /// All chats except blocked ones, newest first.
    #[frb(sync)]
    pub fn chats(&self) -> Result<Vec<ChatSummary>, CoreError> {
        let mut out = Vec::new();
        for c in self.0.conversations()? {
            let last = self
                .0
                .messages(&c.group_id, 1)?
                .pop()
                .map(MessageView::from);
            if c.is_group {
                out.push(ChatSummary {
                    group_name: self.0.group_info(&c.group_id).ok().map(|g| g.name),
                    peer_display_name: None,
                    peer_username: None,
                    request: c.invite,
                    peer_verified: false,
                    is_group: true,
                    left: c.left,
                    group_id: c.group_id,
                    peer_account: c.peer_account,
                    last,
                });
                continue;
            }
            let contact = self.0.contact(&c.peer_account);
            if matches!(&contact, Some(k) if k.state == core_api::ContactState::Blocked) {
                continue;
            }
            out.push(ChatSummary {
                peer_display_name: contact.as_ref().and_then(|k| k.display_name.clone()),
                peer_username: contact.as_ref().and_then(|k| k.username.clone()),
                request: contact
                    .as_ref()
                    .is_none_or(|k| k.state != core_api::ContactState::Accepted),
                peer_verified: contact.is_some_and(|k| k.verified),
                is_group: false,
                group_name: None,
                left: false,
                group_id: c.group_id,
                peer_account: c.peer_account,
                last,
            });
        }
        out.sort_by_key(|c| std::cmp::Reverse(c.last.as_ref().map_or(0, |m| m.sent_at)));
        Ok(out)
    }

    /// GRP-01: a new group with these @usernames; returns its chat ID.
    pub async fn create_group(
        &self,
        name: String,
        usernames: Vec<String>,
    ) -> Result<Vec<u8>, CoreError> {
        Ok(self.0.create_group(&name, &usernames).await?)
    }

    #[frb(sync)]
    pub fn group_info(&self, group_id: Vec<u8>) -> Result<GroupInfoView, CoreError> {
        let g = self.0.group_info(&group_id)?;
        Ok(GroupInfoView {
            name: g.name,
            admins_only_info: g.admins_only_info,
            admins_only_add: g.admins_only_add,
            me_admin: g.me_admin,
            members: g
                .members
                .into_iter()
                .map(|m| GroupMemberView {
                    account: m.account,
                    display_name: m.display_name,
                    username: m.username,
                    admin: m.admin,
                    me: m.me,
                })
                .collect(),
        })
    }

    pub async fn add_members(
        &self,
        group_id: Vec<u8>,
        usernames: Vec<String>,
    ) -> Result<(), CoreError> {
        Ok(self.0.add_members(&group_id, &usernames).await?)
    }

    pub async fn remove_member(
        &self,
        group_id: Vec<u8>,
        account: Vec<u8>,
    ) -> Result<(), CoreError> {
        Ok(self.0.remove_member(&group_id, &account).await?)
    }

    pub async fn set_admin(
        &self,
        group_id: Vec<u8>,
        account: Vec<u8>,
        admin: bool,
    ) -> Result<(), CoreError> {
        Ok(self.0.set_admin(&group_id, &account, admin).await?)
    }

    pub async fn rename_group(&self, group_id: Vec<u8>, name: String) -> Result<(), CoreError> {
        Ok(self.0.rename_group(&group_id, &name).await?)
    }

    pub async fn set_group_settings(
        &self,
        group_id: Vec<u8>,
        admins_only_info: bool,
        admins_only_add: bool,
    ) -> Result<(), CoreError> {
        Ok(self
            .0
            .set_group_settings(&group_id, admins_only_info, admins_only_add)
            .await?)
    }

    /// GRP-10: leave; the chat stays, read-only.
    pub async fn leave_group(&self, group_id: Vec<u8>) -> Result<(), CoreError> {
        Ok(self.0.leave_group(&group_id).await?)
    }

    /// GRP-13: per-member delivered/read state of one of our messages.
    #[frb(sync)]
    pub fn message_receipts(&self, message_id: Vec<u8>) -> Result<Vec<ReceiptView>, CoreError> {
        Ok(self
            .0
            .message_receipts(&message_id)?
            .into_iter()
            .map(|(account, s)| ReceiptView {
                account,
                status: status_view(s),
            })
            .collect())
    }

    /// A member's name for group bubbles and system lines: display name, else @username.
    #[frb(sync)]
    pub fn member_name(&self, account: Vec<u8>) -> Option<String> {
        let c = self.0.contact(&account)?;
        c.display_name.or(c.username.map(|u| format!("@{u}")))
    }

    /// Accepts a message request: they get our profile key and we can reply (MSG-15).
    pub async fn accept(&self, group_id: Vec<u8>) -> Result<(), CoreError> {
        Ok(self.0.accept(&group_id).await?)
    }

    /// Deletes a chat from this device.
    #[frb(sync)]
    pub fn delete_chat(&self, group_id: Vec<u8>) -> Result<(), CoreError> {
        Ok(self.0.delete_chat(&group_id)?)
    }

    /// Blocked accounts for Settings (MSG-16).
    #[frb(sync)]
    pub fn blocked(&self) -> Result<Vec<BlockedContact>, CoreError> {
        Ok(self
            .0
            .blocked()?
            .into_iter()
            .map(|c| BlockedContact {
                account: c.account_id,
                display_name: c.display_name,
                username: c.username,
            })
            .collect())
    }

    /// They become a contact again and get our profile key.
    pub async fn unblock(&self, account: Vec<u8>) -> Result<(), CoreError> {
        Ok(self.0.unblock(&account).await?)
    }

    /// Blocks the account; they are not told (MSG-16).
    pub async fn block(&self, account: Vec<u8>) -> Result<(), CoreError> {
        Ok(self.0.block(&account).await?)
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

    /// Sends a text, optionally as a reply (MSG-07). On failure the message stays Failed.
    pub async fn send_text(
        &self,
        group_id: Vec<u8>,
        text: String,
        reply_to: Option<Vec<u8>>,
    ) -> Result<MessageView, CoreError> {
        Ok(self
            .0
            .send_text(&group_id, &text, reply_to.as_deref())
            .await?
            .into())
    }

    pub async fn retry(&self, message_id: Vec<u8>) -> Result<(), CoreError> {
        Ok(self.0.retry(&message_id).await?)
    }

    /// MSG-08: empty removes our reaction.
    pub async fn react(
        &self,
        group_id: Vec<u8>,
        message_id: Vec<u8>,
        emoji: String,
    ) -> Result<(), CoreError> {
        Ok(self.0.react(&group_id, &message_id, &emoji).await?)
    }

    pub async fn edit(
        &self,
        group_id: Vec<u8>,
        message_id: Vec<u8>,
        text: String,
    ) -> Result<(), CoreError> {
        Ok(self.0.edit(&group_id, &message_id, &text).await?)
    }

    pub async fn delete_for_everyone(
        &self,
        group_id: Vec<u8>,
        message_id: Vec<u8>,
    ) -> Result<(), CoreError> {
        Ok(self.0.delete_for_everyone(&group_id, &message_id).await?)
    }

    #[frb(sync)]
    pub fn delete_for_me(&self, message_id: Vec<u8>) -> Result<(), CoreError> {
        Ok(self.0.delete_for_me(&message_id)?)
    }

    /// Earlier texts of an edited message, oldest first (MSG-09).
    #[frb(sync)]
    pub fn versions(&self, message_id: Vec<u8>) -> Result<Vec<String>, CoreError> {
        Ok(self.0.versions(&message_id)?)
    }

    pub async fn mark_read(&self, group_id: Vec<u8>) -> Result<(), CoreError> {
        Ok(self.0.mark_read(&group_id).await?)
    }

    /// The chat's 60-digit safety number, also encoded in its QR code (CRY-12).
    #[frb(sync)]
    pub fn safety_number(&self, group_id: Vec<u8>) -> Result<Option<String>, CoreError> {
        Ok(self.0.safety_number(&group_id)?)
    }

    /// A scanned code that matches marks the contact verified; false on mismatch.
    #[frb(sync)]
    pub fn verify_safety_number(
        &self,
        group_id: Vec<u8>,
        scanned: String,
    ) -> Result<bool, CoreError> {
        Ok(self.0.verify_safety_number(&group_id, &scanned)?)
    }

    /// Call at most every 3 seconds while typing (MSG-14).
    pub async fn send_typing(&self, group_id: Vec<u8>) -> Result<(), CoreError> {
        Ok(self.0.send_typing(&group_id).await?)
    }

    /// Streams events until the connection closes; the caller reconnects with backoff.
    pub async fn run_stream(&self, sink: StreamSink<CoreEvent>) -> Result<(), CoreError> {
        Ok(self.0.run_stream(move |e| send_event(&sink, e)).await?)
    }

    /// After a push wake-up: streams what was queued, then ends (MSG-17).
    pub async fn drain(&self, sink: StreamSink<CoreEvent>) -> Result<(), CoreError> {
        Ok(self.0.drain(move |e| send_event(&sink, e)).await?)
    }

    /// This device's FCM token, for content-free wake-ups (MSG-17).
    pub async fn set_push_token(&self, push_token: String) -> Result<(), CoreError> {
        Ok(self.0.set_push_token(&push_token).await?)
    }
}

fn send_event(sink: &StreamSink<CoreEvent>, e: core_api::Event) {
    let mut account = None;
    let (kind, group_id, message) = match e {
        core_api::Event::ConversationStarted { group_id, .. } => {
            (CoreEventKind::ConversationStarted, Some(group_id), None)
        }
        core_api::Event::Message(m) => (
            CoreEventKind::Message,
            Some(m.group_id.clone()),
            Some(m.into()),
        ),
        core_api::Event::Updated { group_id } => (CoreEventKind::Updated, Some(group_id), None),
        core_api::Event::Typing {
            group_id,
            account: who,
        } => {
            account = Some(who);
            (CoreEventKind::Typing, Some(group_id), None)
        }
        core_api::Event::ProfileUpdated { .. } => (CoreEventKind::ProfileUpdated, None, None),
        core_api::Event::Deregistered => (CoreEventKind::Deregistered, None, None),
    };
    let _ = sink.add(CoreEvent {
        kind,
        group_id,
        message,
        account,
    });
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
