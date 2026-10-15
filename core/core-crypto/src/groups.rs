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
}

/// Why a commit was refused.
#[derive(Debug, Clone, PartialEq)]
pub struct Refused(pub &'static str);

impl GroupState {
    const VERSION: u8 = 1;

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
        b
    }

    pub fn decode(b: &[u8]) -> Option<Self> {
        let mut r = Reader(b);
        if r.take(1)?[0] != Self::VERSION {
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
        r.0.is_empty().then_some(Self {
            name,
            admins,
            admins_only_info: flags & 1 != 0,
            admins_only_add: flags & 2 != 0,
            joined,
        })
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
        if new.joined != expected.joined {
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
            || new.admins_only_add != self.admins_only_add;
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
        }
    }

    #[test]
    fn roundtrip_and_rules() {
        let g = group();
        assert_eq!(GroupState::decode(&g.encode()), Some(g.clone()));
        assert_eq!(GroupState::decode(&[2]), None);

        // Admin adds C; member B may not (GRP-05, GRP-06).
        let with_c = g.with_members(&[C], &[]);
        assert_eq!(g.check(&A, &[C], &[], &with_c), Ok(()));
        assert_eq!(
            g.check(&B, &[C], &[], &with_c),
            Err(Refused("add_not_allowed"))
        );
        // A commit must carry the matching join order.
        assert_eq!(
            g.check(&A, &[C], &[], &g),
            Err(Refused("membership_mismatch"))
        );

        // AC-10: a member removing someone else is refused; leaving yourself is fine.
        let without_a = g.with_members(&[], &[A]);
        assert_eq!(
            g.check(&B, &[], &[(A, B)], &without_a),
            Err(Refused("remove_not_allowed"))
        );
        assert_eq!(g.check(&B, &[], &[(A, A)], &without_a), Ok(()));
        // GRP-08: with its only admin gone, the longest-standing member leads.
        assert_eq!(without_a.effective_admins(), vec![B]);

        // Renames and role changes follow the settings.
        let renamed = GroupState {
            name: "Hikers 2026".into(),
            ..g.clone()
        };
        assert_eq!(
            g.check(&B, &[], &[], &renamed),
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
        assert_eq!(open.check(&B, &[], &[], &renamed_open), Ok(()));
        let promoted = GroupState {
            admins: vec![A, B],
            ..g.clone()
        };
        assert_eq!(
            g.check(&B, &[], &[], &promoted),
            Err(Refused("settings_not_allowed"))
        );
        assert_eq!(g.check(&A, &[], &[], &promoted), Ok(()));
        let empty = GroupState {
            name: String::new(),
            ..g.clone()
        };
        assert_eq!(g.check(&A, &[], &[], &empty), Err(Refused("name_invalid")));
    }
}
