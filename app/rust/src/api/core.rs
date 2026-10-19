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

pub struct GroupLinkView {
    pub link: String,
    /// Unix seconds.
    pub expires: i64,
    pub id: Vec<u8>,
}

pub struct GroupPreviewView {
    pub name: String,
    pub members: u32,
}

pub struct FoundContact {
    pub phone: String,
    pub username: String,
    /// Starts a chat even with someone under 18 (`start_chat_by_number`).
    pub proof: Vec<u8>,
}

/// RM-01: what the server holds about us. Ids and hashes are hex; days are YYYY-MM-DD.
pub struct ServerData {
    pub account_id: String,
    pub phone_hash: String,
    pub created_day: String,
    pub number_changed_day: String,
    pub identity_key: String,
    pub username: String,
    pub username_claimed_day: String,
    pub released_usernames: Vec<String>,
    pub registration_lock: bool,
    pub discoverable: bool,
    pub profile: bool,
    pub profile_picture: bool,
    pub numbers_checked: i32,
    pub devices: Vec<ServerDevice>,
    pub minor: bool,
}

pub struct ServerDevice {
    pub id: String,
    pub ios: bool,
    pub last_seen_day: String,
    pub push_token: bool,
    pub queued: i32,
    pub key_packages: i32,
    pub this_device: bool,
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// M7: what a moderator did, why (the rule: ReportCategory number), and until when.
pub struct NoticeView {
    pub suspended: bool,
    pub rule: i32,
    pub reason: String,
    pub until_ms: i64,
}

pub struct StickerView {
    pub id: String,
    pub pack: String,
    pub mime_type: String,
}

impl From<core_api::Sticker> for StickerView {
    fn from(s: core_api::Sticker) -> Self {
        Self {
            id: s.id,
            pack: s.pack,
            mime_type: s.mime_type,
        }
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

    /// Moves the account to a new number proven with an OTP from `request_otp`.
    pub async fn change_number(
        &self,
        phone_e164: String,
        otp: String,
        pin: String,
    ) -> Result<(), CoreError> {
        Ok(self.0.change_number(&phone_e164, &otp, &pin).await?)
    }

    pub async fn server_data(&self) -> Result<ServerData, CoreError> {
        let d = self.0.server_data().await?;
        Ok(ServerData {
            account_id: hex(&d.account_id),
            phone_hash: hex(&d.phone_hmac),
            created_day: d.created_day,
            number_changed_day: d.number_changed_day,
            identity_key: hex(&d.identity_pub),
            username: d.username,
            username_claimed_day: d.username_claimed_day,
            released_usernames: d.released_usernames,
            registration_lock: d.registration_lock,
            discoverable: d.discoverable,
            profile: d.profile,
            profile_picture: d.profile_picture,
            numbers_checked: d.numbers_checked,
            minor: d.minor,
            devices: d
                .devices
                .into_iter()
                .map(|v| ServerDevice {
                    id: hex(&v.device_id),
                    ios: v.platform == 1, // PLATFORM_IOS
                    last_seen_day: v.last_seen_day,
                    push_token: v.push_token,
                    queued: v.queued,
                    key_packages: v.key_packages,
                    this_device: v.this_device,
                })
                .collect(),
        })
    }

    /// CMP-03: reports chosen messages of a chat, sealed to the moderators' key. `category` is
    /// the ReportCategory number (1 spam … 8 other); `block` also blocks a 1:1 peer.
    pub async fn report(
        &self,
        group_id: Vec<u8>,
        category: i32,
        note: String,
        message_ids: Vec<Vec<u8>>,
        block: bool,
    ) -> Result<(), CoreError> {
        Ok(self
            .0
            .report(&group_id, category, &note, &message_ids, block)
            .await?)
    }

    /// Adds a WebP or PNG sticker to a pack ("" = my stickers).
    #[frb(sync)]
    pub fn add_sticker(
        &self,
        data: Vec<u8>,
        mime_type: String,
        pack: String,
    ) -> Result<StickerView, CoreError> {
        Ok(self.0.add_sticker(&data, &mime_type, &pack)?.into())
    }

    #[frb(sync)]
    pub fn stickers(&self) -> Result<Vec<StickerView>, CoreError> {
        Ok(self.0.stickers()?.into_iter().map(Into::into).collect())
    }

    #[frb(sync)]
    pub fn sticker_data(&self, id: String) -> Result<Option<Vec<u8>>, CoreError> {
        Ok(self.0.sticker_data(&id)?)
    }

    /// One sticker, or a whole pack when `id` is empty.
    #[frb(sync)]
    pub fn remove_stickers(&self, pack: String, id: String) -> Result<(), CoreError> {
        Ok(self.0.remove_stickers(&pack, &id)?)
    }

    /// Deletes a 1:1 chat's messages; its next message brings it back.
    #[frb(sync)]
    pub fn clear_chat(&self, group_id: Vec<u8>) -> Result<(), CoreError> {
        Ok(self.0.clear_chat(&group_id)?)
    }

    #[frb(sync)]
    pub fn number_removed(&self) -> bool {
        self.0.number_removed()
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

    /// GRP-16: a new invite link for the group (admins only), valid for a week.
    pub async fn create_group_link(&self, group_id: Vec<u8>) -> Result<String, CoreError> {
        Ok(self.0.create_group_link(&group_id).await?)
    }

    /// The group's live invite links.
    #[frb(sync)]
    pub fn group_links(&self, group_id: Vec<u8>) -> Result<Vec<GroupLinkView>, CoreError> {
        Ok(self
            .0
            .group_links(&group_id)?
            .into_iter()
            .map(|l| GroupLinkView {
                link: l.link,
                expires: l.expires as i64,
                id: l.id,
            })
            .collect())
    }

    pub async fn revoke_group_link(&self, group_id: Vec<u8>, id: Vec<u8>) -> Result<(), CoreError> {
        Ok(self.0.revoke_group_link(&group_id, &id).await?)
    }

    /// Name and size of the group a link leads to, before joining.
    pub async fn preview_group_link(&self, link: String) -> Result<GroupPreviewView, CoreError> {
        let p = self.0.preview_group_link(&link).await?;
        Ok(GroupPreviewView {
            name: p.name,
            members: p.members,
        })
    }

    /// Joins the group behind a link; returns its chat.
    pub async fn join_group_link(&self, link: String) -> Result<Vec<u8>, CoreError> {
        Ok(self.0.join_group_link(&link).await?)
    }

    /// DISC-08: our contact link, or None when it is off.
    #[frb(sync)]
    pub fn contact_link(&self) -> Result<Option<String>, CoreError> {
        Ok(self.0.contact_link()?)
    }

    #[frb(sync)]
    pub fn set_contact_link(&self, enabled: bool) -> Result<(), CoreError> {
        Ok(self.0.set_contact_link(enabled)?)
    }

    /// A new secret: links shared before lead to ordinary message requests.
    #[frb(sync)]
    pub fn reset_contact_link(&self) -> Result<(), CoreError> {
        Ok(self.0.reset_contact_link()?)
    }

    /// Opens someone's contact link; returns the chat (already accepted on their side).
    pub async fn open_contact_link(&self, link: String) -> Result<Vec<u8>, CoreError> {
        Ok(self.0.open_contact_link(&link).await?)
    }

    /// Our own number, if this device kept it (accounts from before build 13 may not have).
    #[frb(sync)]
    pub fn my_phone(&self) -> Option<String> {
        self.0.my_phone()
    }

    #[frb(sync)]
    pub fn set_my_phone(&self, phone: String) -> Result<(), CoreError> {
        Ok(self.0.set_my_phone(&phone)?)
    }

    /// DISC-03: "Let people who have my number find me". "phone_mismatch": not our number.
    pub async fn set_discoverable(&self, enabled: bool) -> Result<(), CoreError> {
        Ok(self.0.set_discoverable(enabled).await?)
    }

    pub async fn discoverable(&self) -> Result<bool, CoreError> {
        Ok(self.0.discoverable().await?)
    }

    /// DISC-05: which of these E.164 numbers can be found, with their @usernames.
    pub async fn find_contacts(
        &self,
        numbers: Vec<String>,
    ) -> Result<Vec<FoundContact>, CoreError> {
        Ok(self
            .0
            .find_contacts(&numbers)
            .await?
            .into_iter()
            .map(|f| FoundContact {
                phone: f.phone,
                username: f.username,
                proof: f.proof,
            })
            .collect())
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
    /// Incoming messages not read yet.
    pub unread: u32,
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
    Avatar,
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
    /// GRP-15: accounts @mentioned in the text.
    pub mentions: Vec<Vec<u8>>,
    /// MED-04: a file instead of text; its bytes come from `attachment_data`.
    pub attachment: Option<AttachmentView>,
}

pub struct AttachmentView {
    pub mime_type: String,
    /// Empty for voice notes.
    pub file_name: String,
    pub size: u64,
    pub duration_ms: u32,
    /// MED-09: recorded in the app.
    pub voice_note: bool,
    /// MED-09: loudness per bar, 0-255.
    pub waveform: Vec<u8>,
    /// Images and video.
    pub width: u32,
    pub height: u32,
    /// A small JPEG preview to show before the download.
    pub thumbnail: Vec<u8>,
    /// Shown large, without a bubble.
    pub sticker: bool,
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
            mentions: m.mentions,
            attachment: m.attachment.map(|a| AttachmentView {
                mime_type: a.mime_type,
                file_name: a.file_name,
                size: a.size,
                duration_ms: a.duration_ms,
                voice_note: a.voice_note,
                waveform: a.waveform,
                width: a.width,
                height: a.height,
                thumbnail: a.thumbnail,
                sticker: a.sticker,
            }),
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
                        K::Avatar => GroupEventKind::Avatar,
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
    /// Another account took our number; tell the user to add one (change number).
    NumberRemoved,
    /// M7: suspended or @username removed; `notice` says why.
    Enforcement,
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
    pub async fn start_chat_by_number(
        &self,
        username: String,
        proof: Vec<u8>,
    ) -> Result<Vec<u8>, CoreError> {
        Ok(self.0.start_chat_by_number(&username, &proof).await?)
    }

    /// M7: under 18, as the app worked out from the birth date it keeps.
    pub async fn set_minor(&self, minor: bool) -> Result<(), CoreError> {
        Ok(self.0.set_minor(minor).await?)
    }

    #[frb(sync)]
    pub fn notice(&self) -> Option<NoticeView> {
        self.0.notice().map(|n| NoticeView {
            suspended: n.kind == 1,
            rule: n.rule,
            reason: n.reason,
            until_ms: n.until_ms,
        })
    }

    #[frb(sync)]
    pub fn minor(&self) -> bool {
        self.0.minor()
    }

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
                    unread: self.0.unread(&c.group_id)?,
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
                unread: self.0.unread(&c.group_id)?,
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
        mentions: Vec<Vec<u8>>,
    ) -> Result<MessageView, CoreError> {
        Ok(self
            .0
            .send_text_mentioning(&group_id, &text, reply_to.as_deref(), &mentions)
            .await?
            .into())
    }

    /// MED-09: a voice note or audio file (and, later, any file). Fails without storing a
    /// message if the upload fails.
    #[allow(clippy::too_many_arguments)]
    pub async fn send_attachment(
        &self,
        group_id: Vec<u8>,
        data: Vec<u8>,
        mime_type: String,
        file_name: String,
        duration_ms: u32,
        voice_note: bool,
        waveform: Vec<u8>,
        width: u32,
        height: u32,
        thumbnail: Vec<u8>,
        sticker: bool,
        reply_to: Option<Vec<u8>>,
    ) -> Result<MessageView, CoreError> {
        let a = core_api::OutgoingAttachment {
            data,
            mime_type,
            file_name,
            duration_ms,
            voice_note,
            waveform,
            width,
            height,
            thumbnail,
            sticker,
        };
        Ok(self
            .0
            .send_attachment(&group_id, a, reply_to.as_deref())
            .await?
            .into())
    }

    /// MED-15: sets (PNG bytes) or removes (None) our picture and tells our contacts.
    pub async fn set_avatar(&self, image: Option<Vec<u8>>) -> Result<(), CoreError> {
        Ok(self.0.set_avatar(image).await?)
    }

    #[frb(sync)]
    pub fn my_avatar(&self) -> Option<Vec<u8>> {
        self.0.my_avatar()
    }

    /// A contact's picture, once fetched with their profile.
    #[frb(sync)]
    pub fn avatar(&self, account: Vec<u8>) -> Option<Vec<u8>> {
        self.0.avatar(&account)
    }

    /// MED-15: sets (PNG bytes) or removes (None) the group picture, if the settings allow us.
    pub async fn set_group_avatar(
        &self,
        group_id: Vec<u8>,
        image: Option<Vec<u8>>,
    ) -> Result<(), CoreError> {
        Ok(self.0.set_group_avatar(&group_id, image).await?)
    }

    #[frb(sync)]
    pub fn group_avatar(&self, group_id: Vec<u8>) -> Option<Vec<u8>> {
        self.0.group_avatar(&group_id)
    }

    /// Sends our current name and picture to every chat (after editing the profile).
    pub async fn announce_profile(&self) -> Result<(), CoreError> {
        Ok(self.0.announce_profile().await?)
    }

    /// Whether the attachment is on this device (no download needed).
    #[frb(sync)]
    pub fn attachment_downloaded(&self, message_id: Vec<u8>) -> bool {
        self.0.attachment_downloaded(&message_id)
    }

    /// MED-14: sends a message on to another chat; attachments are encrypted and uploaded again.
    pub async fn forward(
        &self,
        message_id: Vec<u8>,
        to: Vec<u8>,
    ) -> Result<MessageView, CoreError> {
        Ok(self.0.forward(&message_id, &to).await?.into())
    }

    /// The attachment's bytes, downloaded on first use. Errors: attachment_expired (MED-13),
    /// attachment_corrupt (MED-05), network.
    pub async fn attachment_data(&self, message_id: Vec<u8>) -> Result<Vec<u8>, CoreError> {
        Ok(self.0.attachment_data(&message_id).await?)
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
            Some((*m).into()),
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
        core_api::Event::NumberRemoved => (CoreEventKind::NumberRemoved, None, None),
        core_api::Event::Enforcement => (CoreEventKind::Enforcement, None, None),
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
    // The default logger sends every crate's trace output (MLS internals included) to the
    // system log, which other apps with log access can read. Release builds keep warnings only.
    log::set_max_level(if cfg!(debug_assertions) {
        log::LevelFilter::Info
    } else {
        log::LevelFilter::Warn
    });
}
