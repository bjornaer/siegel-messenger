//! 1:1 messaging over MLS (M2): KeyPackages, chat creation, sending, and the receive stream.

use std::time::{SystemTime, UNIX_EPOCH};

use core_crypto::mls::{DeviceCredential, Member, Mls, Received};
use core_net::{Frame, pb};
use core_store::{Conversation, Message, MlsStorage, SqlCipher, Store};
use openmls_rust_crypto::RustCrypto;
use openmls_traits::OpenMlsProvider;
use prost::Message as _;

use crate::{ACCOUNT, AS_PUBLIC, CREDENTIAL, CoreError, SIGNER, SiegelCore, storage};

/// CRY-09: keep about this many one-time KeyPackages on the server; refill below the threshold.
const KEY_PACKAGES: u32 = 100;
const REFILL_BELOW: u32 = 20;
/// MSG-05.
const MAX_TEXT: usize = 64 * 1024;

/// OpenMLS provider over the encrypted store: RustCrypto for crypto and randomness.
struct Provider<'a> {
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

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Something that happened on the stream, for the UI.
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    /// Someone started a chat with us.
    ConversationStarted {
        group_id: Vec<u8>,
        peer_account: Vec<u8>,
    },
    Message(ChatMessage),
    /// This device was revoked or the account deleted; local data is already wiped (ID-12).
    Deregistered,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ChatMessage {
    pub group_id: Vec<u8>,
    pub message_id: Vec<u8>,
    pub sender_account: Vec<u8>,
    /// Sender clock (MSG-03: shown, not used for ordering).
    pub sent_at: i64,
    pub text: String,
    pub outgoing: bool,
}

fn chat_message(m: Message) -> Option<ChatMessage> {
    let c = pb::Content::decode(m.body.as_slice()).ok()?;
    let Some(pb::content::Body::Text(t)) = c.body else {
        return None;
    }; // unknown types skipped (MSG-01)
    Some(ChatMessage {
        group_id: m.group_id,
        message_id: m.message_id,
        sender_account: m.sender_account,
        sent_at: m.sent_at,
        text: t.body,
        outgoing: m.outgoing,
    })
}

impl SiegelCore {
    /// Runs `f` with this device's MLS client while holding the store lock (never across awaits).
    fn with_mls<R>(
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
    pub async fn start_chat(&self, username: &str) -> Result<Vec<u8>, CoreError> {
        let token = self.token()?;
        let peer = self.lookup_username(username).await?;
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
        match self.net.commit(&token, req).await {
            Ok(_) => self.with_mls(|m, s| {
                m.confirm(&out.group_id).map_err(mls_err)?;
                storage(s.save_conversation(&Conversation {
                    group_id: out.group_id.clone(),
                    peer_account: peer.clone(),
                }))
            })?,
            Err(e) => {
                let _ = self.with_mls(|m, _| m.forget(&out.group_id).map_err(mls_err));
                return Err(e.into());
            }
        }
        Ok(out.group_id)
    }

    pub fn conversations(&self) -> Result<Vec<Conversation>, CoreError> {
        match self.store.lock().unwrap().as_ref() {
            Some(s) => storage(s.conversations()),
            None => Err(CoreError::new("wiped")),
        }
    }

    /// The newest `limit` messages of a conversation, oldest first.
    pub fn messages(&self, group_id: &[u8], limit: u32) -> Result<Vec<ChatMessage>, CoreError> {
        match self.store.lock().unwrap().as_ref() {
            Some(s) => Ok(storage(s.messages(group_id, limit))?
                .into_iter()
                .filter_map(chat_message)
                .collect()),
            None => Err(CoreError::new("wiped")),
        }
    }

    /// Encrypts and sends a text message (MSG-05). Returns the stored message.
    pub async fn send_text(&self, group_id: &[u8], text: &str) -> Result<ChatMessage, CoreError> {
        if text.is_empty() || text.len() > MAX_TEXT {
            return Err(CoreError::new("text_invalid"));
        }
        let token = self.token()?;
        let content = pb::Content {
            message_id: uuid::Uuid::now_v7().as_bytes().to_vec(), // MSG-01
            sent_at: now_ms(),
            body: Some(pb::content::Body::Text(pb::Text { body: text.into() })),
        };
        let (payload, recipients, me) = self.with_mls(|m, s| {
            let payload = m
                .encrypt(group_id, &content.encode_to_vec())
                .map_err(mls_err)?;
            let me = storage(s.get(ACCOUNT))?.ok_or(CoreError::new("not_registered"))?;
            Ok((payload, m.others(group_id).map_err(mls_err)?, me))
        })?;
        // ponytail: revoked devices are reported but not yet removed from the group (ID-13, M3).
        self.net
            .send_identified(&token, recipients.iter().map(addr).collect(), payload)
            .await?;
        let msg = Message {
            message_id: content.message_id.clone(),
            group_id: group_id.to_vec(),
            sender_account: me,
            sent_at: content.sent_at,
            body: content.encode_to_vec(),
            outgoing: true,
        };
        self.with_mls(|_, s| storage(s.save_message(&msg)))?;
        chat_message(msg).ok_or(CoreError::new("storage"))
    }

    /// Decrypts one queued payload and stores what it carries.
    fn handle(&self, payload: &[u8]) -> Result<Option<Event>, CoreError> {
        self.with_mls(|m, s| match m.receive(payload).map_err(mls_err)? {
            Received::Joined { group_id, members } => {
                let peer = members
                    .first()
                    .ok_or(CoreError::new("mls"))?
                    .account_id
                    .to_vec();
                storage(s.save_conversation(&Conversation {
                    group_id: group_id.clone(),
                    peer_account: peer.clone(),
                }))?;
                Ok(Some(Event::ConversationStarted {
                    group_id,
                    peer_account: peer,
                }))
            }
            Received::Message {
                group_id,
                sender,
                plaintext,
            } => {
                let Ok(c) = pb::Content::decode(plaintext.as_slice()) else {
                    return Ok(None);
                };
                let msg = Message {
                    message_id: c.message_id.clone(),
                    group_id,
                    sender_account: sender.account_id.to_vec(),
                    sent_at: c.sent_at,
                    body: plaintext,
                    outgoing: false,
                };
                // MSG-03: a redelivered message (same ID) is dropped here.
                if !storage(s.save_message(&msg))? {
                    return Ok(None);
                }
                Ok(chat_message(msg).map(Event::Message))
            }
            Received::Commit { .. } | Received::Ignored => Ok(None),
        })
    }

    /// Connects the message stream and processes it until it closes or the device is
    /// deregistered. Call again (with backoff) to reconnect.
    pub async fn run_stream(&self, on_event: impl Fn(Event) + Send) -> Result<(), CoreError> {
        let token = self.token()?;
        let _ = self.ensure_key_packages().await;
        let mut stream = self.net.stream(&token).await?;
        while let Some(frame) = stream.next().await? {
            match frame {
                Frame::Message { id, payload } => {
                    // ponytail: a payload that fails to process is acked and dropped so it
                    // can't block the queue; surface these once error reporting exists.
                    if let Ok(Some(e)) = self.handle(&payload) {
                        on_event(e);
                    }
                    stream.ack(vec![id]).await?;
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
