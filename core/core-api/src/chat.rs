//! 1:1 messaging over MLS (M2): KeyPackages, chat creation, sending, and the receive stream.

use std::time::{SystemTime, UNIX_EPOCH};

use core_crypto::mls::{DeviceCredential, Member, Mls, Received};
use core_net::{Frame, pb};
use core_store::{
    Contact, ContactState, Conversation, Message, MlsStorage, SqlCipher, Status, Store,
};
use openmls_rust_crypto::RustCrypto;
use openmls_traits::OpenMlsProvider;
use prost::Message as _;

use core_crypto::profile::ProfileKey;

use crate::groups::{GROUP_ADDS, joined_group, record_change};
use crate::messages::{READ_RECEIPTS, TYPING, TYPING_STALE_MS, apply_change};
use crate::{AS_PUBLIC, CREDENTIAL, CoreError, SIGNER, SiegelCore, storage};

/// CRY-09: keep about this many one-time KeyPackages on the server; refill below the threshold.
const KEY_PACKAGES: u32 = 100;
const REFILL_BELOW: u32 = 20;
/// Bumped whenever KeyPackages' capabilities change; 2 = group state extension (GRP-02).
const KP_VERSION: &[u8] = b"2";
const KP_VERSION_KEY: &str = "key_packages_version";
/// CRY-10 default: refresh our leaf keys in each chat at least this often.
const SELF_UPDATE_MS: i64 = 7 * 24 * 60 * 60 * 1000;

/// OpenMLS provider over the encrypted store: RustCrypto for crypto and randomness.
pub(crate) struct Provider<'a> {
    crypto: RustCrypto,
    storage: MlsStorage<'a>,
}

impl<'a> OpenMlsProvider for Provider<'a> {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = MlsStorage<'a>;
    fn storage(&self) -> &Self::StorageProvider {
        &self.storage
    }
    fn crypto(&self) -> &Self::CryptoProvider {
        &self.crypto
    }
    fn rand(&self) -> &Self::RandProvider {
        &self.crypto
    }
}

fn provider(s: &SqlCipher) -> Provider<'_> {
    Provider {
        crypto: RustCrypto::default(),
        storage: s.mls(),
    }
}

pub(crate) fn mls_err(e: core_crypto::mls::Error) -> CoreError {
    CoreError::new(match e.0.as_str() {
        "credential_invalid" | "unknown_group" | "name_invalid" | "peer_outdated" => &e.0,
        r if r.ends_with("_not_allowed") => "not_allowed", // GRP-05, GRP-06
        _ => "mls",
    })
}

pub(crate) fn new_signer(s: &SqlCipher) -> Result<core_crypto::mls::SignatureKeyPair, CoreError> {
    Mls::new_signer(&provider(s)).map_err(mls_err)
}

pub(crate) fn addr(m: &Member) -> pb::DeviceAddress {
    pb::DeviceAddress {
        account_id: m.account_id.to_vec(),
        device_id: m.device_id.to_vec(),
    }
}

pub(crate) fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Something that happened on the stream, for the UI.
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    /// Someone started a chat with us. `request` until we accept them (MSG-15).
    ConversationStarted {
        group_id: Vec<u8>,
        peer_account: Vec<u8>,
        request: bool,
    },
    Message(Box<ChatMessage>),
    /// A message in the chat changed: reaction, edit, delete or receipt.
    Updated {
        group_id: Vec<u8>,
    },
    /// Someone in the chat is typing (MSG-14); show it for a few seconds.
    Typing {
        group_id: Vec<u8>,
        account: Vec<u8>,
    },
    /// A contact's name or @username arrived or changed.
    ProfileUpdated {
        account: Vec<u8>,
    },
    /// This device was revoked or the account deleted; local data is already wiped (ID-12).
    Deregistered,
    /// Another account proved our number and took it. Everything else stays; the user should
    /// add a number so the account can be recovered (docs/change-number.md). Sent once.
    NumberRemoved,
    /// M7: suspended, or our @username was removed; `SiegelCore::notice` says why.
    Enforcement,
    /// M7: moderators reviewed some of our reports (`take_reports_reviewed` says how many).
    ReportsReviewed,
}

/// What processing one payload produced; a profile key also needs a network fetch afterwards.
enum Handled {
    Event(Event),
    /// The peer's new device joined us in a new MLS group (ID-09): share our profile key again.
    Rejoined(Vec<u8>),
    ProfileKey(Vec<u8>),
    /// A new text: shown, and acknowledged with a delivery receipt (MSG-13).
    Text(Box<ChatMessage>),
    /// We are in a new group (GRP-09); an invite (GRP-11) gets nothing back until accepted.
    GroupJoined {
        group_id: Vec<u8>,
        invite: bool,
    },
    /// A commit arrived in a group we left but are still in: our leave proposal was for an
    /// older epoch and got dropped, so propose again (GRP-10).
    StillInGroup(Vec<u8>),
    /// DISC-08: they opened our contact link, so their chat skipped the message request.
    AcceptedByLink(Vec<u8>),
    /// MSG-11: someone deleted a message for everyone; its attachment goes too.
    Deleted {
        group_id: Vec<u8>,
        message_id: Vec<u8>,
    },
    /// Members joined a group: they get our profile key.
    MembersAdded {
        group_id: Vec<u8>,
        accounts: Vec<[u8; 16]>,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct ChatMessage {
    pub group_id: Vec<u8>,
    pub message_id: Vec<u8>,
    pub sender_account: Vec<u8>,
    /// Sender clock (MSG-03: shown, not used for ordering).
    pub sent_at: i64,
    /// Empty once deleted for everyone.
    pub text: String,
    pub outgoing: bool,
    /// MSG-07: the quoted message.
    pub reply_to: Option<Vec<u8>>,
    pub status: Status,
    pub edited: bool,
    pub deleted: bool,
    /// MSG-08: (account, emoji), one per account.
    pub reactions: Vec<(Vec<u8>, String)>,
    /// CRY-13: a local notice that the peer's identity key changed, not a message.
    pub key_change: bool,
    /// GRP-12: a system line in a group, not a message.
    pub event: Option<crate::groups::GroupEvent>,
    /// GRP-15: accounts @mentioned in the text.
    pub mentions: Vec<Vec<u8>>,
    /// MED-04: a file instead of text; fetch it with `attachment_data`.
    pub attachment: Option<crate::AttachmentInfo>,
}

pub(crate) fn chat_message(m: Message, reactions: Vec<(Vec<u8>, String)>) -> Option<ChatMessage> {
    let (mut t, mut key_change, mut event) = (pb::Text::default(), false, None);
    let mut attachment = None;
    if !m.deleted {
        match pb::Content::decode(m.body.as_slice()).ok()?.body? {
            pb::content::Body::Text(x) => t = x,
            pb::content::Body::Attachment(a) => {
                attachment = Some(crate::media::info(&a));
                t.reply_to = a.reply_to;
            }
            pb::content::Body::KeyChange(_) => key_change = true,
            pb::content::Body::GroupEvent(e) => event = Some(crate::groups::group_event(e)?),
            _ => return None, // unknown types skipped (MSG-01)
        }
    }
    Some(ChatMessage {
        group_id: m.group_id,
        message_id: m.message_id,
        sender_account: m.sender_account,
        sent_at: m.sent_at,
        text: t.body,
        outgoing: m.outgoing,
        reply_to: Some(t.reply_to).filter(|r| !r.is_empty()),
        status: m.status,
        edited: m.edited,
        deleted: m.deleted,
        reactions,
        key_change,
        event,
        mentions: t.mentions,
        attachment,
    })
}

impl SiegelCore {
    /// Runs `f` with this device's MLS client while holding the store lock (never across awaits).
    pub(crate) fn with_mls<R>(
        &self,
        f: impl FnOnce(&Mls<Provider<'_>>, &SqlCipher) -> Result<R, CoreError>,
    ) -> Result<R, CoreError> {
        let guard = self.store.lock().unwrap();
        let s = guard.as_ref().ok_or(CoreError::new("wiped"))?;
        let missing = || CoreError::new("not_registered");
        let signer = storage(s.get(SIGNER))?.ok_or_else(missing)?;
        let credential =
            DeviceCredential::decode(&storage(s.get(CREDENTIAL))?.ok_or_else(missing)?)
                .ok_or_else(missing)?;
        let as_pub: [u8; 32] = storage(s.get(AS_PUBLIC))?
            .ok_or_else(missing)?
            .try_into()
            .map_err(|_| missing())?;
        let mls = Mls::load(provider(s), &signer, &credential, as_pub).map_err(mls_err)?;
        f(&mls, s)
    }

    /// Runs `f` against the store without MLS.
    pub(crate) fn with_store<R>(
        &self,
        f: impl FnOnce(&SqlCipher) -> Result<R, CoreError>,
    ) -> Result<R, CoreError> {
        match self.store.lock().unwrap().as_ref() {
            Some(s) => f(s),
            None => Err(CoreError::new("wiped")),
        }
    }

    /// Tops the server up to ~100 one-time KeyPackages plus a last-resort one (CRY-09). After an
    /// update that changed what KeyPackages declare (KP_VERSION), replaces them all once:
    /// old ones can't join groups.
    pub async fn ensure_key_packages(&self) -> Result<(), CoreError> {
        let token = self.token()?;
        let current = self.get(KP_VERSION_KEY)?.as_deref() == Some(KP_VERSION);
        let remaining = if current {
            self.net
                .upload_key_packages(&token, vec![], vec![], false)
                .await?
        } else {
            0
        };
        if remaining >= REFILL_BELOW {
            return Ok(());
        }
        let (kps, lr) = self.with_mls(|m, _| {
            let kps = m
                .key_packages((KEY_PACKAGES - remaining) as usize, false)
                .map_err(mls_err)?;
            let lr = m.key_packages(1, true).map_err(mls_err)?.remove(0);
            Ok((kps, lr))
        })?;
        self.net
            .upload_key_packages(&token, kps, lr, !current)
            .await?;
        self.put(KP_VERSION_KEY, KP_VERSION)?;
        Ok(())
    }

    /// Starts (or returns the existing) 1:1 chat with @username. Returns the conversation ID.
    /// Starting a chat makes them our contact and shares our profile key with them.
    pub async fn start_chat(&self, username: &str) -> Result<Vec<u8>, CoreError> {
        self.start_chat_with(username, &[], &[]).await
    }

    /// A chat with someone found by number: `proof` is the discovery output for it (M7).
    pub async fn start_chat_by_number(
        &self,
        username: &str,
        proof: &[u8],
    ) -> Result<Vec<u8>, CoreError> {
        self.start_chat_with(username, proof, &[]).await
    }

    pub(crate) async fn start_chat_with(
        &self,
        username: &str,
        discovery_proof: &[u8],
        link_secret: &[u8],
    ) -> Result<Vec<u8>, CoreError> {
        let username = username.to_lowercase();
        let peer = self
            .lookup_with(&username, discovery_proof, link_secret)
            .await?;
        if let Some(c) = self
            .conversations()?
            .into_iter()
            .find(|c| c.peer_account == peer)
        {
            return Ok(c.group_id);
        }
        let (mls_group, identity) = self.new_group(&peer).await?;
        self.with_store(|s| {
            let mut c = storage(s.contact(&peer))?.unwrap_or(Contact {
                account_id: peer.clone(),
                ..Default::default()
            });
            c.state = ContactState::Accepted;
            c.username.get_or_insert(username.clone());
            storage(s.save_contact(&c))?;
            storage(s.save_conversation(&Conversation {
                group_id: mls_group.clone(),
                peer_account: peer.clone(),
                mls_group: mls_group.clone(),
                ..Default::default()
            }))?;
            note_identity(s, &peer, &identity)
        })?;
        self.share_profile_key(&mls_group).await?;
        Ok(mls_group)
    }

    /// Creates an MLS group with the peer's devices and commits it. Returns the group ID and
    /// the peer's Account Identity Key from their credentials.
    async fn new_group(&self, peer: &[u8]) -> Result<(Vec<u8>, Vec<u8>), CoreError> {
        let token = self.token()?;
        let mut kps: Vec<Vec<u8>> = self
            .net
            .claim_key_packages(&token, peer)
            .await?
            .into_iter()
            .map(|k| k.key_package)
            .collect();
        kps.extend(self.own_other_key_packages().await);
        let out = self.with_mls(|m, _| m.create_group(&kps, None).map_err(mls_err))?;
        let req = pb::GroupsServiceCommitRequest {
            group_id: out.group_id.clone(),
            epoch: out.epoch,
            commit: out.commit,
            recipients: out.commit_to.iter().map(addr).collect(),
            welcome: out.welcome,
            welcome_recipients: out.welcome_to.iter().map(addr).collect(),
        };
        if let Err(e) = self.net.commit(&token, req).await {
            let _ = self.with_mls(|m, _| m.forget(&out.group_id).map_err(mls_err));
            return Err(e.into());
        }
        let identity = self.with_mls(|m, _| {
            m.confirm(&out.group_id).map_err(mls_err)?;
            let others = m.others(&out.group_id).map_err(mls_err)?;
            Ok(others
                .iter()
                .find(|o| o.account_id.as_slice() == peer)
                .ok_or(CoreError::new("mls"))?
                .identity_pub)
        })?;
        Ok((out.group_id, identity.to_vec()))
    }

    /// ID-09: the peer re-registered, so every device in the chat's MLS group is revoked. Moves
    /// the chat to a new group with their new device; the chat keeps its ID and history.
    async fn rekey(&self, group_id: &[u8]) -> Result<(), CoreError> {
        let conv = self.conversation(group_id)?;
        let (mls_group, identity) = self.new_group(&conv.peer_account).await?;
        let accepted = self.with_store(|s| {
            storage(s.set_mls_group(group_id, &mls_group))?;
            note_identity(s, &conv.peer_account, &identity)?;
            Ok(storage(s.contact(&conv.peer_account))?
                .is_some_and(|c| c.state == ContactState::Accepted))
        })?;
        if accepted {
            let key = pb::ProfileKeyUpdate {
                profile_key: self.profile_key()?.0.to_vec(),
            };
            let content = self.new_content(pb::content::Body::ProfileKeyUpdate(key));
            self.send_once(group_id, &content, None).await?;
        }
        Ok(())
    }

    /// CRY-10: a self-update commit in every chat whose keys are 7 days old. A new group counts
    /// as fresh (a reinstall re-registers and builds new groups, ID-09). Runs on each connect.
    /// ponytail: a device that stays connected for over a week waits for its next reconnect.
    async fn self_updates(&self) -> Result<(), CoreError> {
        let token = self.token()?;
        let now = now_ms();
        for conv in self.conversations()? {
            let key = format!("self_update.{}", hex(&conv.mls_group));
            let last = self
                .get(&key)?
                .and_then(|v| <[u8; 8]>::try_from(v.as_slice()).ok())
                .map(i64::from_be_bytes);
            match last {
                Some(t) if now - t < SELF_UPDATE_MS => continue,
                None => {
                    self.put(&key, &now.to_be_bytes())?;
                    continue;
                }
                Some(_) => {}
            }
            let g = conv.mls_group.clone();
            let out = self.with_mls(|m, _| m.self_update(&g).map_err(mls_err))?;
            let req = pb::GroupsServiceCommitRequest {
                group_id: g.clone(),
                epoch: out.epoch,
                commit: out.commit,
                recipients: out.commit_to.iter().map(addr).collect(),
                welcome: vec![],
                welcome_recipients: vec![],
            };
            match self.net.commit(&token, req).await {
                Ok(_) => {
                    self.with_mls(|m, _| m.confirm(&g).map_err(mls_err))?;
                    self.put(&key, &now.to_be_bytes())?;
                    if conv.is_group {
                        let _ = self.refresh_group_links(&conv.group_id).await; // GRP-16
                    }
                }
                // CRY-14: another commit won; theirs is in our queue, retry on the next connect.
                Err(_) => self.with_mls(|m, _| m.abort(&g).map_err(mls_err))?,
            }
        }
        Ok(())
    }

    pub(crate) fn conversation(&self, group_id: &[u8]) -> Result<Conversation, CoreError> {
        self.conversations()?
            .into_iter()
            .find(|c| c.group_id == group_id)
            .ok_or(CoreError::new("unknown_group"))
    }

    pub fn conversations(&self) -> Result<Vec<Conversation>, CoreError> {
        self.with_store(|s| storage(s.conversations()))
    }

    /// The newest `limit` messages of a conversation, oldest first.
    pub fn messages(&self, group_id: &[u8], limit: u32) -> Result<Vec<ChatMessage>, CoreError> {
        self.with_store(|s| {
            // ponytail: one reactions query per message; join them if long chats get slow.
            let mut out = Vec::new();
            for m in storage(s.messages(group_id, limit))? {
                let r = storage(s.reactions(&m.message_id))?;
                out.extend(chat_message(m, r));
            }
            Ok(out)
        })
    }

    /// Encrypts content for the group and delivers it: sealed to contacts whose profile key we
    /// hold (MSG-10), identified to everyone else (MSG-15). A rejected token (they rotated their
    /// key, e.g. after blocking us) falls back to identified; their app then drops it (MSG-16).
    pub(crate) async fn send_content(
        &self,
        group_id: &[u8],
        body: pb::content::Body,
    ) -> Result<pb::Content, CoreError> {
        let content = self.new_content(body);
        self.deliver(group_id, &content).await?;
        Ok(content)
    }

    pub(crate) async fn deliver(
        &self,
        group_id: &[u8],
        content: &pb::Content,
    ) -> Result<(), CoreError> {
        self.deliver_to(group_id, content, None).await
    }

    /// Delivers to the chat's members, or only to `only` (group receipts go to the sender
    /// alone, GRP-13). A 1:1 peer whose devices are all revoked re-registered: re-key the chat
    /// and send again (ID-09). In a group, re-registered members get their new devices (AC-05).
    pub(crate) async fn deliver_to(
        &self,
        group_id: &[u8],
        content: &pb::Content,
        only: Option<&[[u8; 16]]>,
    ) -> Result<(), CoreError> {
        let conv = self.conversation(group_id)?;
        let (revoked, recipients) = self.send_once(group_id, content, only).await?;
        if conv.is_group {
            // Their new devices join at the next epoch; send them what found the old ones gone.
            if !revoked.is_empty() && self.replace_devices(group_id, &revoked).await.is_ok() {
                self.send_once(group_id, content, Some(&revoked)).await?;
            }
        } else if recipients > 0 && !revoked.is_empty() {
            self.rekey(group_id).await?;
            self.send_once(group_id, content, None).await?;
        }
        Ok(())
    }

    /// Encrypts once and sends. Returns the accounts of revoked devices and how many devices
    /// it was meant for.
    async fn send_once(
        &self,
        group_id: &[u8],
        content: &pb::Content,
        only: Option<&[[u8; 16]]>,
    ) -> Result<(Vec<[u8; 16]>, usize), CoreError> {
        let mls_group = self.conversation(group_id)?.mls_group;
        let payload = self.with_mls(|m, _| {
            m.encrypt(&mls_group, &content.encode_to_vec())
                .map_err(mls_err)
        })?;
        self.send_payload(group_id, payload, only).await
    }

    /// GRP-10: a leave proposal is an MLS message of its own.
    pub(crate) async fn deliver_payload(
        &self,
        group_id: &[u8],
        payload: Vec<u8>,
    ) -> Result<(), CoreError> {
        self.send_payload(group_id, payload, None).await.map(|_| ())
    }

    /// Sends one MLS payload: sealed to contacts whose profile key we hold (MSG-10), identified
    /// to everyone else (MSG-15). A rejected token (they rotated their key, e.g. after blocking
    /// us) falls back to identified; their app then drops it (MSG-16).
    /// ponytail: group members who aren't contacts get identified sends.
    async fn send_payload(
        &self,
        group_id: &[u8],
        payload: Vec<u8>,
        only: Option<&[[u8; 16]]>,
    ) -> Result<(Vec<[u8; 16]>, usize), CoreError> {
        let token = self.token()?;
        let mls_group = self.conversation(group_id)?.mls_group;
        let (sealed, mut identified, recipients) = self.with_mls(|m, s| {
            let (mut sealed, mut identified) = (Vec::new(), Vec::new());
            let others: Vec<Member> = m
                .others(&mls_group)
                .map_err(mls_err)?
                .into_iter()
                .filter(|r| only.is_none_or(|o| o.contains(&r.account_id)))
                .collect();
            let recipients = others.len();
            for r in others {
                match storage(s.contact(&r.account_id))? {
                    Some(Contact {
                        state: ContactState::Accepted,
                        profile_key: Some(k),
                        ..
                    }) if k.len() == 32 => {
                        let key = ProfileKey(k.try_into().expect("32 bytes"));
                        sealed.push(pb::SealedRecipient {
                            address: Some(addr(&r)),
                            delivery_token: key.delivery_token().to_vec(),
                        });
                    }
                    _ => identified.push(addr(&r)),
                }
            }
            Ok((sealed, identified, recipients))
        })?;
        let mut revoked = Vec::new();
        if !sealed.is_empty() {
            let (r, rejected) = self.net.send_sealed(sealed, payload.clone()).await?;
            revoked.extend(r);
            identified.extend(rejected);
        }
        if !identified.is_empty() {
            revoked.extend(
                self.net
                    .send_identified(&token, identified, payload)
                    .await?,
            );
        }
        // M8: one of our own devices gone (unlinked) isn't a re-registration: drop just it.
        let me = self.me()?;
        let own: Vec<[u8; 16]> = revoked
            .iter()
            .filter(|d| d.account_id == me)
            .filter_map(|d| d.device_id.as_slice().try_into().ok())
            .collect();
        if !own.is_empty() {
            let _ = Box::pin(self.commit_full(group_id, vec![], &[], &own, |s| s, false)).await;
        }
        let mut accounts: Vec<[u8; 16]> = Vec::new();
        for d in revoked.iter().filter(|d| d.account_id != me) {
            if let Ok(a) = <[u8; 16]>::try_from(d.account_id.as_slice())
                && !accounts.contains(&a)
            {
                accounts.push(a);
            }
        }
        Ok((accounts, recipients))
    }

    /// Decrypts one queued payload and stores what it carries.
    fn handle(&self, payload: &[u8]) -> Result<Option<Handled>, CoreError> {
        let (read_receipts, typing) = (self.enabled(READ_RECEIPTS), self.enabled(TYPING));
        // M7: under 18, only contacts can add us to groups; anyone else's add is an invite.
        let everyone_may_add =
            self.setting(GROUP_ADDS).as_deref() == Some("everyone") && !self.minor();
        let me = self.get(crate::ACCOUNT)?.unwrap_or_default();
        self.with_mls(|m, s| match m.receive(payload).map_err(mls_err)? {
            Received::Joined {
                group_id,
                members,
                adder,
                state: Some(_),
            } => Ok(
                joined_group(m, s, group_id, &members, adder.as_ref(), everyone_may_add)?
                    .map(|(group_id, invite)| Handled::GroupJoined { group_id, invite }),
            ),
            Received::Joined {
                group_id,
                members,
                adder,
                ..
            } => {
                // M8: the peer is the other account; our own other devices are members too.
                let first = members
                    .iter()
                    .find(|x| x.account_id.as_slice() != me.as_slice())
                    .ok_or(CoreError::new("mls"))?;
                let (peer, identity) = (first.account_id.to_vec(), first.identity_pub);
                let contact = storage(s.contact(&peer))?;
                if matches!(&contact, Some(c) if c.state == ContactState::Blocked) {
                    m.forget(&group_id).map_err(mls_err)?; // MSG-16: blocked users can't start chats
                    return Ok(None);
                }
                // A chat our own phone added this linked device to is one we already accepted.
                let by_me = adder.is_some_and(|a| a.account_id.as_slice() == me.as_slice());
                let state = match &contact {
                    Some(c) if !(by_me && c.state == ContactState::Request) => c.state,
                    _ if by_me => ContactState::Accepted,
                    _ => ContactState::Request,
                };
                match &contact {
                    None => storage(s.save_contact(&Contact {
                        account_id: peer.clone(),
                        state,
                        ..Default::default()
                    }))?,
                    Some(c) if c.state != state => {
                        storage(s.save_contact(&Contact { state, ..c.clone() }))?
                    }
                    _ => {}
                }
                let existing = storage(s.conversations())?
                    .into_iter()
                    .find(|c| c.peer_account == peer);
                if let Some(conv) = existing {
                    // ID-09 (or both sides starting at once): same chat, new MLS group. The
                    // old group stays mapped so its late messages still arrive.
                    storage(s.set_mls_group(&conv.group_id, &group_id))?;
                    note_identity(s, &peer, &identity)?;
                    return Ok(Some(Handled::Rejoined(conv.group_id)));
                }
                storage(s.save_conversation(&Conversation {
                    group_id: group_id.clone(),
                    peer_account: peer.clone(),
                    mls_group: group_id.clone(),
                    ..Default::default()
                }))?;
                note_identity(s, &peer, &identity)?;
                Ok(Some(Handled::Event(Event::ConversationStarted {
                    group_id,
                    peer_account: peer,
                    request: state != ContactState::Accepted,
                })))
            }
            Received::Message {
                group_id: mls_group,
                sender,
                plaintext,
            } => {
                let Some(group_id) = storage(s.conversation_for_mls(&mls_group))? else {
                    return Ok(None); // chat deleted here
                };
                let Some(conv) = storage(s.conversations())?
                    .into_iter()
                    .find(|c| c.group_id == group_id)
                else {
                    return Ok(None);
                };
                let from = sender.account_id.to_vec();
                if matches!(storage(s.contact(&from))?, Some(c) if c.state == ContactState::Blocked)
                {
                    return Ok(None); // MSG-16: dropped silently
                }
                let Ok(c) = pb::Content::decode(plaintext.as_slice()) else {
                    return Ok(None);
                };
                if let Some(pb::content::Body::Attachment(a)) = &c.body
                    && !crate::media::valid(a)
                {
                    return Ok(None);
                }
                // M8: from another of our own devices. What we sent shows as ours; their typing,
                // profile-key shares and receipts aren't for us (receipt sync: part 2).
                let mine = from.as_slice() == me.as_slice();
                if mine
                    && matches!(
                        c.body,
                        Some(
                            pb::content::Body::ProfileKeyUpdate(_)
                                | pb::content::Body::Typing(_)
                                | pb::content::Body::Receipt(_)
                                | pb::content::Body::ContactLink(_)
                        )
                    )
                {
                    return Ok(None);
                }
                match c.body {
                    Some(pb::content::Body::ProfileKeyUpdate(u)) if u.profile_key.len() == 32 => {
                        let mut contact = storage(s.contact(&from))?.unwrap_or(Contact {
                            account_id: from.clone(),
                            ..Default::default()
                        });
                        contact.profile_key = Some(u.profile_key);
                        storage(s.save_contact(&contact))?;
                        Ok(Some(Handled::ProfileKey(from)))
                    }
                    Some(pb::content::Body::Text(_) | pb::content::Body::Attachment(_)) => {
                        let msg = Message {
                            message_id: c.message_id.clone(),
                            group_id,
                            sender_account: from,
                            sent_at: c.sent_at,
                            body: plaintext,
                            outgoing: mine,
                            status: if mine {
                                Status::Sent
                            } else {
                                Status::Delivered
                            },
                            edited: false,
                            deleted: false,
                        };
                        // MSG-03: a redelivered message (same ID) is dropped here.
                        if !storage(s.save_message(&msg))? {
                            return Ok(None);
                        }
                        Ok(chat_message(msg, vec![]).map(|m| Handled::Text(Box::new(m))))
                    }
                    Some(pb::content::Body::Delete(ref d)) => {
                        let id = d.message_id.clone();
                        Ok(apply_change(s, &group_id, &from, &c, true)?.then_some(
                            Handled::Deleted {
                                group_id,
                                message_id: id,
                            },
                        ))
                    }
                    Some(pb::content::Body::Reaction(_) | pb::content::Body::Edit(_)) => {
                        Ok(apply_change(s, &group_id, &from, &c, true)?
                            .then_some(Handled::Event(Event::Updated { group_id })))
                    }
                    Some(pb::content::Body::Receipt(r)) => {
                        let status = match r.kind() {
                            pb::receipt::Kind::Delivered => Status::Delivered,
                            pb::receipt::Kind::Read if read_receipts => Status::Read,
                            _ => return Ok(None), // MSG-13: ours off hides theirs
                        };
                        if conv.is_group {
                            Self::group_receipt(m, s, &conv, &from, &r.message_ids, status, &me)?;
                        } else {
                            storage(s.advance_status(&group_id, &r.message_ids, status))?;
                        }
                        Ok(Some(Handled::Event(Event::Updated { group_id })))
                    }
                    Some(pb::content::Body::ContactLink(p)) if !conv.is_group => {
                        Ok(crate::links::accept_by_link(s, &from, &p.secret)?
                            .then_some(Handled::AcceptedByLink(group_id)))
                    }
                    Some(pb::content::Body::Typing(_))
                        if typing && now_ms() - c.sent_at < TYPING_STALE_MS =>
                    {
                        Ok(Some(Handled::Event(Event::Typing {
                            group_id,
                            account: from,
                        })))
                    }
                    _ => Ok(None), // unknown or not yet supported types (MSG-01)
                }
            }
            Received::Commit {
                group_id: mls_group,
                change: Some(change),
            } => {
                let Some(group_id) = storage(s.conversation_for_mls(&mls_group))? else {
                    return Ok(None);
                };
                let left = storage(s.conversations())?
                    .iter()
                    .any(|c| c.group_id == group_id && c.left);
                if left {
                    return Ok(Some(Handled::StillInGroup(group_id)));
                }
                for a in &change.added {
                    Self::ensure_contact(s, a)?;
                }
                record_change(s, &group_id, &change)?;
                let accounts = change.added.clone();
                Ok(Some(if accounts.is_empty() {
                    Handled::Event(Event::Updated { group_id })
                } else {
                    Handled::MembersAdded { group_id, accounts }
                }))
            }
            Received::Removed {
                group_id: mls_group,
            } => {
                let Some(group_id) = storage(s.conversation_for_mls(&mls_group))? else {
                    return Ok(None);
                };
                storage(s.set_conversation_flags(&group_id, false, true))?;
                m.forget(&mls_group).map_err(mls_err)?;
                Ok(Some(Handled::Event(Event::Updated { group_id })))
            }
            Received::Proposal { .. } => Ok(None), // committed by commit_due_proposals (GRP-10)
            Received::Rejected { group_id, .. } => {
                // GRP-07: refused, but the server counted the epoch.
                crate::groups::add_skew(s, &group_id)?;
                Ok(None)
            }
            Received::Commit { .. } | Received::Ignored => Ok(None),
        })
    }

    /// Connects the message stream and processes it until it closes or the device is
    /// deregistered. Call again (with backoff) to reconnect.
    pub async fn run_stream(&self, on_event: impl Fn(Event) + Send) -> Result<(), CoreError> {
        self.stream_until(on_event, None).await
    }

    /// After a push wake-up (MSG-17): processes what is queued and returns once nothing new
    /// arrived for a few seconds, or after 20 s (Android's background budget).
    pub async fn drain(&self, on_event: impl Fn(Event) + Send) -> Result<(), CoreError> {
        let idle = std::time::Duration::from_secs(3);
        let all = std::time::Duration::from_secs(20);
        tokio::time::timeout(all, self.stream_until(on_event, Some(idle)))
            .await
            .unwrap_or(Ok(()))
    }

    /// Upkeep on each connect: key packages (CRY-09), a profile publish that failed at
    /// registration, self-updates (CRY-10), pending leaves (GRP-10), contacts' and groups'
    /// pictures (MED-15).
    async fn upkeep(&self) -> Result<(), CoreError> {
        if self.get(crate::MINOR_SYNC)?.as_deref() == Some(b"1") {
            let _ = self.set_minor(self.minor()).await;
        }
        let _ = self.ensure_key_packages().await;
        let _ = self.ensure_own_devices().await; // M8: our linked devices in every conversation
        let _ = self.publish_profile().await;
        let _ = self.self_updates().await;
        for c in self.conversations()? {
            if c.is_group && c.left {
                let _ = self.repropose_leave(&c.group_id).await;
            }
            if c.is_group && !c.left {
                let _ = self.keep_group_avatar(&c.group_id).await;
                let _ = self.refresh_group_avatar(&c.group_id).await;
            }
        }
        self.refresh_missing_profiles().await;
        Ok(())
    }

    async fn stream_until(
        &self,
        on_event: impl Fn(Event) + Send,
        idle: Option<std::time::Duration>,
    ) -> Result<(), CoreError> {
        let token = self.token()?;
        let mut stream = self.net.stream(&token).await?;
        // Every 5 s while live, busy or not: commit members' pending leave proposals (GRP-10).
        // The first tick also does the upkeep, after what was queued: messages come first. A
        // drain after a push skips it; the app does it when it is opened.
        let tick = std::time::Duration::from_secs(5);
        let mut last_tick = std::time::Instant::now();
        let mut upkeep = idle.is_none();
        loop {
            if idle.is_none() && last_tick.elapsed() >= tick {
                last_tick = std::time::Instant::now();
                if std::mem::take(&mut upkeep) {
                    self.upkeep().await?;
                }
                let _ = self.commit_due_proposals().await;
            }
            let wait = idle.unwrap_or(tick);
            let frame = match tokio::time::timeout(wait, stream.next()).await {
                Ok(f) => f?,
                Err(_) if idle.is_some() => return Ok(()), // drained
                Err(_) => continue,
            };
            let Some(frame) = frame else { break };
            match frame {
                Frame::Message { id, payload } => {
                    // ponytail: a payload that fails to process is acked and dropped so it
                    // can't block the queue; surface these once error reporting exists.
                    let handled = self.handle(&payload);
                    stream.ack(vec![id]).await?;
                    match handled {
                        Ok(Some(Handled::Event(e))) => {
                            if let Event::Updated { group_id } = &e {
                                let _ = self.refresh_group_avatar(group_id).await; // MED-15
                            }
                            on_event(e)
                        }
                        Ok(Some(Handled::Deleted {
                            group_id,
                            message_id,
                        })) => {
                            self.forget_media(&message_id);
                            on_event(Event::Updated { group_id });
                        }
                        Ok(Some(Handled::Rejoined(group_id))) => {
                            if !self.is_request(&group_id).unwrap_or(true) {
                                let _ = self.share_profile_key(&group_id).await;
                            }
                            on_event(Event::Updated { group_id });
                        }
                        Ok(Some(Handled::Text(m))) => {
                            // ponytail: one receipt per message; batch per frame burst if chatty.
                            let _ = self
                                .send_receipt(
                                    &m.group_id,
                                    pb::receipt::Kind::Delivered,
                                    vec![m.message_id.clone()],
                                    &m.sender_account,
                                )
                                .await;
                            on_event(Event::Message(m));
                        }
                        Ok(Some(Handled::GroupJoined { group_id, invite })) => {
                            let _ = self.refresh_group_avatar(&group_id).await;
                            if !invite {
                                let _ = self.share_profile_key(&group_id).await;
                            }
                            on_event(Event::ConversationStarted {
                                group_id,
                                peer_account: vec![],
                                request: invite,
                            });
                        }
                        Ok(Some(Handled::AcceptedByLink(group_id))) => {
                            let _ = self.share_profile_key(&group_id).await;
                            on_event(Event::Updated { group_id });
                        }
                        Ok(Some(Handled::StillInGroup(group_id))) => {
                            let _ = self.repropose_leave(&group_id).await;
                        }
                        Ok(Some(Handled::MembersAdded { group_id, accounts })) => {
                            if !self.is_request(&group_id).unwrap_or(true) {
                                let _ = self.share_profile_key_with(&group_id, &accounts).await;
                            }
                            on_event(Event::Updated { group_id });
                        }
                        Ok(Some(Handled::ProfileKey(account))) => {
                            let fetched = self.refresh_profile(&account).await.is_ok();
                            if fetched {
                                on_event(Event::ProfileUpdated { account });
                            }
                        }
                        _ => {}
                    }
                }
                Frame::NumberRemoved => {
                    if !self.number_removed() {
                        self.put(crate::PHONE, b"")?;
                        self.put(crate::NUMBER_REMOVED, b"1")?;
                        on_event(Event::NumberRemoved);
                    }
                }
                Frame::ReportsReviewed(n) => {
                    let before = self.reports_reviewed();
                    self.put(crate::REVIEWED, (before + n.max(0)).to_string().as_bytes())?;
                    on_event(Event::ReportsReviewed);
                }
                Frame::Enforcement(e) => {
                    if e.kind() == pb::enforcement::Kind::UsernameRemoved {
                        self.put(crate::USERNAME, b"")?;
                    }
                    self.put(crate::NOTICE, &e.encode_to_vec())?;
                    on_event(Event::Enforcement);
                }
                Frame::Deregistered => {
                    self.wipe()?;
                    on_event(Event::Deregistered);
                    return Ok(());
                }
            }
        }
        Ok(())
    }
}

/// CRY-13: pins the peer's Account Identity Key on first sight. A different key later clears
/// the verified mark and puts a notice in every chat with them.
pub(crate) fn note_identity(s: &SqlCipher, peer: &[u8], identity: &[u8]) -> Result<(), CoreError> {
    let mut c = storage(s.contact(peer))?.unwrap_or(Contact {
        account_id: peer.to_vec(),
        ..Default::default()
    });
    let changed = match &c.identity_key {
        Some(k) if k == identity => return Ok(()),
        Some(_) => true,
        None => false,
    };
    c.identity_key = Some(identity.to_vec());
    c.verified = false;
    storage(s.save_contact(&c))?;
    if !changed {
        return Ok(());
    }
    for conv in storage(s.conversations())? {
        if conv.peer_account != peer {
            continue;
        }
        let id = uuid::Uuid::now_v7().as_bytes().to_vec();
        let content = pb::Content {
            message_id: id.clone(),
            sent_at: now_ms(),
            body: Some(pb::content::Body::KeyChange(pb::KeyChange {})),
        };
        storage(s.save_message(&Message {
            message_id: id,
            group_id: conv.group_id,
            sender_account: peer.to_vec(),
            sent_at: content.sent_at,
            body: content.encode_to_vec(),
            outgoing: false,
            status: Status::Read, // nothing to read-receipt
            edited: false,
            deleted: false,
        }))?;
    }
    Ok(())
}

pub(crate) fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
