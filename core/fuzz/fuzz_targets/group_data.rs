//! Group data from other members or the server: device credentials, the group state carried
//! in the group context, invite-link snapshots and their sealed form.
#![no_main]
use core_crypto::{
    groups::{GroupState, Invite},
    mls::{DeviceCredential, Mls},
};
use libfuzzer_sys::fuzz_target;
use openmls_rust_crypto::OpenMlsRustCrypto;

fuzz_target!(|data: &[u8]| {
    let _ = DeviceCredential::decode(data);
    if let Some(s) = GroupState::decode(data) {
        let _ = s.encode();
        let _ = s.effective_admins();
    }
    let _ = Mls::<OpenMlsRustCrypto>::peek(data);
    let _ = Invite::open(&[7; 32], data);
});
