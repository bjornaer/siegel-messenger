//! MLS (RFC 9420) through OpenMLS: every chat, 1:1 included, is an MLS group (CRY-01, CRY-03).
//! Sans-IO: callers move the returned bytes over the network; `P` supplies crypto, randomness
//! and storage, so group state persists wherever the provider keeps it.

use openmls::prelude::tls_codec::{Deserialize as _, Serialize as _};
use openmls::prelude::*;
pub use openmls_basic_credential::SignatureKeyPair;

use crate::groups::{Account, GROUP_STATE_EXT, GroupState};
use crate::{IdentityKey, verify_as_binding};

/// Every leaf declares the extensions we use: last resort (CRY-09) and group state (GRP-02).
fn capabilities() -> Capabilities {
    Capabilities::builder()
        .extensions(vec![
            ExtensionType::LastResort,
            ExtensionType::Unknown(GROUP_STATE_EXT),
        ])
        .build()
}

/// CRY-02: the RFC 9420 mandatory-to-implement suite.
pub const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
/// CRY-05: plaintext padded to the next 256-byte bucket.
const PADDING: usize = 256;
/// Late messages from a previous epoch stay decryptable this long after a commit.
const PAST_EPOCHS: usize = 3;
/// Group receipts go only to the message's sender (GRP-13), so other members see gaps in each
/// sender's message counter; this many skipped messages are tolerated.
const MAX_FORWARD: u32 = 5000;

#[derive(Debug, Clone, PartialEq)]
pub struct Error(pub String);

fn err(e: impl std::fmt::Debug) -> Error {
    Error(format!("{e:?}"))
}

/// The identity inside our MLS BasicCredential (CRY-07, CRY-08): the device's account and ID,
/// the Account Identity public key, the identity key's signature over the device signing key,
/// and the Authentication Service's signature over (account, identity key).
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceCredential {
    pub account_id: [u8; 16],
    pub device_id: [u8; 16],
    pub identity_pub: [u8; 32],
    pub identity_sig: [u8; 64],
    pub as_sig: [u8; 64],
}

fn device_binding(account_id: &[u8; 16], device_id: &[u8; 16], signature_key: &[u8]) -> Vec<u8> {
    [
        b"siegel-device-v1".as_slice(),
        account_id,
        device_id,
        signature_key,
    ]
    .concat()
}

impl DeviceCredential {
    const LEN: usize = 16 + 16 + 32 + 64 + 64;

    pub fn issue(
        identity: &IdentityKey,
        account_id: [u8; 16],
        device_id: [u8; 16],
        signature_key: &[u8],
        as_sig: [u8; 64],
    ) -> Self {
        Self {
            account_id,
            device_id,
            identity_pub: identity.public(),
            identity_sig: identity.sign(&device_binding(&account_id, &device_id, signature_key)),
            as_sig,
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        [
            &self.account_id[..],
            &self.device_id,
            &self.identity_pub,
            &self.identity_sig,
            &self.as_sig,
        ]
        .concat()
    }

    pub fn decode(b: &[u8]) -> Option<Self> {
        if b.len() != Self::LEN {
            return None;
        }
        Some(Self {
            account_id: b[0..16].try_into().ok()?,
            device_id: b[16..32].try_into().ok()?,
            identity_pub: b[32..64].try_into().ok()?,
            identity_sig: b[64..128].try_into().ok()?,
            as_sig: b[128..192].try_into().ok()?,
        })
    }

    /// CRY-08: both signatures must hold before this device is accepted as a member.
    pub fn verify(&self, signature_key: &[u8], as_pub: &[u8; 32]) -> bool {
        let bound = IdentityKey::verify(
            &self.identity_pub,
            &device_binding(&self.account_id, &self.device_id, signature_key),
            &self.identity_sig,
        );
        bound && verify_as_binding(as_pub, &self.account_id, &self.identity_pub, &self.as_sig)
    }
}

/// A verified member device.
#[derive(Debug, Clone, PartialEq)]
pub struct Member {
    pub account_id: [u8; 16],
    pub device_id: [u8; 16],
    pub identity_pub: [u8; 32],
}

fn member(
    credential: &Credential,
    signature_key: &[u8],
    as_pub: &[u8; 32],
) -> Result<Member, Error> {
    let c = DeviceCredential::decode(credential.serialized_content())
        .ok_or(Error("credential_invalid".into()))?;
    if !c.verify(signature_key, as_pub) {
        return Err(Error("credential_invalid".into()));
    }
    Ok(Member {
        account_id: c.account_id,
        device_id: c.device_id,
        identity_pub: c.identity_pub,
    })
}

/// A commit to submit with Groups.Commit (CRY-14); merge it with `confirm` only once accepted.
#[derive(Debug)]
pub struct Outgoing {
    pub group_id: Vec<u8>,
    pub epoch: u64,
    pub commit: Vec<u8>,
    pub commit_to: Vec<Member>,
    pub welcome: Vec<u8>,
    pub welcome_to: Vec<Member>,
}

/// A membership or metadata change someone committed, for system lines (GRP-12).
#[derive(Debug, Clone, PartialEq)]
pub struct Change {
    pub by: Account,
    pub added: Vec<Account>,
    /// Removed by someone else.
    pub removed: Vec<Account>,
    /// Left on their own (GRP-10).
    pub left: Vec<Account>,
    pub old: GroupState,
    pub new: GroupState,
}

#[derive(Debug, PartialEq)]
pub enum Received {
    Joined {
        group_id: Vec<u8>,
        members: Vec<Member>,
        /// Who added us (GRP-11 decides between joining and an invite).
        adder: Option<Member>,
        /// None for a 1:1 chat.
        state: Option<GroupState>,
    },
    Message {
        group_id: Vec<u8>,
        sender: Member,
        plaintext: Vec<u8>,
    },
    Commit {
        group_id: Vec<u8>,
        change: Option<Change>,
    },
    /// We were removed from the group; it no longer accepts messages.
    Removed {
        group_id: Vec<u8>,
    },
    /// A proposal (a member leaving, GRP-10) waits for someone to commit it.
    Proposal {
        group_id: Vec<u8>,
    },
    /// GRP-07: a commit that breaks the group's rules was refused and not merged. The server
    /// still counted its epoch, so our next commit must account for it.
    Rejected {
        group_id: Vec<u8>,
        reason: String,
    },
    Ignored,
}

/// One device's MLS client.
pub struct Mls<P: OpenMlsProvider> {
    pub provider: P,
    signer: SignatureKeyPair,
    credential: CredentialWithKey,
    as_pub: [u8; 32],
}

impl<P: OpenMlsProvider> Mls<P> {
    /// Creates and stores a fresh device signing key (CRY-07).
    pub fn new_signer(provider: &P) -> Result<SignatureKeyPair, Error> {
        let s = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm()).map_err(err)?;
        s.store(provider.storage()).map_err(err)?;
        Ok(s)
    }

    /// Loads the device signing key stored by `new_signer`.
    pub fn load(
        provider: P,
        signer_pub: &[u8],
        credential: &DeviceCredential,
        as_pub: [u8; 32],
    ) -> Result<Self, Error> {
        let signer = SignatureKeyPair::read(
            provider.storage(),
            signer_pub,
            CIPHERSUITE.signature_algorithm(),
        )
        .ok_or(Error("signer_missing".into()))?;
        let credential = CredentialWithKey {
            credential: BasicCredential::new(credential.encode()).into(),
            signature_key: signer.public().into(),
        };
        Ok(Self {
            provider,
            signer,
            credential,
            as_pub,
        })
    }

    /// One-time KeyPackages (CRY-09), or the last-resort one.
    pub fn key_packages(&self, n: usize, last_resort: bool) -> Result<Vec<Vec<u8>>, Error> {
        (0..n)
            .map(|_| {
                let mut b = KeyPackage::builder().leaf_node_capabilities(capabilities());
                if last_resort {
                    b = b.mark_as_last_resort();
                }
                let bundle = b
                    .build(
                        CIPHERSUITE,
                        &self.provider,
                        &self.signer,
                        self.credential.clone(),
                    )
                    .map_err(err)?;
                bundle.key_package().tls_serialize_detached().map_err(err)
            })
            .collect()
    }

    fn create_config(state: Option<&GroupState>) -> MlsGroupCreateConfig {
        let mut b = MlsGroupCreateConfig::builder();
        if let Some(st) = state {
            // Members must support the state extension, so it can change by commit (GRP-02).
            let required = RequiredCapabilitiesExtension::new(
                &[ExtensionType::Unknown(GROUP_STATE_EXT)],
                &[],
                &[],
            );
            let exts = Extensions::from_vec(vec![
                Extension::Unknown(GROUP_STATE_EXT, UnknownExtension(st.encode())),
                Extension::RequiredCapabilities(required),
            ])
            .expect("valid group context extensions");
            b = b.with_group_context_extensions(exts);
        }
        b.capabilities(capabilities())
            .ciphersuite(CIPHERSUITE)
            .use_ratchet_tree_extension(true) // the Welcome carries the tree; the server never sees it
            .wire_format_policy(MIXED_CIPHERTEXT_WIRE_FORMAT_POLICY) // CRY-04: we send ciphertext only; joins by link (GRP-16) arrive as signed plaintext commits
            .padding_size(PADDING)
            .max_past_epochs(PAST_EPOCHS)
            .sender_ratchet_configuration(SenderRatchetConfiguration::new(5, MAX_FORWARD))
            .build()
    }

    fn join_config() -> MlsGroupJoinConfig {
        MlsGroupJoinConfig::builder()
            .use_ratchet_tree_extension(true)
            .wire_format_policy(MIXED_CIPHERTEXT_WIRE_FORMAT_POLICY)
            .padding_size(PADDING)
            .max_past_epochs(PAST_EPOCHS)
            .sender_ratchet_configuration(SenderRatchetConfiguration::new(5, MAX_FORWARD))
            .build()
    }

    fn group(&self, group_id: &[u8]) -> Result<MlsGroup, Error> {
        MlsGroup::load(self.provider.storage(), &GroupId::from_slice(group_id))
            .map_err(err)?
            .ok_or(Error("unknown_group".into()))
    }

    /// Other members' devices, the recipients of anything this device sends.
    pub fn others(&self, group_id: &[u8]) -> Result<Vec<Member>, Error> {
        let g = self.group(group_id)?;
        let me = g.own_leaf_index();
        g.members()
            .filter(|m| m.index != me)
            .map(|m| member(&m.credential, &m.signature_key, &self.as_pub))
            .collect()
    }

    /// Starts a group with the given KeyPackages (a 1:1 chat is the peer's devices, CRY-03;
    /// a group chat carries its state, GRP-01). Every KeyPackage must carry a valid credential
    /// (CRY-08).
    pub fn create_group(
        &self,
        key_packages: &[Vec<u8>],
        state: Option<&GroupState>,
    ) -> Result<Outgoing, Error> {
        let mut kps = Vec::new();
        let mut welcome_to = Vec::new();
        for b in key_packages {
            let kp = KeyPackageIn::tls_deserialize_exact(b)
                .map_err(err)?
                .validate(self.provider.crypto(), ProtocolVersion::Mls10)
                .map_err(err)?;
            let leaf = kp.leaf_node();
            if state.is_some() && !supports_groups(leaf) {
                return Err(Error("peer_outdated".into())); // an old app version: it must update
            }
            welcome_to.push(member(
                leaf.credential(),
                leaf.signature_key().as_slice(),
                &self.as_pub,
            )?);
            kps.push(kp);
        }
        // GRP-04: the creator is the first admin; the join order starts with the creator.
        let state = state.map(|st| {
            let mut joined = vec![self.me()];
            for m in &welcome_to {
                if !joined.contains(&m.account_id) {
                    joined.push(m.account_id);
                }
            }
            GroupState {
                admins: vec![self.me()],
                joined,
                ..st.clone()
            }
        });
        let mut g = MlsGroup::new(
            &self.provider,
            &self.signer,
            &Self::create_config(state.as_ref()),
            self.credential.clone(),
        )
        .map_err(err)?;
        let (commit, welcome, _) = g
            .add_members(&self.provider, &self.signer, &kps)
            .map_err(err)?;
        Ok(Outgoing {
            group_id: g.group_id().as_slice().to_vec(),
            epoch: 0,
            commit: commit.tls_serialize_detached().map_err(err)?,
            commit_to: vec![], // nobody else is in the group yet
            welcome: welcome.tls_serialize_detached().map_err(err)?,
            welcome_to,
        })
    }

    /// CRY-10: a commit that replaces this device's leaf keys, so a past key compromise stops
    /// reaching future messages. Submit like any commit, then `confirm` or `abort`.
    pub fn self_update(&self, group_id: &[u8]) -> Result<Outgoing, Error> {
        let mut g = self.group(group_id)?;
        let epoch = g.epoch().as_u64();
        let bundle = g
            .self_update(&self.provider, &self.signer, LeafNodeParameters::default())
            .map_err(err)?;
        Ok(Outgoing {
            group_id: group_id.to_vec(),
            epoch,
            commit: bundle.commit().tls_serialize_detached().map_err(err)?,
            commit_to: self.others(group_id)?,
            welcome: vec![],
            welcome_to: vec![],
        })
    }

    fn me(&self) -> Account {
        DeviceCredential::decode(self.credential.credential.serialized_content())
            .map(|c| c.account_id)
            .unwrap_or_default()
    }

    /// The group's state, or None for a 1:1 chat.
    pub fn state(&self, group_id: &[u8]) -> Result<Option<GroupState>, Error> {
        Ok(state_of(self.group(group_id)?.extensions()))
    }

    /// Every member device, this one included.
    pub fn roster(&self, group_id: &[u8]) -> Result<Vec<Member>, Error> {
        self.group(group_id)?
            .members()
            .map(|m| member(&m.credential, &m.signature_key, &self.as_pub))
            .collect()
    }

    /// One commit for any mix of changes (GRP-05, GRP-06, GRP-09): add the KeyPackages' devices,
    /// remove every device of the given accounts, apply `edit` (name, roles, settings), and
    /// commit pending proposals such as members leaving (GRP-10). The new state's join order is
    /// derived here, and the whole change must pass the same check receivers apply (GRP-07).
    pub fn commit(
        &self,
        group_id: &[u8],
        adds: &[Vec<u8>],
        remove: &[Account],
        edit: Option<GroupState>,
    ) -> Result<Outgoing, Error> {
        let mut g = self.group(group_id)?;
        let epoch = g.epoch().as_u64();
        let commit_to = self.others(group_id)?;
        let mut kps = Vec::new();
        let mut welcome_to = Vec::new();
        for b in adds {
            let kp = KeyPackageIn::tls_deserialize_exact(b)
                .map_err(err)?
                .validate(self.provider.crypto(), ProtocolVersion::Mls10)
                .map_err(err)?;
            let leaf = kp.leaf_node();
            if !supports_groups(leaf) {
                return Err(Error("peer_outdated".into()));
            }
            welcome_to.push(member(
                leaf.credential(),
                leaf.signature_key().as_slice(),
                &self.as_pub,
            )?);
            kps.push(kp);
        }
        let mut leaves = Vec::new();
        for m in g.members() {
            if remove.contains(&member(&m.credential, &m.signature_key, &self.as_pub)?.account_id) {
                leaves.push(m.index);
            }
        }
        let mut new_ext = None;
        if let Some(old) = state_of(g.extensions()) {
            // Pending leaves count as removals proposed by the leaver.
            let mut removed: Vec<(Account, Account)> = Vec::new();
            for p in g.pending_proposals() {
                if let (Proposal::Remove(r), Sender::Member(by)) = (p.proposal(), p.sender()) {
                    let gone = self.account_at(&g, r.removed())?;
                    removed.push((gone, self.account_at(&g, *by)?));
                }
            }
            removed.extend(remove.iter().map(|a| (*a, self.me())));
            // Like receivers: an account with a device left or rejoining hasn't left.
            let mut staying: Vec<Account> = welcome_to.iter().map(|m| m.account_id).collect();
            for m in g.members() {
                let a = member(&m.credential, &m.signature_key, &self.as_pub)?.account_id;
                let leaving = leaves.contains(&m.index)
                    || g.pending_proposals().any(
                        |p| matches!(p.proposal(), Proposal::Remove(r) if r.removed() == m.index),
                    );
                if !leaving {
                    staying.push(a);
                }
            }
            removed.retain(|(a, _)| !staying.contains(a));
            removed.dedup();
            let added = new_accounts(&g, &welcome_to, &self.as_pub)?;
            let gone: Vec<Account> = removed.iter().map(|(a, _)| *a).collect();
            let mut new = edit.unwrap_or(old.clone()).with_members(&added, &gone);
            // Members who joined by link go into the join order with this commit (GRP-16).
            let unlisted: Vec<Account> = staying
                .iter()
                .filter(|a| !old.joined.contains(a) && !added.contains(a))
                .copied()
                .fold(Vec::new(), |mut v, a| {
                    if !v.contains(&a) {
                        v.push(a);
                    }
                    v
                });
            for a in &unlisted {
                if !new.joined.contains(a) {
                    new.joined.push(*a);
                }
            }
            old.check(&self.me(), &added, &removed, &unlisted, &new)
                .map_err(|r| Error(r.0.into()))?;
            // A GroupContextExtensions proposal replaces the whole set: keep the others.
            let mut exts: Vec<Extension> = g
                .extensions()
                .iter()
                .filter(|e| e.extension_type() != ExtensionType::Unknown(GROUP_STATE_EXT))
                .cloned()
                .collect();
            exts.push(Extension::Unknown(
                GROUP_STATE_EXT,
                UnknownExtension(new.encode()),
            ));
            new_ext = Some(Extensions::from_vec(exts).map_err(err)?);
        }
        let mut b = g
            .commit_builder()
            .consume_proposal_store(true)
            .propose_adds(kps)
            .propose_removals(leaves);
        if let Some(e) = new_ext {
            b = b.propose_group_context_extensions(e).map_err(err)?;
        }
        let bundle = b
            .load_psks(self.provider.storage())
            .map_err(err)?
            .build(
                self.provider.rand(),
                self.provider.crypto(),
                &self.signer,
                |_| true,
            )
            .map_err(err)?
            .stage_commit(&self.provider)
            .map_err(err)?;
        let (commit, welcome, _) = bundle.into_contents();
        Ok(Outgoing {
            group_id: group_id.to_vec(),
            epoch,
            commit: commit.tls_serialize_detached().map_err(err)?,
            commit_to,
            welcome: match welcome {
                Some(w) => MlsMessageOut::from_welcome(w, ProtocolVersion::Mls10)
                    .tls_serialize_detached()
                    .map_err(err)?,
                None => vec![],
            },
            welcome_to,
        })
    }

    /// GRP-16: the group's current snapshot (GroupInfo with the tree and the external key) for an
    /// invite link. The caller encrypts it with the link key before it leaves the device.
    pub fn snapshot(&self, group_id: &[u8]) -> Result<Vec<u8>, Error> {
        self.group(group_id)?
            .export_group_info(self.provider.crypto(), &self.signer, true)
            .map_err(err)?
            .tls_serialize_detached()
            .map_err(err)
    }

    /// GRP-16: what a decrypted snapshot says about the group, without joining it: its state
    /// and how many accounts are in it. Unverified: for showing the name before joining only.
    pub fn peek(snapshot: &[u8]) -> Result<(GroupState, usize), Error> {
        let gi = group_info(snapshot)?;
        let st = state_of(gi.group_context().extensions()).ok_or(Error("not_a_group".into()))?;
        let n = st.joined.len();
        Ok((st, n))
    }

    /// GRP-16: joins a group by external commit from its snapshot, with the link's proof in the
    /// commit's authenticated data. Submit the commit; `forget` the group if it is refused.
    pub fn join_by_link(
        &self,
        snapshot: &[u8],
        invite_id: &[u8; 16],
        key: &[u8; 32],
    ) -> Result<Outgoing, Error> {
        let gi = group_info(snapshot)?;
        let epoch = gi.epoch().as_u64();
        let proof = crate::groups::Invite::proof(invite_id, key, &self.me(), epoch);
        // The returned group is already merged: if the server refuses the commit, `forget` it.
        let (g, bundle) = MlsGroup::external_commit_builder()
            .with_aad(proof)
            .with_config(Self::join_config())
            .build_group(&self.provider, gi, self.credential.clone())
            .map_err(err)?
            .leaf_node_parameters(
                LeafNodeParameters::builder()
                    .with_capabilities(capabilities())
                    .build(),
            )
            .load_psks(self.provider.storage())
            .map_err(err)?
            .build(
                self.provider.rand(),
                self.provider.crypto(),
                &self.signer,
                |_| true,
            )
            .map_err(err)?
            .finalize(&self.provider)
            .map_err(err)?;
        let (commit, _, _) = bundle.into_contents();
        let group_id = g.group_id().as_slice().to_vec();
        Ok(Outgoing {
            commit_to: self.others(&group_id)?,
            group_id,
            epoch,
            commit: commit.tls_serialize_detached().map_err(err)?,
            welcome: vec![],
            welcome_to: vec![],
        })
    }

    /// GRP-10: a proposal removing this device; another member commits it.
    pub fn leave(&self, group_id: &[u8]) -> Result<Vec<u8>, Error> {
        self.group(group_id)?
            .leave_group(&self.provider, &self.signer)
            .map_err(err)?
            .tls_serialize_detached()
            .map_err(err)
    }

    pub fn epoch(&self, group_id: &[u8]) -> Result<u64, Error> {
        Ok(self.group(group_id)?.epoch().as_u64())
    }

    /// Proposals waiting for a commit (GRP-10).
    pub fn has_pending_proposals(&self, group_id: &[u8]) -> Result<bool, Error> {
        Ok(self.group(group_id)?.pending_proposals().next().is_some())
    }

    fn account_at(&self, g: &MlsGroup, leaf: LeafNodeIndex) -> Result<Account, Error> {
        let m = g.member_at(leaf).ok_or(Error("unknown_sender".into()))?;
        Ok(member(&m.credential, &m.signature_key, &self.as_pub)?.account_id)
    }

    /// GRP-07: checks a received commit against the group's rules before it is merged.
    fn check_commit(
        &self,
        g: &MlsGroup,
        by: Account,
        c: &StagedCommit,
    ) -> Result<Option<Change>, Error> {
        let Some(old) = state_of(g.extensions()) else {
            return Ok(None); // 1:1 chats have no roles
        };
        let refused = |r: &str| Error(format!("unauthorized_commit:{r}"));
        let new = state_of(c.group_context().extensions()).ok_or(refused("state_missing"))?;
        let mut joining = Vec::new();
        for add in c.add_proposals() {
            let leaf = add.add_proposal().key_package().leaf_node();
            joining.push(member(
                leaf.credential(),
                leaf.signature_key().as_slice(),
                &self.as_pub,
            )?); // CRY-08
        }
        let added = new_accounts(g, &joining, &self.as_pub)?;
        // An account is gone once all of its devices are removed and none rejoins.
        let mut removed_leaves = Vec::new();
        let mut removed = Vec::new();
        for r in c.remove_proposals() {
            let leaf = r.remove_proposal().removed();
            removed_leaves.push(leaf);
            let proposer = match r.sender() {
                Sender::Member(i) => self.account_at(g, *i)?,
                _ => return Err(refused("external_remove")),
            };
            removed.push((self.account_at(g, leaf)?, proposer));
        }
        let mut staying = Vec::new();
        for m in g.members() {
            if !removed_leaves.contains(&m.index) {
                staying.push(member(&m.credential, &m.signature_key, &self.as_pub)?.account_id);
            }
        }
        staying.extend(joining.iter().map(|m| m.account_id));
        let unlisted: Vec<Account> = staying
            .iter()
            .filter(|a| !old.joined.contains(a) && !added.contains(a))
            .copied()
            .collect();
        removed.retain(|(a, _)| !staying.contains(a));
        removed.dedup();
        old.check(&by, &added, &removed, &unlisted, &new)
            .map_err(|r| refused(r.0))?;
        Ok(Some(Change {
            by,
            added,
            left: removed
                .iter()
                .filter(|(a, p)| a == p)
                .map(|(a, _)| *a)
                .collect(),
            removed: removed
                .iter()
                .filter(|(a, p)| a != p)
                .map(|(a, _)| *a)
                .collect(),
            old,
            new,
        }))
    }

    /// The server accepted our commit: apply it.
    pub fn confirm(&self, group_id: &[u8]) -> Result<(), Error> {
        self.group(group_id)?
            .merge_pending_commit(&self.provider)
            .map_err(err)
    }

    /// The server rejected our commit (epoch conflict): drop it; it can be rebuilt after the winner's.
    pub fn abort(&self, group_id: &[u8]) -> Result<(), Error> {
        self.group(group_id)?
            .clear_pending_commit(self.provider.storage())
            .map_err(err)
    }

    /// Forgets a group that was never accepted by the server (create_group lost the race).
    pub fn forget(&self, group_id: &[u8]) -> Result<(), Error> {
        self.group(group_id)?
            .delete(self.provider.storage())
            .map_err(err)
    }

    /// Encrypts an application message as an MLS PrivateMessage (CRY-04).
    pub fn encrypt(&self, group_id: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, Error> {
        let mut g = self.group(group_id)?;
        let msg = g
            .create_message(&self.provider, &self.signer, plaintext)
            .map_err(err)?;
        msg.tls_serialize_detached().map_err(err)
    }

    /// Processes anything from the queue: a Welcome, an application message or a commit.
    pub fn receive(&self, bytes: &[u8]) -> Result<Received, Error> {
        let msg = MlsMessageIn::tls_deserialize_exact(bytes).map_err(err)?;
        match msg.extract() {
            MlsMessageBodyIn::Welcome(w) => {
                let join =
                    StagedWelcome::build_from_welcome(&self.provider, &Self::join_config(), w)
                        .map_err(err)?;
                let gid = join
                    .processed_welcome()
                    .unverified_group_info()
                    .group_id()
                    .clone();
                // A Welcome into a group we already have: our copy fell behind (a commit we
                // couldn't read split us off) and an admin re-added us. See `repairs`.
                let stale = MlsGroup::load(self.provider.storage(), &gid).map_err(err)?;
                let join = if stale.is_some() {
                    join.replace_old_group()
                } else {
                    join
                };
                let staged = join.build().map_err(err)?;
                let adder = staged
                    .welcome_sender()
                    .ok()
                    .map(|l| member(l.credential(), l.signature_key().as_slice(), &self.as_pub));
                if let Some(old) = &stale {
                    let adder = adder.clone().transpose()?.map(|a| a.account_id);
                    let new = state_of(staged.group_context().extensions());
                    repairs(
                        old,
                        adder,
                        new.as_ref(),
                        &self.me(),
                        staged.group_context().epoch().as_u64(),
                    )
                    .map_err(|r| Error(format!("unauthorized_commit:{r}")))?;
                }
                let mut g = staged.into_group(&self.provider).map_err(err)?;
                let group_id = g.group_id().as_slice().to_vec();
                let state = state_of(g.extensions());
                // GRP-07: the join order must name exactly the members, or the roles can't be trusted.
                if let Some(st) = &state {
                    let mut accounts = Vec::new();
                    for m in self.roster(&group_id)? {
                        if !accounts.contains(&m.account_id) {
                            accounts.push(m.account_id);
                        }
                    }
                    let mut joined = st.joined.clone();
                    joined.sort();
                    accounts.sort();
                    if joined != accounts {
                        g.delete(self.provider.storage()).map_err(err)?;
                        return Err(Error("unauthorized_commit:state_mismatch".into()));
                    }
                }
                // CRY-08: every member must check out, or we leave without a trace.
                match (self.others(&group_id), adder.transpose()) {
                    (Ok(members), Ok(adder)) => Ok(Received::Joined {
                        group_id,
                        members,
                        adder,
                        state,
                    }),
                    (Err(e), _) | (_, Err(e)) => {
                        g.delete(self.provider.storage()).map_err(err)?;
                        Err(e)
                    }
                }
            }
            // GRP-16: someone joining by link. External commits are signed plaintext; members
            // send everything else encrypted, so other plaintext is ignored.
            MlsMessageBodyIn::PublicMessage(pm) => {
                let pm: ProtocolMessage = pm.into();
                let group_id = pm.group_id().as_slice().to_vec();
                let mut g = self.group(&group_id)?;
                if g.configuration().wire_format_policy() != MIXED_CIPHERTEXT_WIRE_FORMAT_POLICY {
                    // Groups from before invite links only accepted ciphertext.
                    g.set_configuration(self.provider.storage(), &Self::join_config())
                        .map_err(err)?;
                }
                let epoch = g.epoch().as_u64();
                let processed = g.process_message(&self.provider, pm).map_err(err)?;
                if !matches!(processed.sender(), Sender::NewMemberCommit) {
                    return Ok(Received::Ignored);
                }
                let proof = processed.aad().to_vec();
                let ProcessedMessageContent::StagedCommitMessage(c) = processed.into_content()
                else {
                    return Ok(Received::Ignored);
                };
                let leaf = c
                    .update_path_leaf_node()
                    .ok_or(Error("unknown_sender".into()))?;
                let joiner = member(
                    leaf.credential(),
                    leaf.signature_key().as_slice(),
                    &self.as_pub,
                )?;
                let rejected = |r: &str| Received::Rejected {
                    group_id: group_id.clone(),
                    reason: format!("unauthorized_commit:{r}"),
                };
                let Some(old) = state_of(g.extensions()) else {
                    return Ok(rejected("no_links_in_direct_chats"));
                };
                // A join adds the joiner and nothing else (a resync may drop their old leaf).
                let mut others_removed = false;
                for r in c.remove_proposals() {
                    others_removed |=
                        self.account_at(&g, r.remove_proposal().removed())? != joiner.account_id;
                }
                if c.add_proposals().next().is_some() || others_removed {
                    return Ok(rejected("join_does_more"));
                }
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_or(0, |d| d.as_secs());
                if let Err(r) = old.check_join(&joiner.account_id, &proof, epoch, now) {
                    return Ok(rejected(r.0));
                }
                g.merge_staged_commit(&self.provider, *c).map_err(err)?;
                Ok(Received::Commit {
                    group_id,
                    change: Some(Change {
                        by: joiner.account_id,
                        added: vec![joiner.account_id],
                        removed: vec![],
                        left: vec![],
                        new: old.clone(),
                        old,
                    }),
                })
            }
            MlsMessageBodyIn::PrivateMessage(pm) => {
                let pm: ProtocolMessage = pm.into();
                let group_id = pm.group_id().as_slice().to_vec();
                let mut g = self.group(&group_id)?;
                let processed = g.process_message(&self.provider, pm).map_err(err)?;
                let sender_index = match processed.sender() {
                    Sender::Member(i) => *i,
                    _ => return Ok(Received::Ignored),
                };
                let sender_key = g
                    .member_at(sender_index)
                    .ok_or(Error("unknown_sender".into()))?
                    .signature_key;
                let sender = member(processed.credential(), &sender_key, &self.as_pub)?;
                match processed.into_content() {
                    ProcessedMessageContent::ApplicationMessage(m) => Ok(Received::Message {
                        group_id,
                        sender,
                        plaintext: m.into_bytes(),
                    }),
                    ProcessedMessageContent::StagedCommitMessage(c) => {
                        let change = match self.check_commit(&g, sender.account_id, &c) {
                            Err(Error(r)) if r.starts_with("unauthorized_commit") => {
                                return Ok(Received::Rejected {
                                    group_id,
                                    reason: r,
                                });
                            }
                            r => r?,
                        };
                        let removed = c.self_removed();
                        g.merge_staged_commit(&self.provider, *c).map_err(err)?;
                        Ok(if removed {
                            Received::Removed { group_id }
                        } else {
                            Received::Commit { group_id, change }
                        })
                    }
                    ProcessedMessageContent::ProposalMessage(p) => {
                        // Only members leaving: anything else must come inline with a commit.
                        let own = match (p.proposal(), p.sender()) {
                            (Proposal::Remove(r), Sender::Member(by)) => r.removed() == *by,
                            _ => false,
                        };
                        if !own {
                            return Ok(Received::Ignored);
                        }
                        g.store_pending_proposal(self.provider.storage(), *p)
                            .map_err(err)?;
                        Ok(Received::Proposal { group_id })
                    }
                    _ => Ok(Received::Ignored),
                }
            }
            _ => Ok(Received::Ignored),
        }
    }
}

/// Leaves from app versions before group chats can't join a group (GRP-02).
fn supports_groups(leaf: &LeafNode) -> bool {
    leaf.capabilities()
        .extensions()
        .contains(&ExtensionType::Unknown(GROUP_STATE_EXT))
}

fn group_info(
    snapshot: &[u8],
) -> Result<openmls::messages::group_info::VerifiableGroupInfo, Error> {
    match MlsMessageIn::tls_deserialize_exact(snapshot)
        .map_err(err)?
        .extract()
    {
        MlsMessageBodyIn::GroupInfo(gi) => Ok(gi),
        _ => Err(Error("not_a_snapshot".into())),
    }
}

/// Whether a Welcome may replace our copy of a group: only a later epoch of the same group,
/// sent by an admin of our copy, that still has us in it. Anyone can make a group with a known
/// ID, so without these checks a stranger, or any member, could swap the group for their own.
fn repairs(
    old: &MlsGroup,
    adder: Option<Account>,
    new: Option<&GroupState>,
    me: &Account,
    epoch: u64,
) -> Result<(), &'static str> {
    let old_state = state_of(old.extensions()).ok_or("not_a_group")?;
    let new = new.ok_or("state_missing")?;
    match adder {
        _ if epoch <= old.epoch().as_u64() => Err("stale_welcome"),
        Some(a) if old_state.effective_admins().contains(&a) && new.joined.contains(me) => Ok(()),
        _ => Err("repair_not_allowed"),
    }
}

fn state_of(e: &Extensions<GroupContext>) -> Option<GroupState> {
    GroupState::decode(&e.unknown(GROUP_STATE_EXT)?.0)
}

/// Accounts among `joining` that aren't in the group yet (a new device of a member isn't new).
fn new_accounts(
    g: &MlsGroup,
    joining: &[Member],
    as_pub: &[u8; 32],
) -> Result<Vec<Account>, Error> {
    let mut present = Vec::new();
    for m in g.members() {
        present.push(member(&m.credential, &m.signature_key, as_pub)?.account_id);
    }
    let mut out: Vec<Account> = Vec::new();
    for m in joining {
        if !present.contains(&m.account_id) && !out.contains(&m.account_id) {
            out.push(m.account_id);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use openmls_rust_crypto::OpenMlsRustCrypto;

    fn device(as_key: &IdentityKey, n: u8, forge_as: bool) -> Mls<OpenMlsRustCrypto> {
        let provider = OpenMlsRustCrypto::default();
        let signer = Mls::new_signer(&provider).unwrap();
        let id = IdentityKey::generate();
        let (account, dev) = ([n; 16], [n + 100; 16]);
        let as_signer = if forge_as {
            IdentityKey::generate()
        } else {
            IdentityKey::from_bytes(&as_key.to_bytes())
        };
        let as_sig = as_signer.sign(&[b"siegel-as-v1".as_slice(), &account, &id.public()].concat());
        let cred = DeviceCredential::issue(&id, account, dev, signer.public(), as_sig);
        assert_eq!(DeviceCredential::decode(&cred.encode()), Some(cred.clone()));
        Mls::load(provider, signer.public(), &cred, as_key.public()).unwrap()
    }

    #[test]
    fn one_to_one_chat() {
        let as_key = IdentityKey::generate();
        let (alice, bob) = (device(&as_key, 1, false), device(&as_key, 2, false));

        let kp = bob.key_packages(1, false).unwrap();
        let out = alice.create_group(&kp, None).unwrap();
        assert_eq!((out.epoch, out.commit_to.len()), (0, 0));
        assert_eq!(out.welcome_to[0].account_id, [2; 16]);
        alice.confirm(&out.group_id).unwrap();

        let Received::Joined {
            group_id, members, ..
        } = bob.receive(&out.welcome).unwrap()
        else {
            panic!("join")
        };
        assert_eq!(
            (group_id.as_slice(), members[0].account_id),
            (out.group_id.as_slice(), [1; 16])
        );

        let short = alice.encrypt(&group_id, b"hi").unwrap();
        let long = alice.encrypt(&group_id, &[b'x'; 100]).unwrap();
        let longer = alice.encrypt(&group_id, &[b'x'; 200]).unwrap();
        assert_eq!(
            short.len(),
            long.len(),
            "CRY-05: lengths hidden within a 256-byte bucket"
        );
        assert_eq!(longer.len() - long.len(), 256, "CRY-05: next bucket");
        assert!(!short.windows(2).any(|w| w == b"hi"), "ciphertext only");

        let Received::Message {
            sender, plaintext, ..
        } = bob.receive(&short).unwrap()
        else {
            panic!("message")
        };
        assert_eq!(
            (sender.account_id, plaintext.as_slice()),
            ([1; 16], &b"hi"[..])
        );
        bob.receive(&long).unwrap();
        bob.receive(&longer).unwrap();

        let reply = bob.encrypt(&group_id, b"hello back").unwrap();
        let Received::Message {
            sender, plaintext, ..
        } = alice.receive(&reply).unwrap()
        else {
            panic!("reply")
        };
        assert_eq!(
            (sender.account_id, plaintext.as_slice()),
            ([2; 16], &b"hello back"[..])
        );
        assert_eq!(alice.others(&group_id).unwrap()[0].device_id, [102; 16]);

        // CRY-10: Bob refreshes his keys; a message Alice sent in the old epoch still opens.
        let in_flight = alice.encrypt(&group_id, b"in flight").unwrap();
        let up = bob.self_update(&group_id).unwrap();
        assert_eq!((up.epoch, up.commit_to[0].account_id), (1, [1; 16]));
        bob.confirm(&group_id).unwrap();
        assert_eq!(
            alice.receive(&up.commit).unwrap(),
            Received::Commit {
                group_id: group_id.clone(),
                change: None
            }
        );
        assert!(matches!(
            bob.receive(&in_flight).unwrap(),
            Received::Message { .. }
        ));
        let after = bob.encrypt(&group_id, b"after").unwrap();
        assert!(matches!(
            alice.receive(&after).unwrap(),
            Received::Message { .. }
        ));
    }

    #[test]
    fn rejects_credentials_without_a_valid_as_signature() {
        let as_key = IdentityKey::generate();
        let alice = device(&as_key, 1, false);
        let mallory = device(&as_key, 3, true); // identity key not bound by our AS (CRY-08)
        let kp = mallory.key_packages(1, false).unwrap();
        assert_eq!(
            alice.create_group(&kp, None).unwrap_err(),
            Error("credential_invalid".into())
        );
    }

    #[test]
    fn last_resort_key_packages() {
        let as_key = IdentityKey::generate();
        let bob = device(&as_key, 2, false);
        let lr = bob.key_packages(1, true).unwrap();
        let kp = KeyPackageIn::tls_deserialize_exact(&lr[0])
            .unwrap()
            .validate(bob.provider.crypto(), ProtocolVersion::Mls10)
            .unwrap();
        assert!(kp.last_resort());
    }

    #[test]
    fn groups_roles_leaving_and_malicious_commits() {
        // GRP-01..10, AC-10.
        let as_key = IdentityKey::generate();
        let (a, b, c, d) = (
            device(&as_key, 1, false),
            device(&as_key, 2, false),
            device(&as_key, 3, false),
            device(&as_key, 4, false),
        );
        let kps: Vec<_> = [&b, &c]
            .iter()
            .flat_map(|m| m.key_packages(1, false).unwrap())
            .collect();
        let init = GroupState {
            name: "Hikers".into(),
            admins_only_info: true,
            admins_only_add: true,
            ..Default::default()
        };
        let out = a.create_group(&kps, Some(&init)).unwrap();
        a.confirm(&out.group_id).unwrap();
        let gid = out.group_id.clone();
        for m in [&b, &c] {
            let Received::Joined { state, adder, .. } = m.receive(&out.welcome).unwrap() else {
                panic!("join")
            };
            let st = state.unwrap();
            assert_eq!(
                (st.name.as_str(), st.admins.clone()),
                ("Hikers", vec![[1; 16]])
            );
            assert_eq!(st.joined, vec![[1; 16], [2; 16], [3; 16]]);
            assert_eq!(adder.unwrap().account_id, [1; 16]);
        }

        // AC-10: B is no admin; its own client refuses, and a hand-built commit is rejected by all.
        assert!(
            b.commit(&gid, &[], &[[3; 16]], None)
                .unwrap_err()
                .0
                .contains("remove_not_allowed")
        );
        let mut g = b.group(&gid).unwrap();
        let leaf = g
            .members()
            .find(|m| b.account_at(&g, m.index).unwrap() == [3; 16])
            .unwrap()
            .index;
        let (evil, _, _) = g
            .commit_builder()
            .propose_removals([leaf])
            .load_psks(b.provider.storage())
            .unwrap()
            .build(b.provider.rand(), b.provider.crypto(), &b.signer, |_| true)
            .unwrap()
            .stage_commit(&b.provider)
            .unwrap()
            .into_contents();
        let evil = evil.tls_serialize_detached().unwrap();
        for m in [&a, &c] {
            assert!(matches!(
                m.receive(&evil).unwrap(),
                Received::Rejected { .. }
            ));
        }
        g.clear_pending_commit(b.provider.storage()).unwrap();

        // The admin adds D; everyone sees who did what (GRP-09, GRP-12).
        let add = a
            .commit(&gid, &d.key_packages(1, false).unwrap(), &[], None)
            .unwrap();
        a.confirm(&gid).unwrap();
        for m in [&b, &c] {
            let Received::Commit {
                change: Some(ch), ..
            } = m.receive(&add.commit).unwrap()
            else {
                panic!("commit")
            };
            assert_eq!((ch.by, ch.added.clone()), ([1; 16], vec![[4; 16]]));
        }
        assert!(matches!(
            d.receive(&add.welcome).unwrap(),
            Received::Joined { .. }
        ));

        // GRP-10: C leaves by proposal; B, no admin, may commit it.
        let bye = c.leave(&gid).unwrap();
        for m in [&a, &b, &d] {
            assert_eq!(
                m.receive(&bye).unwrap(),
                Received::Proposal {
                    group_id: gid.clone()
                }
            );
        }
        let out = b.commit(&gid, &[], &[], None).unwrap();
        b.confirm(&gid).unwrap();
        for m in [&a, &d] {
            let Received::Commit {
                change: Some(ch), ..
            } = m.receive(&out.commit).unwrap()
            else {
                panic!("leave commit")
            };
            assert_eq!(
                (ch.left.clone(), ch.removed.clone()),
                (vec![[3; 16]], vec![])
            );
        }
        assert_eq!(
            c.receive(&out.commit).unwrap(),
            Received::Removed {
                group_id: gid.clone()
            }
        );

        // GRP-08: the only admin leaves; B, longest-standing, may now rename.
        let bye = a.leave(&gid).unwrap();
        for m in [&b, &d] {
            m.receive(&bye).unwrap();
        }
        let out = d.commit(&gid, &[], &[], None).unwrap();
        d.confirm(&gid).unwrap();
        b.receive(&out.commit).unwrap();
        let st = b.state(&gid).unwrap().unwrap();
        assert_eq!(st.effective_admins(), vec![[2; 16]]);
        let renamed = GroupState {
            name: "Hikers 2026".into(),
            ..st.clone()
        };
        assert!(
            d.commit(&gid, &[], &[], Some(renamed.clone()))
                .unwrap_err()
                .0
                .contains("rename")
        );
        let out = b.commit(&gid, &[], &[], Some(renamed)).unwrap();
        b.confirm(&gid).unwrap();
        d.receive(&out.commit).unwrap();
        assert_eq!(d.state(&gid).unwrap().unwrap().name, "Hikers 2026");
    }

    #[test]
    fn an_admin_repairs_a_split_off_member() {
        // B missed a commit (an older app refused it), so its copy fell behind for good. The admin
        // removes and re-adds B; B's Welcome replaces the stale copy.
        let as_key = IdentityKey::generate();
        let (a, b, c) = (
            device(&as_key, 1, false),
            device(&as_key, 2, false),
            device(&as_key, 3, false),
        );
        let kps: Vec<_> = [&b, &c]
            .iter()
            .flat_map(|m| m.key_packages(1, false).unwrap())
            .collect();
        let out = a.create_group(&kps, Some(&GroupState::default())).unwrap();
        a.confirm(&out.group_id).unwrap();
        let gid = out.group_id.clone();
        for m in [&b, &c] {
            m.receive(&out.welcome).unwrap();
        }
        let rename = |st: GroupState| GroupState {
            name: "Hikers".into(),
            ..st
        };
        let st = a.state(&gid).unwrap().unwrap();
        let missed = a.commit(&gid, &[], &[], Some(rename(st))).unwrap();
        a.confirm(&gid).unwrap();
        c.receive(&missed.commit).unwrap(); // B never sees it

        // Only an admin of B's own copy may replace it.
        let old = b.group(&gid).unwrap();
        let mut st = b.state(&gid).unwrap().unwrap();
        st.joined.push([2; 16]);
        assert_eq!(
            repairs(&old, Some([3; 16]), Some(&st), &[2; 16], 9),
            Err("repair_not_allowed")
        );
        assert_eq!(
            repairs(&old, Some([1; 16]), Some(&st), &[2; 16], 0),
            Err("stale_welcome")
        );

        a.commit(&gid, &[], &[[2; 16]], None).unwrap();
        a.confirm(&gid).unwrap();
        let readd = a
            .commit(&gid, &b.key_packages(1, false).unwrap(), &[], None)
            .unwrap();
        a.confirm(&gid).unwrap();
        let Received::Joined { state, .. } = b.receive(&readd.welcome).unwrap() else {
            panic!("rejoin")
        };
        assert_eq!(state.unwrap().name, "Hikers");
        let hi = a.encrypt(&gid, b"back").unwrap();
        let Received::Message { plaintext, .. } = b.receive(&hi).unwrap() else {
            panic!("message")
        };
        assert_eq!(plaintext, b"back");
    }

    #[test]
    fn joining_by_invite_link() {
        // GRP-16: an outsider joins with the link alone; members check the proof.
        let as_key = IdentityKey::generate();
        let (a, b, d, e) = (
            device(&as_key, 1, false),
            device(&as_key, 2, false),
            device(&as_key, 4, false),
            device(&as_key, 5, false),
        );
        let init = GroupState {
            name: "Climbers".into(),
            admins_only_info: true,
            admins_only_add: true,
            ..Default::default()
        };
        let out = a
            .create_group(&b.key_packages(1, false).unwrap(), Some(&init))
            .unwrap();
        a.confirm(&out.group_id).unwrap();
        let gid = out.group_id.clone();
        b.receive(&out.welcome).unwrap();

        let invite = crate::groups::Invite {
            id: [7; 16],
            key: [8; 32],
            write_key: [9; 16],
            expires: u64::MAX,
            by: [1; 16],
        };
        let st = a.state(&gid).unwrap().unwrap();
        let out = a
            .commit(
                &gid,
                &[],
                &[],
                Some(GroupState {
                    invites: vec![invite.clone()],
                    ..st
                }),
            )
            .unwrap();
        a.confirm(&gid).unwrap();
        b.receive(&out.commit).unwrap();

        let snap = a.snapshot(&gid).unwrap();
        let (peek, n) = Mls::<OpenMlsRustCrypto>::peek(&snap).unwrap();
        assert_eq!((peek.name.as_str(), n), ("Climbers", 2));

        // A wrong key is refused by every member; the group stays as it was.
        let forged = e.join_by_link(&snap, &invite.id, &[0; 32]).unwrap();
        assert!(matches!(
            b.receive(&forged.commit).unwrap(),
            Received::Rejected { .. }
        ));

        let join = d.join_by_link(&snap, &invite.id, &invite.key).unwrap();
        assert_eq!(join.commit_to.len(), 2);
        for m in [&a, &b] {
            let Received::Commit {
                change: Some(ch), ..
            } = m.receive(&join.commit).unwrap()
            else {
                panic!("join")
            };
            assert_eq!(ch.added, vec![[4; 16]]);
        }
        let hello = d.encrypt(&gid, b"hi all").unwrap();
        assert!(matches!(
            a.receive(&hello).unwrap(),
            Received::Message { .. }
        ));

        // The next commit puts the newcomer into the join order.
        let out = b.commit(&gid, &[], &[], None).unwrap();
        b.confirm(&gid).unwrap();
        a.receive(&out.commit).unwrap();
        d.receive(&out.commit).unwrap();
        assert_eq!(
            a.state(&gid).unwrap().unwrap().joined,
            vec![[1; 16], [2; 16], [4; 16]]
        );
    }
}
