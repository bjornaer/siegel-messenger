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

use crate::messages::{READ_RECEIPTS, TYPING, TYPING_STALE_MS, apply_change};
use crate::{AS_PUBLIC, CREDENTIAL, CoreError, SIGNER, SiegelCore, storage};

/// CRY-09: keep about this many one-time KeyPackages on the server; refill below the threshold.
const KEY_PACKAGES: u32 = 100;
const REFILL_BELOW: u32 = 20;
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

fn mls_err(e: core_crypto::mls::Error) -> CoreError {
    CoreError::new(match e.0.as_str() {
        "credential_invalid" | "unknown_group" => &e.0,
        _ => "mls",
    })
}

pub(crate) fn new_signer(s: &SqlCipher) -> Result<core_crypto::mls::SignatureKeyPair, CoreError> {
    Mls::new_signer(&provider(s)).map_err(mls_err)
}

fn addr(m: &Member) -> pb::DeviceAddress {
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
    Message(ChatMessage),
    /// A message in the chat changed: reaction, edit, delete or receipt.
    Updated {
        group_id: Vec<u8>,
    },
    /// The peer is typing (MSG-14); show it for a few seconds.
    Typing {
        group_id: Vec<u8>,
    },
    /// A contact's name or @username arrived or changed.
    ProfileUpdated {
        account: Vec<u8>,
    },
    /// This device was revoked or the account deleted; local data is already wiped (ID-12).
    Deregistered,
}

/// What processing one payload produced; a profile key also needs a network fetch afterwards.
enum Handled {
    Event(Event),
    /// The peer's new device joined us in a new MLS group (ID-09): share our profile key again.
    Rejoined(Vec<u8>),
    ProfileKey(Vec<u8>),
    /// A new text: shown, and acknowledged with a delivery receipt (MSG-13).
    Text(ChatMessage),
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
}

pub(crate) fn chat_message(m: Message, reactions: Vec<(Vec<u8>, String)>) -> Option<ChatMessage> {
    let (t, key_change) = if m.deleted {
        (pb::Text::default(), false)
    } else {
        match pb::Content::decode(m.body.as_slice()).ok()?.body? {
            pb::content::Body::Text(t) => (t, false),
            pb::content::Body::KeyChange(_) => (pb::Text::default(), true),
            _ => return None, // unknown types skipped (MSG-01)
        }
    };
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

    /// Tops the server up to ~100 one-time KeyPackages plus a last-resort one (CRY-09).
    pub async fn ensure_key_packages(&self) -> Result<(), CoreError> {
        let token = self.token()?;
        let remaining = self.net.upload_key_packages(&token, vec![], vec![]).await?;
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
        self.net.upload_key_packages(&token, kps, lr).await?;
        Ok(())
    }

    /// Starts (or returns the existing) 1:1 chat with @username. Returns the conversation ID.
    /// Starting a chat makes them our contact and shares our profile key with them.
    pub async fn start_chat(&self, username: &str) -> Result<Vec<u8>, CoreError> {
        let username = username.to_lowercase();
        let peer = self.lookup_username(&username).await?;
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
        let kps: Vec<Vec<u8>> = self
            .net
            .claim_key_packages(&token, peer)
            .await?
            .into_iter()
            .map(|k| k.key_package)
            .collect();
        let out = self.with_mls(|m, _| m.create_group(&kps).map_err(mls_err))?;
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
            Ok(others.first().ok_or(CoreError::new("mls"))?.identity_pub)
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
            self.deliver_once(group_id, &content).await?;
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
        if !self.deliver_once(group_id, content).await? {
            self.rekey(group_id).await?;
            self.deliver_once(group_id, content).await?;
        }
        Ok(())
    }

    /// One delivery attempt in the chat's current MLS group. False when every recipient
    /// device turned out to be revoked (the peer re-registered).
    async fn deliver_once(
        &self,
        group_id: &[u8],
        content: &pb::Content,
    ) -> Result<bool, CoreError> {
        let token = self.token()?;
        let mls_group = self.conversation(group_id)?.mls_group;
        let (payload, sealed, mut identified, recipients) = self.with_mls(|m, s| {
            let payload = m
                .encrypt(&mls_group, &content.encode_to_vec())
                .map_err(mls_err)?;
            let (mut sealed, mut identified) = (Vec::new(), Vec::new());
            let others = m.others(&mls_group).map_err(mls_err)?;
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
            Ok((payload, sealed, identified, recipients))
        })?;
        let mut revoked = 0;
        if !sealed.is_empty() {
            let (r, rejected) = self.net.send_sealed(sealed, payload.clone()).await?;
            revoked += r.len();
            identified.extend(rejected);
        }
        // ponytail: in groups (M3) revoked devices must also be removed from the group (ID-13).
        if !identified.is_empty() {
            revoked += self
                .net
                .send_identified(&token, identified, payload)
                .await?
                .len();
        }
        Ok(recipients == 0 || revoked < recipients)
    }

    /// Decrypts one queued payload and stores what it carries.
    fn handle(&self, payload: &[u8]) -> Result<Option<Handled>, CoreError> {
        let (read_receipts, typing) = (self.enabled(READ_RECEIPTS), self.enabled(TYPING));
        self.with_mls(|m, s| match m.receive(payload).map_err(mls_err)? {
            Received::Joined { group_id, members } => {
                let first = members.first().ok_or(CoreError::new("mls"))?;
                let (peer, identity) = (first.account_id.to_vec(), first.identity_pub);
                let contact = storage(s.contact(&peer))?;
                if matches!(&contact, Some(c) if c.state == ContactState::Blocked) {
                    m.forget(&group_id).map_err(mls_err)?; // MSG-16: blocked users can't start chats
                    return Ok(None);
                }
                let state = contact.as_ref().map_or(ContactState::Request, |c| c.state);
                if contact.is_none() {
                    storage(s.save_contact(&Contact {
                        account_id: peer.clone(),
                        state,
                        ..Default::default()
                    }))?;
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
                let from = sender.account_id.to_vec();
                if matches!(storage(s.contact(&from))?, Some(c) if c.state == ContactState::Blocked)
                {
                    return Ok(None); // MSG-16: dropped silently
                }
                let Ok(c) = pb::Content::decode(plaintext.as_slice()) else {
                    return Ok(None);
                };
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
                    Some(pb::content::Body::Text(_)) => {
                        let msg = Message {
                            message_id: c.message_id.clone(),
                            group_id,
                            sender_account: from,
                            sent_at: c.sent_at,
                            body: plaintext,
                            outgoing: false,
                            status: Status::Delivered,
                            edited: false,
                            deleted: false,
                        };
                        // MSG-03: a redelivered message (same ID) is dropped here.
                        if !storage(s.save_message(&msg))? {
                            return Ok(None);
                        }
                        Ok(chat_message(msg, vec![]).map(Handled::Text))
                    }
                    Some(
                        pb::content::Body::Reaction(_)
                        | pb::content::Body::Edit(_)
                        | pb::content::Body::Delete(_),
                    ) => Ok(apply_change(s, &group_id, &from, &c, true)?
                        .then_some(Handled::Event(Event::Updated { group_id }))),
                    Some(pb::content::Body::Receipt(r)) => {
                        let status = match r.kind() {
                            pb::receipt::Kind::Delivered => Status::Delivered,
                            pb::receipt::Kind::Read if read_receipts => Status::Read,
                            _ => return Ok(None), // MSG-13: ours off hides theirs
                        };
                        storage(s.advance_status(&group_id, &r.message_ids, status))?;
                        Ok(Some(Handled::Event(Event::Updated { group_id })))
                    }
                    Some(pb::content::Body::Typing(_))
                        if typing && now_ms() - c.sent_at < TYPING_STALE_MS =>
                    {
                        Ok(Some(Handled::Event(Event::Typing { group_id })))
                    }
                    _ => Ok(None), // unknown or not yet supported types (MSG-01)
                }
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

    async fn stream_until(
        &self,
        on_event: impl Fn(Event) + Send,
        idle: Option<std::time::Duration>,
    ) -> Result<(), CoreError> {
        let token = self.token()?;
        let _ = self.ensure_key_packages().await;
        let _ = self.publish_profile().await; // retries a publish that failed at registration
        let _ = self.self_updates().await;
        let mut stream = self.net.stream(&token).await?;
        loop {
            let frame = match idle {
                Some(d) => match tokio::time::timeout(d, stream.next()).await {
                    Ok(f) => f?,
                    Err(_) => return Ok(()), // drained
                },
                None => stream.next().await?,
            };
            let Some(frame) = frame else { break };
            match frame {
                Frame::Message { id, payload } => {
                    // ponytail: a payload that fails to process is acked and dropped so it
                    // can't block the queue; surface these once error reporting exists.
                    let handled = self.handle(&payload);
                    stream.ack(vec![id]).await?;
                    match handled {
                        Ok(Some(Handled::Event(e))) => on_event(e),
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
                                )
                                .await;
                            on_event(Event::Message(m));
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

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
