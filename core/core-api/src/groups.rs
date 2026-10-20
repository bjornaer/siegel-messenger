//! Group chats (M3, section 8): creation, membership, roles, settings, invites and system lines.
//! Group state and permissions live in MLS (core-crypto groups.rs); this module moves commits
//! over the network, resolves races between concurrent commits (CRY-14, AC-04) and keeps the
//! local chat in step.

use core_crypto::groups::{Account, GroupState};
use core_crypto::mls::{Change, Member, Mls};
use core_net::pb;
use core_store::{Contact, ContactState, Conversation, Message, SqlCipher, Status, Store};
use prost::Message as _;

use crate::chat::{Provider, addr, mls_err, note_identity, now_ms};
use crate::{CoreError, SiegelCore, storage};

/// GRP-01: up to 256 members including the creator.
const MAX_MEMBERS: usize = 256;
/// GRP-11 setting key: "everyone" or "contacts" (default) may add me to groups.
pub const GROUP_ADDS: &str = "group_adds";

/// A group as the UI shows it.
#[derive(Debug, Clone, PartialEq)]
pub struct GroupInfo {
    pub name: String,
    pub members: Vec<GroupMember>,
    pub admins_only_info: bool,
    pub admins_only_add: bool,
    pub me_admin: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct GroupMember {
    pub account: Vec<u8>,
    pub display_name: Option<String>,
    pub username: Option<String>,
    pub admin: bool,
    pub me: bool,
}

/// GRP-12 system line kinds.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum GroupEventKind {
    Created,
    Added,
    Removed,
    Left,
    Renamed,
    AdminAdded,
    AdminRemoved,
    Settings,
    /// MED-15: the group picture changed or was removed.
    Avatar,
}

/// A system line in a group chat.
#[derive(Debug, Clone, PartialEq)]
pub struct GroupEvent {
    pub kind: GroupEventKind,
    /// Who made the change; empty when unknown.
    pub actor: Vec<u8>,
    pub targets: Vec<Vec<u8>>,
    /// Renamed: the new name.
    pub name: String,
}

pub(crate) fn group_event(e: pb::GroupEvent) -> Option<GroupEvent> {
    use pb::group_event::Kind as K;
    let kind = match e.kind() {
        K::Created => GroupEventKind::Created,
        K::Added => GroupEventKind::Added,
        K::Removed => GroupEventKind::Removed,
        K::Left => GroupEventKind::Left,
        K::Renamed => GroupEventKind::Renamed,
        K::AdminAdded => GroupEventKind::AdminAdded,
        K::AdminRemoved => GroupEventKind::AdminRemoved,
        K::Settings => GroupEventKind::Settings,
        K::Avatar => GroupEventKind::Avatar,
        K::Unspecified => return None,
    };
    Some(GroupEvent {
        kind,
        actor: e.actor,
        targets: e.targets,
        name: e.name,
    })
}

fn group_avatar_key(conv: &[u8]) -> String {
    let hex: String = conv.iter().map(|b| format!("{b:02x}")).collect();
    format!("group_avatar:{hex}")
}

/// Stores one system line in the chat (GRP-12).
fn system_line(
    s: &SqlCipher,
    conv: &[u8],
    kind: pb::group_event::Kind,
    actor: &[u8],
    targets: &[Account],
    name: &str,
) -> Result<(), CoreError> {
    let id = uuid::Uuid::now_v7().as_bytes().to_vec();
    let content = pb::Content {
        message_id: id.clone(),
        sent_at: now_ms(),
        body: Some(pb::content::Body::GroupEvent(pb::GroupEvent {
            kind: kind as i32,
            actor: actor.to_vec(),
            targets: targets.iter().map(|a| a.to_vec()).collect(),
            name: name.into(),
        })),
    };
    storage(s.save_message(&Message {
        message_id: id,
        group_id: conv.to_vec(),
        sender_account: actor.to_vec(),
        sent_at: content.sent_at,
        body: content.encode_to_vec(),
        outgoing: false,
        status: Status::Read, // nothing to read-receipt
        edited: false,
        deleted: false,
    }))?;
    Ok(())
}

/// The system lines for one committed change, ours or someone else's.
pub(crate) fn record_change(s: &SqlCipher, conv: &[u8], ch: &Change) -> Result<(), CoreError> {
    use pb::group_event::Kind as K;
    let by = &ch.by[..];
    if !ch.added.is_empty() {
        system_line(s, conv, K::Added, by, &ch.added, "")?;
    }
    if !ch.removed.is_empty() {
        system_line(s, conv, K::Removed, by, &ch.removed, "")?;
    }
    for a in &ch.left {
        system_line(s, conv, K::Left, a, &[], "")?;
    }
    if ch.new.name != ch.old.name {
        system_line(s, conv, K::Renamed, by, &[], &ch.new.name)?;
    }
    if ch.new.avatar != ch.old.avatar {
        system_line(s, conv, K::Avatar, by, &[], "")?;
    }
    let (was, is) = (ch.old.effective_admins(), ch.new.effective_admins());
    let promoted: Vec<Account> = is.iter().filter(|a| !was.contains(a)).copied().collect();
    let demoted: Vec<Account> = was
        .iter()
        .filter(|a| !is.contains(a) && ch.new.joined.contains(a))
        .copied()
        .collect();
    if !promoted.is_empty() {
        system_line(s, conv, K::AdminAdded, by, &promoted, "")?;
    }
    if !demoted.is_empty() {
        system_line(s, conv, K::AdminRemoved, by, &demoted, "")?;
    }
    if (ch.new.admins_only_info, ch.new.admins_only_add)
        != (ch.old.admins_only_info, ch.old.admins_only_add)
    {
        system_line(s, conv, K::Settings, by, &[], "")?;
    }
    Ok(())
}

/// Someone added us to a group (GRP-09). A contact (or anyone, if the user allows it) adds us
/// straight in; anyone else sends an invite we accept or decline (GRP-11). Returns the chat
/// and whether it is an invite, or None when the adder is blocked.
pub(crate) fn joined_group(
    m: &Mls<Provider<'_>>,
    s: &SqlCipher,
    group_id: Vec<u8>,
    members: &[Member],
    adder: Option<&Member>,
    everyone_may_add: bool,
) -> Result<Option<(Vec<u8>, bool)>, CoreError> {
    let adder_contact = match adder {
        Some(a) => storage(s.contact(&a.account_id))?,
        None => None,
    };
    if matches!(&adder_contact, Some(c) if c.state == ContactState::Blocked) {
        m.forget(&group_id).map_err(mls_err)?; // MSG-16
        return Ok(None);
    }
    // Re-added to a chat we have (after being removed, or to repair a split-off copy): the
    // same chat again, still an invite if it was one.
    let known = storage(s.conversations())?
        .into_iter()
        .find(|c| c.group_id == group_id);
    // M8: our own phone adding this linked device is never an invite.
    let me = storage(s.get(crate::ACCOUNT))?.unwrap_or_default();
    let by_me = adder.is_some_and(|a| a.account_id.as_slice() == me.as_slice());
    let invite = match &known {
        Some(c) => c.invite,
        None => {
            !by_me
                && !everyone_may_add
                && !matches!(&adder_contact, Some(c) if c.state == ContactState::Accepted)
        }
    };
    for member in members {
        note_identity(s, &member.account_id, &member.identity_pub)?;
    }
    if known.is_some() {
        storage(s.set_conversation_flags(&group_id, invite, false))?;
    }
    storage(s.save_conversation(&Conversation {
        group_id: group_id.clone(),
        mls_group: group_id.clone(),
        is_group: true,
        invite,
        ..Default::default()
    }))?;
    let me = m
        .roster(&group_id)
        .map_err(mls_err)?
        .into_iter()
        .map(|x| x.account_id)
        .find(|a| !members.iter().any(|o| o.account_id == *a));
    let actor = adder.map(|a| a.account_id.to_vec()).unwrap_or_default();
    system_line(
        s,
        &group_id,
        pb::group_event::Kind::Added,
        &actor,
        &me.into_iter().collect::<Vec<_>>(),
        "",
    )?;
    Ok(Some((group_id, invite)))
}

fn skew_key(mls_group: &[u8]) -> String {
    format!("epoch_skew.{}", crate::chat::hex(mls_group))
}

fn skew_in(s: &SqlCipher, mls_group: &[u8]) -> Result<u64, CoreError> {
    Ok(storage(s.get(&skew_key(mls_group)))?
        .and_then(|v| <[u8; 8]>::try_from(v.as_slice()).ok())
        .map_or(0, u64::from_be_bytes))
}

/// A commit we rejected still took a server epoch: our commits must count it (GRP-07).
pub(crate) fn add_skew(s: &SqlCipher, mls_group: &[u8]) -> Result<(), CoreError> {
    let n = skew_in(s, mls_group)? + 1;
    storage(s.put(&skew_key(mls_group), &n.to_be_bytes()))
}

impl SiegelCore {
    fn group_conversation(&self, conv: &[u8]) -> Result<Conversation, CoreError> {
        let c = self.conversation(conv)?;
        if !c.is_group {
            return Err(CoreError::new("not_a_group"));
        }
        Ok(c)
    }

    /// Server epochs we know were taken by commits we rejected (GRP-07).
    fn skew(&self, mls_group: &[u8]) -> u64 {
        self.with_store(|s| skew_in(s, mls_group)).unwrap_or(0)
    }

    async fn claim_all(&self, accounts: &[Account]) -> Result<Vec<Vec<u8>>, CoreError> {
        let token = self.token()?;
        let mut kps = Vec::new();
        for a in accounts {
            kps.extend(
                self.net
                    .claim_key_packages(&token, a)
                    .await?
                    .into_iter()
                    .map(|k| k.key_package),
            );
        }
        Ok(kps)
    }

    async fn accounts_for(&self, usernames: &[String]) -> Result<Vec<Account>, CoreError> {
        let mut out = Vec::new();
        for u in usernames {
            let a: Account = self
                .lookup_username(&u.to_lowercase())
                .await?
                .try_into()
                .map_err(|_| CoreError::new("bad_response"))?;
            if !out.contains(&a) {
                out.push(a);
            }
        }
        Ok(out)
    }

    /// GRP-01: a new group with these members; we are its admin. Returns the chat ID.
    pub async fn create_group(
        &self,
        name: &str,
        usernames: &[String],
    ) -> Result<Vec<u8>, CoreError> {
        let name = name.trim();
        if !(1..=64).contains(&name.chars().count()) {
            return Err(CoreError::new("name_invalid"));
        }
        let accounts = self.accounts_for(usernames).await?;
        if accounts.len() + 1 > MAX_MEMBERS {
            return Err(CoreError::new("group_too_large"));
        }
        let mut kps = self.claim_all(&accounts).await?;
        // M8: our own other devices are members too (the server skips this one).
        kps.extend(self.own_other_key_packages().await);
        let init = GroupState {
            name: name.into(),
            admins_only_info: true, // GRP-06 defaults
            admins_only_add: true,
            ..Default::default()
        };
        let out = self.with_mls(|m, _| m.create_group(&kps, Some(&init)).map_err(mls_err))?;
        let req = pb::GroupsServiceCommitRequest {
            group_id: out.group_id.clone(),
            epoch: out.epoch,
            commit: out.commit,
            recipients: vec![],
            welcome: out.welcome,
            welcome_recipients: out.welcome_to.iter().map(addr).collect(),
        };
        if let Err(e) = self.net.commit(&self.token()?, req).await {
            let _ = self.with_mls(|m, _| m.forget(&out.group_id).map_err(mls_err));
            return Err(e.into());
        }
        let gid = out.group_id;
        let me = self.me_account()?; // never inside with_mls/with_store: they hold the store lock
        self.with_mls(|m, s| {
            m.confirm(&gid).map_err(mls_err)?;
            for member in &out.welcome_to {
                note_identity(s, &member.account_id, &member.identity_pub)?;
            }
            storage(s.save_conversation(&Conversation {
                group_id: gid.clone(),
                mls_group: gid.clone(),
                is_group: true,
                ..Default::default()
            }))?;
            system_line(s, &gid, pb::group_event::Kind::Created, &me, &[], name)
        })?;
        self.share_profile_key(&gid).await?;
        Ok(gid)
    }

    fn me_account(&self) -> Result<Vec<u8>, CoreError> {
        self.get(crate::ACCOUNT)?
            .ok_or(CoreError::new("not_registered"))
    }

    /// Name, members with roles, and settings.
    pub fn group_info(&self, conv: &[u8]) -> Result<GroupInfo, CoreError> {
        let c = self.group_conversation(conv)?;
        let me = self.me_account()?;
        self.with_mls(|m, s| {
            let st = m
                .state(&c.mls_group)
                .map_err(mls_err)?
                .ok_or(CoreError::new("not_a_group"))?;
            let admins = st.effective_admins();
            // Everyone in the join order, then anyone who joined by link and isn't in it yet.
            let mut accounts = st.joined.clone();
            for m in m.roster(&c.mls_group).map_err(mls_err)? {
                if !accounts.contains(&m.account_id) {
                    accounts.push(m.account_id);
                }
            }
            let mut members = Vec::new();
            for a in &accounts {
                let contact = storage(s.contact(a))?;
                members.push(GroupMember {
                    account: a.to_vec(),
                    display_name: contact.as_ref().and_then(|c| c.display_name.clone()),
                    username: contact.and_then(|c| c.username),
                    admin: admins.contains(a),
                    me: a[..] == me[..],
                });
            }
            Ok(GroupInfo {
                me_admin: members.iter().any(|x| x.me && x.admin),
                name: st.name,
                members,
                admins_only_info: st.admins_only_info,
                admins_only_add: st.admins_only_add,
            })
        })
    }

    /// One membership or metadata commit, retried when another commit wins the epoch (CRY-14,
    /// AC-04): we wait for the winner to arrive on the stream, then rebuild on top of it.
    pub(crate) async fn group_commit(
        &self,
        conv: &[u8],
        add: &[Account],
        remove: &[Account],
        edit: impl Fn(GroupState) -> GroupState,
    ) -> Result<(), CoreError> {
        self.group_commit_from(conv, add, remove, edit, false).await
    }

    /// `on_stream`: called from the stream loop itself, which can't receive the winning commit
    /// while it waits for it. Then a lost race just gives up; the loop processes the winner next
    /// and retries what's still pending on a later tick.
    async fn group_commit_from(
        &self,
        conv: &[u8],
        add: &[Account],
        remove: &[Account],
        edit: impl Fn(GroupState) -> GroupState,
        on_stream: bool,
    ) -> Result<(), CoreError> {
        let c = self.group_conversation(conv)?;
        if c.left {
            return Err(CoreError::new("group_left"));
        }
        let kps = self.claim_all(add).await?;
        self.commit_with(conv, kps, remove, edit, on_stream).await
    }

    /// One commit with these KeyPackages added, in a group or a 1:1 chat (M8: our own new
    /// devices join every conversation this way).
    pub(crate) async fn commit_with(
        &self,
        conv: &[u8],
        kps: Vec<Vec<u8>>,
        remove: &[Account],
        edit: impl Fn(GroupState) -> GroupState,
        on_stream: bool,
    ) -> Result<(), CoreError> {
        self.commit_full(conv, kps, remove, &[], edit, on_stream)
            .await
    }

    /// The commit itself: add these KeyPackages, remove these accounts and single devices.
    pub(crate) async fn commit_full(
        &self,
        conv: &[u8],
        kps: Vec<Vec<u8>>,
        remove: &[Account],
        drop_devices: &[[u8; 16]],
        edit: impl Fn(GroupState) -> GroupState,
        on_stream: bool,
    ) -> Result<(), CoreError> {
        let token = self.token()?;
        for _ in 0..3 {
            let g = self.conversation(conv)?.mls_group;
            let before = self.with_mls(|m, _| m.state(&g).map_err(mls_err))?;
            let edited = before.clone().map(&edit);
            let out = self.with_mls(|m, _| {
                m.commit_dropping(&g, &kps, remove, drop_devices, edited)
                    .map_err(mls_err)
            })?;
            let req = pb::GroupsServiceCommitRequest {
                group_id: g.clone(),
                epoch: out.epoch + self.skew(&g),
                commit: out.commit,
                recipients: out.commit_to.iter().map(addr).collect(),
                welcome: out.welcome,
                welcome_recipients: out.welcome_to.iter().map(addr).collect(),
            };
            match self.net.commit(&token, req).await {
                Ok(_) => {
                    let me: Account = self
                        .me_account()?
                        .try_into()
                        .map_err(|_| CoreError::new("not_registered"))?;
                    let recorded = self.with_mls(|m, s| {
                        m.confirm(&g).map_err(mls_err)?;
                        for member in &out.welcome_to {
                            note_identity(s, &member.account_id, &member.identity_pub)?;
                        }
                        let (Some(old), Some(new)) = (before, m.state(&g).map_err(mls_err)?) else {
                            return Ok(());
                        };
                        let gone: Vec<Account> = old
                            .joined
                            .iter()
                            .filter(|a| !new.joined.contains(a))
                            .copied()
                            .collect();
                        let change = Change {
                            by: me,
                            added: new
                                .joined
                                .iter()
                                .filter(|a| !old.joined.contains(a))
                                .copied()
                                .collect(),
                            removed: gone
                                .iter()
                                .filter(|a| remove.contains(a))
                                .copied()
                                .collect(),
                            left: gone
                                .iter()
                                .filter(|a| !remove.contains(a))
                                .copied()
                                .collect(),
                            old,
                            new,
                        };
                        record_change(s, conv, &change)
                    });
                    recorded?;
                    let _ = self.refresh_group_links(conv).await; // GRP-16: links follow the epoch
                    return Ok(());
                }
                Err(e) if e.code == "epoch_conflict" => {
                    self.with_mls(|m, _| m.abort(&g).map_err(mls_err))?;
                    if on_stream {
                        return Err(e.into());
                    }
                    let epoch = self.with_mls(|m, _| m.epoch(&g).map_err(mls_err))?;
                    // The winning commit comes in on the stream; give it a moment.
                    for _ in 0..50 {
                        crate::rt::sleep(std::time::Duration::from_millis(200)).await;
                        if self.with_mls(|m, _| m.epoch(&g).map_err(mls_err))? > epoch {
                            break;
                        }
                    }
                }
                Err(e) => {
                    let _ = self.with_mls(|m, _| m.abort(&g).map_err(mls_err));
                    return Err(e.into());
                }
            }
        }
        Err(CoreError::new("epoch_conflict"))
    }

    /// GRP-09: adds people by @username. New members see only what's sent from now on.
    pub async fn add_members(&self, conv: &[u8], usernames: &[String]) -> Result<(), CoreError> {
        let accounts = self.accounts_for(usernames).await?;
        let size = self.group_info(conv)?.members.len();
        if size + accounts.len() > MAX_MEMBERS {
            return Err(CoreError::new("group_too_large"));
        }
        self.group_commit(conv, &accounts, &[], |s| s).await?;
        self.share_profile_key_with(conv, &accounts).await
    }

    /// GRP-05: admins remove members.
    pub async fn remove_member(&self, conv: &[u8], account: &[u8]) -> Result<(), CoreError> {
        let a: Account = account
            .try_into()
            .map_err(|_| CoreError::new("unknown_contact"))?;
        self.group_commit(conv, &[], &[a], |s| s).await
    }

    /// GRP-05: promote or demote an admin.
    pub async fn set_admin(
        &self,
        conv: &[u8],
        account: &[u8],
        admin: bool,
    ) -> Result<(), CoreError> {
        let a: Account = account
            .try_into()
            .map_err(|_| CoreError::new("unknown_contact"))?;
        self.group_commit(conv, &[], &[], |mut s| {
            s.admins = s.effective_admins();
            s.admins.retain(|x| *x != a);
            if admin {
                s.admins.push(a);
            }
            s
        })
        .await
    }

    /// GRP-01, GRP-06: rename, if the settings allow us.
    pub async fn rename_group(&self, conv: &[u8], name: &str) -> Result<(), CoreError> {
        let name = name.trim().to_string();
        self.group_commit(conv, &[], &[], |s| GroupState {
            name: name.clone(),
            ..s
        })
        .await
    }

    /// MED-15, GRP-06: sets (PNG bytes) or removes (None) the group picture, if the settings
    /// allow us. The picture is uploaded renewable: members keep it alive (`keep_group_avatar`).
    pub async fn set_group_avatar(
        &self,
        conv: &[u8],
        image: Option<Vec<u8>>,
    ) -> Result<(), CoreError> {
        let avatar = match &image {
            Some(img) => {
                if img.is_empty() || img.len() > crate::contacts::MAX_AVATAR {
                    return Err(CoreError::new("avatar_invalid"));
                }
                let (a, _) = self.upload(img, true).await?;
                let bad = |_| CoreError::new("bad_response");
                Some(core_crypto::groups::GroupAvatar {
                    blob_id: a.blob_id.try_into().map_err(bad)?,
                    key: a.key.try_into().map_err(bad)?,
                    sha256: a.sha256.try_into().map_err(bad)?,
                    size: img.len() as u32,
                })
            }
            None => None,
        };
        self.group_commit(conv, &[], &[], |s| GroupState {
            avatar: avatar.clone(),
            ..s
        })
        .await?;
        let cached = match (&avatar, image) {
            (Some(a), Some(img)) => [a.blob_id.as_slice(), &img].concat(),
            _ => vec![],
        };
        self.put(&group_avatar_key(conv), &cached)
    }

    /// The group picture, once fetched.
    pub fn group_avatar(&self, conv: &[u8]) -> Option<Vec<u8>> {
        let v = self.get(&group_avatar_key(conv)).ok().flatten()?;
        (v.len() > 16).then(|| v[16..].to_vec())
    }

    fn group_state(&self, conv: &[u8]) -> Result<GroupState, CoreError> {
        let c = self.group_conversation(conv)?;
        self.with_mls(|m, _| {
            m.state(&c.mls_group)
                .map_err(mls_err)?
                .ok_or(CoreError::new("not_a_group"))
        })
    }

    /// Downloads the group picture when the group state points at a new one.
    pub(crate) async fn refresh_group_avatar(&self, conv: &[u8]) -> Result<(), CoreError> {
        let st = self.group_state(conv)?;
        let key = group_avatar_key(conv);
        let cached = self.get(&key)?.unwrap_or_default();
        let Some(a) = st.avatar else {
            if !cached.is_empty() {
                self.put(&key, b"")?;
            }
            return Ok(());
        };
        if cached.get(..16) == Some(&a.blob_id[..]) {
            return Ok(());
        }
        let r = pb::Attachment {
            blob_id: a.blob_id.to_vec(),
            sha256: a.sha256.to_vec(),
            ..Default::default()
        };
        let blob = self.download(&r).await?;
        let img = core_media::decrypt(&a.key, &blob, a.size as usize)
            .ok_or(CoreError::new("attachment_corrupt"))?;
        self.put(&key, &[&a.blob_id[..], &img].concat())
    }

    /// MED-15: renews the group picture on the server, at most once a day per group.
    pub(crate) async fn keep_group_avatar(&self, conv: &[u8]) -> Result<(), CoreError> {
        let Some(a) = self.group_state(conv)?.avatar else {
            return Ok(());
        };
        let kept_key = format!("{}_kept", group_avatar_key(conv));
        let now = now_ms() / 1000;
        let last = self
            .get(&kept_key)?
            .and_then(|b| <[u8; 8]>::try_from(b.as_slice()).ok())
            .map_or(0, i64::from_be_bytes);
        if now - last < 24 * 3600 {
            return Ok(());
        }
        self.net.keep_blob(&self.token()?, &a.blob_id).await?;
        self.put(&kept_key, &now.to_be_bytes())
    }

    /// GRP-06: who may edit name and avatar, and who may add members.
    pub async fn set_group_settings(
        &self,
        conv: &[u8],
        admins_only_info: bool,
        admins_only_add: bool,
    ) -> Result<(), CoreError> {
        self.group_commit(conv, &[], &[], |s| GroupState {
            admins_only_info,
            admins_only_add,
            ..s
        })
        .await
    }

    /// GRP-10: proposes our removal; another member commits it. The chat stays, read-only.
    pub async fn leave_group(&self, conv: &[u8]) -> Result<(), CoreError> {
        let c = self.group_conversation(conv)?;
        if c.left {
            return Ok(());
        }
        let proposal = self.with_mls(|m, _| m.leave(&c.mls_group).map_err(mls_err))?;
        self.deliver_payload(conv, proposal).await?;
        let me = self.me_account()?;
        self.with_store(|s| {
            storage(s.set_conversation_flags(conv, false, true))?;
            system_line(s, conv, pb::group_event::Kind::Left, &me, &[], "")
        })
    }

    /// GRP-10: proposes our removal again while we are still in the group (a proposal is only
    /// valid in the epoch it was made for). Does nothing once we are out.
    pub(crate) async fn repropose_leave(&self, conv: &[u8]) -> Result<(), CoreError> {
        let g = self.group_conversation(conv)?.mls_group;
        let Ok(proposal) = self.with_mls(|m, _| m.leave(&g).map_err(mls_err)) else {
            return Ok(()); // group gone: we were removed
        };
        self.deliver_payload(conv, proposal).await
    }

    /// GRP-11: accept an invite; members then get our profile key.
    pub async fn accept_invite(&self, conv: &[u8]) -> Result<(), CoreError> {
        let c = self.group_conversation(conv)?;
        self.with_store(|s| storage(s.set_conversation_flags(conv, false, c.left)))?;
        self.share_profile_key(conv).await
    }

    /// GRP-13: each member's receipt for one of our messages.
    pub fn message_receipts(&self, message_id: &[u8]) -> Result<Vec<(Vec<u8>, Status)>, CoreError> {
        self.with_store(|s| storage(s.receipts(message_id)))
    }

    /// GRP-13: records a member's receipt; our message is Delivered or Read once every other
    /// current member reached that state.
    pub(crate) fn group_receipt(
        m: &Mls<Provider<'_>>,
        s: &SqlCipher,
        conv: &Conversation,
        from: &[u8],
        ids: &[Vec<u8>],
        status: Status,
        me: &[u8],
    ) -> Result<(), CoreError> {
        let others: Vec<Account> = match m.state(&conv.mls_group).map_err(mls_err)? {
            Some(st) => st.joined.into_iter().filter(|a| a[..] != *me).collect(),
            None => return Ok(()),
        };
        for id in ids {
            let Some(msg) = storage(s.message(id))? else {
                continue;
            };
            if msg.group_id != conv.group_id || !msg.outgoing {
                continue;
            }
            storage(s.save_receipt(id, from, status))?;
            let got = storage(s.receipts(id))?;
            let all = others
                .iter()
                .map(|a| {
                    got.iter()
                        .find(|(x, _)| x[..] == a[..])
                        .map_or(Status::Sent, |(_, st)| *st)
                })
                .fold(Status::Read, |lo, st| if st < lo { st } else { lo });
            if all > Status::Sent {
                storage(s.advance_status(&conv.group_id, std::slice::from_ref(id), all))?;
            }
        }
        Ok(())
    }

    /// GRP-10: commits members' pending leave proposals a little after they arrive, spread per
    /// device so members don't all race for the same epoch.
    pub(crate) async fn commit_due_proposals(&self) -> Result<(), CoreError> {
        let me = self.me_account()?;
        // 2 to 11 s after it arrived, plus the 5 s tick: well within GRP-10's 60 s.
        let delay = 2_000 + i64::from(me.first().copied().unwrap_or(0) % 10) * 1_000;
        for c in self.conversations()? {
            if !c.is_group || c.left || c.invite {
                continue;
            }
            let key = format!("proposal_since.{}", crate::chat::hex(&c.mls_group));
            let pending =
                self.with_mls(|m, _| m.has_pending_proposals(&c.mls_group).map_err(mls_err))?;
            if !pending {
                let _ = self.with_store(|s| storage(s.put(&key, &[])));
                continue;
            }
            let since = self
                .get(&key)?
                .and_then(|v| <[u8; 8]>::try_from(v.as_slice()).ok())
                .map(i64::from_be_bytes);
            match since {
                None => self.put(&key, &now_ms().to_be_bytes())?,
                Some(t) if now_ms() - t >= delay => {
                    let _ = self
                        .group_commit_from(&c.group_id, &[], &[], |s| s, true)
                        .await;
                }
                Some(_) => {}
            }
        }
        Ok(())
    }

    /// AC-05: members whose devices were revoked re-registered; replace their devices with the
    /// new ones. Any member may do this: the membership itself doesn't change.
    pub(crate) async fn replace_devices(
        &self,
        conv: &[u8],
        accounts: &[Account],
    ) -> Result<(), CoreError> {
        self.group_commit_from(conv, accounts, accounts, |s| s, true)
            .await
    }

    /// Shares our profile key with some members only (new members, or everyone but a blocked
    /// account), so the key never reaches anyone else.
    pub(crate) async fn share_profile_key_with(
        &self,
        conv: &[u8],
        accounts: &[Account],
    ) -> Result<(), CoreError> {
        let key = pb::ProfileKeyUpdate {
            profile_key: self.profile_key()?.0.to_vec(),
        };
        let content = self.new_content(pb::content::Body::ProfileKeyUpdate(key));
        self.deliver_to(conv, &content, Some(accounts)).await
    }

    /// Group members who aren't contacts get a contact entry once their profile arrives.
    pub(crate) fn ensure_contact(s: &SqlCipher, account: &[u8]) -> Result<(), CoreError> {
        if storage(s.contact(account))?.is_none() {
            storage(s.save_contact(&Contact {
                account_id: account.to_vec(),
                ..Default::default()
            }))?;
        }
        Ok(())
    }
}

/// GRP-16 default: links last a week.
const INVITE_LIFE_SECS: u64 = 7 * 24 * 60 * 60;

/// One live invite link of a group.
#[derive(Debug, Clone, PartialEq)]
pub struct GroupLink {
    pub link: String,
    /// Unix seconds.
    pub expires: u64,
    pub id: Vec<u8>,
}

/// Name and member count shown before joining by link.
#[derive(Debug, Clone, PartialEq)]
pub struct GroupPreview {
    pub name: String,
    pub members: u32,
}

fn now_secs() -> u64 {
    crate::rt::SystemTime::now()
        .duration_since(crate::rt::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn random<const N: usize>() -> [u8; N] {
    use rand_core::RngCore as _;
    let mut b = [0u8; N];
    rand_core::OsRng.fill_bytes(&mut b);
    b
}

/// `/g/<id>#<key>`: ID and link key.
pub(crate) fn parse_group_link(link: &str) -> Option<([u8; 16], [u8; 32])> {
    use base64::Engine as _;
    let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let rest = link.split("/g/").nth(1)?;
    let (id, key) = rest.split_once('#')?;
    let id = b64.decode(id.trim_end_matches('/')).ok()?.try_into().ok()?;
    let key = b64.decode(key).ok()?.try_into().ok()?;
    Some((id, key))
}

impl SiegelCore {
    fn group_link(&self, id: &[u8; 16], key: &[u8; 32]) -> String {
        use base64::Engine as _;
        let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
        format!(
            "{}/g/{}#{}",
            self.server_url,
            b64.encode(id),
            b64.encode(key)
        )
    }

    /// GRP-16: a new invite link (admins only), valid for a week.
    pub async fn create_group_link(&self, conv: &[u8]) -> Result<String, CoreError> {
        let me: Account = self
            .me_account()?
            .try_into()
            .map_err(|_| CoreError::new("not_registered"))?;
        let invite = core_crypto::groups::Invite {
            id: random(),
            key: random(),
            write_key: random(),
            expires: now_secs() + INVITE_LIFE_SECS,
            by: me,
        };
        let added = invite.clone();
        self.group_commit(conv, &[], &[], move |mut s| {
            s.invites.retain(|i| i.expires > now_secs());
            s.invites.push(added.clone());
            s
        })
        .await?;
        self.refresh_group_links(conv).await?;
        Ok(self.group_link(&invite.id, &invite.key))
    }

    /// The group's live links (members can see them; only admins create or revoke).
    pub fn group_links(&self, conv: &[u8]) -> Result<Vec<GroupLink>, CoreError> {
        let g = self.group_conversation(conv)?.mls_group;
        let st = self
            .with_mls(|m, _| m.state(&g).map_err(mls_err))?
            .ok_or(CoreError::new("not_a_group"))?;
        let now = now_secs();
        Ok(st
            .invites
            .iter()
            .filter(|i| i.expires > now)
            .map(|i| GroupLink {
                link: self.group_link(&i.id, &i.key),
                expires: i.expires,
                id: i.id.to_vec(),
            })
            .collect())
    }

    /// Revokes a link: it stops working for anyone who hasn't joined yet.
    pub async fn revoke_group_link(&self, conv: &[u8], id: &[u8]) -> Result<(), CoreError> {
        let write_key = self
            .group_links_raw(conv)?
            .into_iter()
            .find(|i| i.id[..] == *id)
            .map(|i| i.write_key);
        let gone = id.to_vec();
        self.group_commit(conv, &[], &[], move |mut s| {
            s.invites.retain(|i| i.id[..] != gone[..]);
            s
        })
        .await?;
        if let Some(wk) = write_key {
            let _ = self.net.delete_invite(&self.token()?, id, &wk).await;
        }
        Ok(())
    }

    fn group_links_raw(&self, conv: &[u8]) -> Result<Vec<core_crypto::groups::Invite>, CoreError> {
        let g = self.group_conversation(conv)?.mls_group;
        Ok(self
            .with_mls(|m, _| m.state(&g).map_err(mls_err))?
            .map(|s| s.invites)
            .unwrap_or_default())
    }

    /// After every commit: the server's snapshot for each live link must show the current epoch,
    /// or joining fails. Sealed with the link key, with the epoch offset in front (GRP-07 skew).
    pub(crate) async fn refresh_group_links(&self, conv: &[u8]) -> Result<(), CoreError> {
        let c = self.group_conversation(conv)?;
        let now = now_secs();
        let live: Vec<_> = self
            .group_links_raw(conv)?
            .into_iter()
            .filter(|i| i.expires > now)
            .collect();
        if live.is_empty() {
            return Ok(());
        }
        let snapshot = self.with_mls(|m, _| m.snapshot(&c.mls_group).map_err(mls_err))?;
        let plain = [&self.skew(&c.mls_group).to_be_bytes()[..], &snapshot].concat();
        let token = self.token()?;
        for i in live {
            let sealed = core_crypto::groups::Invite::seal(&i.key, &plain);
            self.net
                .put_invite(&token, &i.id, &i.write_key, sealed, i.expires as i64)
                .await?;
        }
        Ok(())
    }

    async fn fetch_snapshot(
        &self,
        link: &str,
    ) -> Result<([u8; 16], [u8; 32], u64, Vec<u8>), CoreError> {
        let (id, key) = parse_group_link(link).ok_or(CoreError::new("link_invalid"))?;
        let sealed = self.net.get_invite(&self.token()?, &id).await?;
        let plain = core_crypto::groups::Invite::open(&key, &sealed)
            .ok_or(CoreError::new("link_invalid"))?;
        let (skew, snapshot) = plain
            .split_at_checked(8)
            .ok_or(CoreError::new("link_invalid"))?;
        let skew = u64::from_be_bytes(skew.try_into().expect("8 bytes"));
        Ok((id, key, skew, snapshot.to_vec()))
    }

    /// GRP-16: what the link leads to, before joining.
    pub async fn preview_group_link(&self, link: &str) -> Result<GroupPreview, CoreError> {
        let (_, _, _, snapshot) = self.fetch_snapshot(link).await?;
        let (st, n) = core_crypto::mls::Mls::<Provider<'_>>::peek(&snapshot).map_err(mls_err)?;
        Ok(GroupPreview {
            name: st.name,
            members: n as u32,
        })
    }

    /// GRP-16: joins by link straight away (admins can remove people afterwards). Returns the chat.
    pub async fn join_group_link(&self, link: &str) -> Result<Vec<u8>, CoreError> {
        let (id, key, skew, snapshot) = self.fetch_snapshot(link).await?;
        let out = self.with_mls(|m, _| m.join_by_link(&snapshot, &id, &key).map_err(mls_err))?;
        let gid = out.group_id.clone();
        if self.conversations()?.iter().any(|c| c.mls_group == gid) {
            return Err(CoreError::new("already_member"));
        }
        let req = pb::GroupsServiceCommitRequest {
            group_id: gid.clone(),
            epoch: out.epoch + skew,
            commit: out.commit,
            recipients: out.commit_to.iter().map(addr).collect(),
            welcome: vec![],
            welcome_recipients: vec![],
        };
        if let Err(e) = self.net.commit(&self.token()?, req).await {
            let _ = self.with_mls(|m, _| m.forget(&gid).map_err(mls_err));
            return Err(if e.code == "epoch_conflict" {
                CoreError::new("link_stale") // the group moved on; try again in a moment
            } else {
                e.into()
            });
        }
        let me = self.me_account()?;
        self.with_mls(|m, s| {
            for member in m.roster(&gid).map_err(mls_err)? {
                if member.account_id[..] != me[..] {
                    note_identity(s, &member.account_id, &member.identity_pub)?;
                }
            }
            if skew > 0 {
                storage(s.put(&skew_key(&gid), &skew.to_be_bytes()))?;
            }
            storage(s.save_conversation(&Conversation {
                group_id: gid.clone(),
                mls_group: gid.clone(),
                is_group: true,
                ..Default::default()
            }))?;
            system_line(
                s,
                &gid,
                pb::group_event::Kind::Added,
                &me,
                &[me.as_slice().try_into().unwrap_or_default()],
                "",
            )
        })?;
        self.share_profile_key(&gid).await?;
        let _ = self.refresh_group_links(&gid).await;
        Ok(gid)
    }
}
