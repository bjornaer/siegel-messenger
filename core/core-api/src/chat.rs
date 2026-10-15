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
}

pub(crate) fn chat_message(m: Message, reactions: Vec<(Vec<u8>, String)>) -> Option<ChatMessage> {
    let t = if m.deleted {
        pb::Text::default()
    } else {
        let c = pb::Content::decode(m.body.as_slice()).ok()?;
        let Some(pb::content::Body::Text(t)) = c.body else {
            return None;
        }; // unknown types skipped (MSG-01)
        t
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
        let token = self.token()?;
        let username = username.to_lowercase();
        let peer = self.lookup_username(&username).await?;
        if let Some(c) = self
            .conversations()?
            .into_iter()
            .find(|c| c.peer_account == peer)
        {
            return Ok(c.group_id);
        }
        let kps: Vec<Vec<u8>> = self
            .net
            .claim_key_packages(&token, &peer)
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
        self.with_mls(|m, s| {
            m.confirm(&out.group_id).map_err(mls_err)?;
            let mut c = storage(s.contact(&peer))?.unwrap_or(Contact {
                account_id: peer.clone(),
                state: ContactState::Accepted,
                profile_key: None,
                display_name: None,
                username: None,
            });
            c.state = ContactState::Accepted;
            c.username.get_or_insert(username.clone());
            storage(s.save_contact(&c))?;
            storage(s.save_conversation(&Conversation {
                group_id: out.group_id.clone(),
                peer_account: peer.clone(),
            }))
        })?;
        self.share_profile_key(&out.group_id).await?;
        Ok(out.group_id)
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
        let token = self.token()?;
        let (payload, sealed, mut identified) = self.with_mls(|m, s| {
            let payload = m
                .encrypt(group_id, &content.encode_to_vec())
                .map_err(mls_err)?;
            let (mut sealed, mut identified) = (Vec::new(), Vec::new());
            for r in m.others(group_id).map_err(mls_err)? {
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
            Ok((payload, sealed, identified))
        })?;
        if !sealed.is_empty() {
            let (_revoked, rejected) = self.net.send_sealed(sealed, payload.clone()).await?;
            identified.extend(rejected);
        }
        // ponytail: revoked devices are reported but not yet removed from the group (ID-13, M3).
        if !identified.is_empty() {
            self.net
                .send_identified(&token, identified, payload)
                .await?;
        }
        Ok(())
    }

    /// Decrypts one queued payload and stores what it carries.
    fn handle(&self, payload: &[u8]) -> Result<Option<Handled>, CoreError> {
        let (read_receipts, typing) = (self.enabled(READ_RECEIPTS), self.enabled(TYPING));
        self.with_mls(|m, s| match m.receive(payload).map_err(mls_err)? {
            Received::Joined { group_id, members } => {
                let peer = members
                    .first()
                    .ok_or(CoreError::new("mls"))?
                    .account_id
                    .to_vec();
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
                        profile_key: None,
                        display_name: None,
                        username: None,
                    }))?;
                }
                storage(s.save_conversation(&Conversation {
                    group_id: group_id.clone(),
                    peer_account: peer.clone(),
                }))?;
                Ok(Some(Handled::Event(Event::ConversationStarted {
                    group_id,
                    peer_account: peer,
                    request: state != ContactState::Accepted,
                })))
            }
            Received::Message {
                group_id,
                sender,
                plaintext,
            } => {
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
                            state: ContactState::Request,
                            profile_key: None,
                            display_name: None,
                            username: None,
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
        let token = self.token()?;
        let _ = self.ensure_key_packages().await;
        let _ = self.publish_profile().await; // retries a publish that failed at registration
        let mut stream = self.net.stream(&token).await?;
        while let Some(frame) = stream.next().await? {
            match frame {
                Frame::Message { id, payload } => {
                    // ponytail: a payload that fails to process is acked and dropped so it
                    // can't block the queue; surface these once error reporting exists.
                    let handled = self.handle(&payload);
                    stream.ack(vec![id]).await?;
                    match handled {
                        Ok(Some(Handled::Event(e))) => on_event(e),
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
