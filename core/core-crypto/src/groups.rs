//! Group metadata (GRP-02) and the permission rules every member enforces (GRP-04..08).
//! The state rides in an MLS GroupContext extension, so the server never sees it (GRP-03) and
//! each change is a commit that all members check before merging (GRP-07).

pub type Account = [u8; 16];

/// GroupContext extension type for [`GroupState`] (private-use range).
pub const GROUP_STATE_EXT: u16 = 0xF5A1;

/// What a group is, beyond its members' keys.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct GroupState {
    /// GRP-01: 1 to 64 characters.
    pub name: String,
    /// GRP-04: admins by account; see [`GroupState::effective_admins`].
    pub admins: Vec<Account>,
    /// GRP-06 "Who can edit name and avatar": admins only (default) or everyone.
    pub admins_only_info: bool,
    /// GRP-06 "Who can add members": admins only (default) or everyone.
    pub admins_only_add: bool,
    /// Members in the order they joined, for GRP-08.
    pub joined: Vec<Account>,
    /// GRP-16: live invite links. Members hold the keys, so every member can check a joiner.
    pub invites: Vec<Invite>,
}

/// One group invite link (GRP-16): `/g/<id>#<key>`.
#[derive(Debug, Clone, PartialEq)]
pub struct Invite {
    pub id: [u8; 16],
    /// In the link only: decrypts the group snapshot and proves a joiner had the link.
    pub key: [u8; 32],
    /// Lets members, and nobody holding just the link, update the snapshot on the server.
    pub write_key: [u8; 16],
    /// Unix seconds.
    pub expires: u64,
    pub by: Account,
}

impl Invite {
    const LEN: usize = 16 + 32 + 16 + 8 + 16;

    fn snapshot_cipher(key: &[u8; 32]) -> aes_gcm::Aes256Gcm {
        use aes_gcm::KeyInit;
        let mut k = [0u8; 32];
        hkdf::Hkdf::<sha2::Sha256>::new(None, key)
            .expand(b"siegel-invite-snapshot-v1", &mut k)
            .expect("32 bytes");
        aes_gcm::Aes256Gcm::new(&k.into())
    }

    /// The group snapshot as the server stores it: readable only with the link key.
    pub fn seal(key: &[u8; 32], snapshot: &[u8]) -> Vec<u8> {
        use aes_gcm::aead::{Aead, AeadCore};
        let nonce = aes_gcm::Aes256Gcm::generate_nonce(&mut rand_core::OsRng);
        let ct = Self::snapshot_cipher(key)
            .encrypt(&nonce, snapshot)
            .expect("encrypt");
        [nonce.as_slice(), &ct].concat()
    }

    pub fn open(key: &[u8; 32], sealed: &[u8]) -> Option<Vec<u8>> {
        use aes_gcm::aead::Aead;
        let (nonce, ct) = sealed.split_at_checked(12)?;
        Self::snapshot_cipher(key)
            .decrypt(aes_gcm::Nonce::from_slice(nonce), ct)
            .ok()
    }

    /// What a joiner puts in their external commit's authenticated data: the invite ID and a
    /// MAC binding the link key to the joiner and the epoch.
    pub fn proof(id: &[u8; 16], key: &[u8; 32], joiner: &Account, epoch: u64) -> Vec<u8> {
        use hmac::{Hmac, Mac};
        let mut m = <Hmac<sha2::Sha256> as Mac>::new_from_slice(key).expect("any key length");
        m.update(b"siegel-invite-v1");
        m.update(joiner);
        m.update(&epoch.to_be_bytes());
        [&id[..], &m.finalize().into_bytes()[..16]].concat()
    }
}

/// Why a commit was refused.
#[derive(Debug, Clone, PartialEq)]
pub struct Refused(pub &'static str);

impl GroupState {
    /// 2 adds invites; version 1 states (before invite links) still decode.
    const VERSION: u8 = 2;

    pub fn encode(&self) -> Vec<u8> {
        let mut b = vec![Self::VERSION];
        let name = self.name.as_bytes();
        b.extend((name.len() as u16).to_be_bytes());
        b.extend(name);
        b.push(self.admins_only_info as u8 | (self.admins_only_add as u8) << 1);
        for list in [&self.admins, &self.joined] {
            b.extend((list.len() as u16).to_be_bytes());
            list.iter().for_each(|a| b.extend(a));
        }
        b.extend((self.invites.len() as u16).to_be_bytes());
        for i in &self.invites {
            b.extend(i.id);
            b.extend(i.key);
            b.extend(i.write_key);
            b.extend(i.expires.to_be_bytes());
            b.extend(i.by);
        }
        b
    }

    pub fn decode(b: &[u8]) -> Option<Self> {
        let mut r = Reader(b);
        let version = r.take(1)?[0];
        if !(1..=Self::VERSION).contains(&version) {
            return None;
        }
        let n = r.u16()?;
        let name = String::from_utf8(r.take(n)?.to_vec()).ok()?;
        let flags = r.take(1)?[0];
        let mut list = || -> Option<Vec<Account>> {
            let n = r.u16()?;
            (0..n).map(|_| r.take(16)?.try_into().ok()).collect()
        };
        let (admins, joined) = (list()?, list()?);
        let mut invites = Vec::new();
        if version >= 2 {
            for _ in 0..r.u16()? {
                let b = r.take(Invite::LEN)?;
                invites.push(Invite {
                    id: b[..16].try_into().ok()?,
                    key: b[16..48].try_into().ok()?,
                    write_key: b[48..64].try_into().ok()?,
                    expires: u64::from_be_bytes(b[64..72].try_into().ok()?),
                    by: b[72..88].try_into().ok()?,
                });
            }
        }
        r.0.is_empty().then_some(Self {
            name,
            admins,
            admins_only_info: flags & 1 != 0,
            admins_only_add: flags & 2 != 0,
            joined,
            invites,
        })
    }

    /// GRP-16: someone joined by link with an external commit. Valid only with a proof made from
    /// a live invite's key for this joiner and epoch.
    pub fn check_join(
        &self,
        joiner: &Account,
        proof: &[u8],
        epoch: u64,
        now: u64,
    ) -> Result<(), Refused> {
        let invite = self
            .invites
            .iter()
            .find(|i| proof.get(..16) == Some(&i.id[..]))
            .ok_or(Refused("invite_unknown"))?;
        if invite.expires <= now {
            return Err(Refused("invite_expired"));
        }
        if Invite::proof(&invite.id, &invite.key, joiner, epoch) != proof {
            return Err(Refused("invite_proof_invalid"));
        }
        Ok(())
    }

    /// GRP-08: the admins still in the group, or the longest-standing member if none is left.
    pub fn effective_admins(&self) -> Vec<Account> {
        let present: Vec<Account> = self
            .admins
            .iter()
            .filter(|a| self.joined.contains(a))
            .copied()
            .collect();
        if present.is_empty() {
            self.joined.first().copied().into_iter().collect()
        } else {
            present
        }
    }

    pub fn is_admin(&self, a: &Account) -> bool {
        self.effective_admins().contains(a)
    }

    /// The state after members join or leave: the join order follows them, departed admins go.
    pub fn with_members(&self, added: &[Account], removed: &[Account]) -> Self {
        let mut s = self.clone();
        s.joined.retain(|a| !removed.contains(a));
        for a in added {
            if !s.joined.contains(a) {
                s.joined.push(*a);
            }
        }
        s.admins.retain(|a| s.joined.contains(a));
        s
    }

    /// GRP-07: may `committer` turn this state into `new`, adding and removing these accounts?
    /// `removed` pairs each removed account with who proposed its removal (a member leaving
    /// proposes their own). The new join order must be exactly what the membership change implies.
    pub fn check(
        &self,
        committer: &Account,
        added: &[Account],
        removed: &[(Account, Account)],
        unlisted: &[Account],
        new: &GroupState,
    ) -> Result<(), Refused> {
        let admin = |a: &Account| self.is_admin(a);
        if !added.is_empty() && self.admins_only_add && !admin(committer) {
            return Err(Refused("add_not_allowed"));
        }
        for (gone, by) in removed {
            if gone != by && !admin(by) {
                return Err(Refused("remove_not_allowed"));
            }
        }
        let gone: Vec<Account> = removed.iter().map(|(a, _)| *a).collect();
        let expected = self.with_members(added, &gone);
        // Members who joined by link (GRP-16) aren't in the join order yet: any commit may
        // append them, in any order, once each.
        let tail = new.joined.get(expected.joined.len()..).unwrap_or_default();
        let repaired = new.joined.starts_with(&expected.joined)
            && tail
                .iter()
                .all(|a| unlisted.contains(a) && !gone.contains(a))
            && tail.iter().enumerate().all(|(i, a)| !tail[..i].contains(a));
        if !repaired {
            return Err(Refused("membership_mismatch"));
        }
        if new.name != self.name {
            if self.admins_only_info && !admin(committer) {
                return Err(Refused("rename_not_allowed"));
            }
            if !(1..=64).contains(&new.name.chars().count()) {
                return Err(Refused("name_invalid"));
            }
        }
        let roles_changed = new.admins != expected.admins
            || new.admins_only_info != self.admins_only_info
            || new.admins_only_add != self.admins_only_add
            || new.invites != self.invites; // GRP-16: admins create and revoke links
        if roles_changed && !admin(committer) {
            return Err(Refused("settings_not_allowed"));
        }
        if new.admins.iter().any(|a| !new.joined.contains(a)) {
            return Err(Refused("admin_not_member"));
        }
        Ok(())
    }
}

struct Reader<'a>(&'a [u8]);

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let (a, b) = self.0.split_at_checked(n)?;
        self.0 = b;
        Some(a)
    }
    fn u16(&mut self) -> Option<usize> {
        Some(u16::from_be_bytes(self.take(2)?.try_into().ok()?) as usize)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: Account = [1; 16];
    const B: Account = [2; 16];
    const C: Account = [3; 16];

    fn group() -> GroupState {
        GroupState {
            name: "Hikers".into(),
            admins: vec![A],
            admins_only_info: true,
            admins_only_add: true,
            joined: vec![A, B],
            invites: vec![],
        }
    }

    #[test]
    fn roundtrip_and_rules() {
        let g = group();
        assert_eq!(GroupState::decode(&g.encode()), Some(g.clone()));
        assert_eq!(GroupState::decode(&[2]), None);

        // Admin adds C; member B may not (GRP-05, GRP-06).
        let with_c = g.with_members(&[C], &[]);
        assert_eq!(g.check(&A, &[C], &[], &[], &with_c), Ok(()));
        assert_eq!(
            g.check(&B, &[C], &[], &[], &with_c),
            Err(Refused("add_not_allowed"))
        );
        // A commit must carry the matching join order.
        assert_eq!(
            g.check(&A, &[C], &[], &[], &g),
            Err(Refused("membership_mismatch"))
        );

        // AC-10: a member removing someone else is refused; leaving yourself is fine.
        let without_a = g.with_members(&[], &[A]);
        assert_eq!(
            g.check(&B, &[], &[(A, B)], &[], &without_a),
            Err(Refused("remove_not_allowed"))
        );
        assert_eq!(g.check(&B, &[], &[(A, A)], &[], &without_a), Ok(()));
        // GRP-08: with its only admin gone, the longest-standing member leads.
        assert_eq!(without_a.effective_admins(), vec![B]);

        // Renames and role changes follow the settings.
        let renamed = GroupState {
            name: "Hikers 2026".into(),
            ..g.clone()
        };
        assert_eq!(
            g.check(&B, &[], &[], &[], &renamed),
            Err(Refused("rename_not_allowed"))
        );
        let open = GroupState {
            admins_only_info: false,
            ..g.clone()
        };
        let renamed_open = GroupState {
            name: "Hikers 2026".into(),
            ..open.clone()
        };
        assert_eq!(open.check(&B, &[], &[], &[], &renamed_open), Ok(()));
        let promoted = GroupState {
            admins: vec![A, B],
            ..g.clone()
        };
        assert_eq!(
            g.check(&B, &[], &[], &[], &promoted),
            Err(Refused("settings_not_allowed"))
        );
        assert_eq!(g.check(&A, &[], &[], &[], &promoted), Ok(()));
        let empty = GroupState {
            name: String::new(),
            ..g.clone()
        };
        assert_eq!(
            g.check(&A, &[], &[], &[], &empty),
            Err(Refused("name_invalid"))
        );
    }

    #[test]
    fn invites_and_link_joins() {
        let mut g = group();
        assert_eq!(
            GroupState::decode(&[1, 0, 0, 0, 0, 0, 0, 0]).map(|s| s.invites),
            Some(vec![]),
            "version 1 still decodes"
        );
        let inv = Invite {
            id: [7; 16],
            key: [8; 32],
            write_key: [9; 16],
            expires: 1_000,
            by: A,
        };
        let with = GroupState {
            invites: vec![inv.clone()],
            ..g.clone()
        };
        assert_eq!(GroupState::decode(&with.encode()), Some(with.clone()));
        assert_eq!(
            g.check(&B, &[], &[], &[], &with),
            Err(Refused("settings_not_allowed")),
            "only admins make links"
        );
        assert_eq!(g.check(&A, &[], &[], &[], &with), Ok(()));
        g = with;

        let sealed = Invite::seal(&inv.key, b"snapshot");
        assert_eq!(
            Invite::open(&inv.key, &sealed).as_deref(),
            Some(&b"snapshot"[..])
        );
        assert_eq!(Invite::open(&[0; 32], &sealed), None);
        let proof = Invite::proof(&inv.id, &inv.key, &C, 5);
        assert_eq!(g.check_join(&C, &proof, 5, 999), Ok(()));
        assert_eq!(
            g.check_join(&C, &proof, 6, 999),
            Err(Refused("invite_proof_invalid")),
            "bound to the epoch"
        );
        assert_eq!(
            g.check_join(&B, &proof, 5, 999),
            Err(Refused("invite_proof_invalid")),
            "bound to the joiner"
        );
        assert_eq!(
            g.check_join(&C, &proof, 5, 1_000),
            Err(Refused("invite_expired"))
        );
        assert_eq!(
            g.check_join(&C, &[0; 32], 5, 999),
            Err(Refused("invite_unknown"))
        );

        // The joiner then appears in the join order by a repair commit anyone may make.
        let repaired = GroupState {
            joined: vec![A, B, C],
            ..g.clone()
        };
        assert_eq!(g.check(&C, &[], &[], &[C], &repaired), Ok(()));
        assert_eq!(
            g.check(&C, &[], &[], &[], &repaired),
            Err(Refused("membership_mismatch")),
            "only unlisted members"
        );
    }
}
