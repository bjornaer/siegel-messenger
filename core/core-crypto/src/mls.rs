//! MLS (RFC 9420) through OpenMLS: every chat, 1:1 included, is an MLS group (CRY-01, CRY-03).
//! Sans-IO: callers move the returned bytes over the network; `P` supplies crypto, randomness
//! and storage, so group state persists wherever the provider keeps it.

use openmls::prelude::tls_codec::{Deserialize as _, Serialize as _};
use openmls::prelude::*;
pub use openmls_basic_credential::SignatureKeyPair;

use crate::{IdentityKey, verify_as_binding};

/// CRY-02: the RFC 9420 mandatory-to-implement suite.
pub const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
/// CRY-05: plaintext padded to the next 256-byte bucket.
const PADDING: usize = 256;
/// Late messages from a previous epoch stay decryptable this long after a commit.
const PAST_EPOCHS: usize = 3;

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

#[derive(Debug, PartialEq)]
pub enum Received {
    Joined {
        group_id: Vec<u8>,
        members: Vec<Member>,
    },
    Message {
        group_id: Vec<u8>,
        sender: Member,
        plaintext: Vec<u8>,
    },
    Commit {
        group_id: Vec<u8>,
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
                // Leaves must declare the last-resort extension or peers reject such KeyPackages.
                let caps = Capabilities::builder()
                    .extensions(vec![ExtensionType::LastResort])
                    .build();
                let mut b = KeyPackage::builder().leaf_node_capabilities(caps);
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

    fn create_config() -> MlsGroupCreateConfig {
        MlsGroupCreateConfig::builder()
            .ciphersuite(CIPHERSUITE)
            .use_ratchet_tree_extension(true) // the Welcome carries the tree; the server never sees it
            .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY) // CRY-04, GRP-03
            .padding_size(PADDING)
            .max_past_epochs(PAST_EPOCHS)
            .build()
    }

    fn join_config() -> MlsGroupJoinConfig {
        MlsGroupJoinConfig::builder()
            .use_ratchet_tree_extension(true)
            .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY)
            .padding_size(PADDING)
            .max_past_epochs(PAST_EPOCHS)
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

    /// Starts a group with the given KeyPackages (a 1:1 chat is the peer's devices, CRY-03).
    /// Every KeyPackage must carry a valid credential (CRY-08).
    pub fn create_group(&self, key_packages: &[Vec<u8>]) -> Result<Outgoing, Error> {
        let mut kps = Vec::new();
        let mut welcome_to = Vec::new();
        for b in key_packages {
            let kp = KeyPackageIn::tls_deserialize_exact(b)
                .map_err(err)?
                .validate(self.provider.crypto(), ProtocolVersion::Mls10)
                .map_err(err)?;
            let leaf = kp.leaf_node();
            welcome_to.push(member(
                leaf.credential(),
                leaf.signature_key().as_slice(),
                &self.as_pub,
            )?);
            kps.push(kp);
        }
        let mut g = MlsGroup::new(
            &self.provider,
            &self.signer,
            &Self::create_config(),
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
                let staged =
                    StagedWelcome::new_from_welcome(&self.provider, &Self::join_config(), w, None)
                        .map_err(err)?;
                let mut g = staged.into_group(&self.provider).map_err(err)?;
                let group_id = g.group_id().as_slice().to_vec();
                // CRY-08: every member must check out, or we leave without a trace.
                match self.others(&group_id) {
                    Ok(members) => Ok(Received::Joined { group_id, members }),
                    Err(e) => {
                        g.delete(self.provider.storage()).map_err(err)?;
                        Err(e)
                    }
                }
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
                        for add in c.add_proposals() {
                            let leaf = add.add_proposal().key_package().leaf_node();
                            member(
                                leaf.credential(),
                                leaf.signature_key().as_slice(),
                                &self.as_pub,
                            )?; // CRY-08
                        }
                        g.merge_staged_commit(&self.provider, *c).map_err(err)?;
                        Ok(Received::Commit { group_id })
                    }
                    ProcessedMessageContent::ProposalMessage(p) => {
                        g.store_pending_proposal(self.provider.storage(), *p)
                            .map_err(err)?;
                        Ok(Received::Ignored)
                    }
                    _ => Ok(Received::Ignored),
                }
            }
            _ => Ok(Received::Ignored),
        }
    }
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
        let out = alice.create_group(&kp).unwrap();
        assert_eq!((out.epoch, out.commit_to.len()), (0, 0));
        assert_eq!(out.welcome_to[0].account_id, [2; 16]);
        alice.confirm(&out.group_id).unwrap();

        let Received::Joined { group_id, members } = bob.receive(&out.welcome).unwrap() else {
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
                group_id: group_id.clone()
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
            alice.create_group(&kp).unwrap_err(),
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
}
