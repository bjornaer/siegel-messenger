//! MLS messages from the queue: anything a sender or the server can put there. Half the inputs
//! are raw bytes, half are real messages (a Welcome, a commit, an application message) with
//! the input written over them, so mutations reach past the outer framing.
#![no_main]
use std::sync::{Mutex, OnceLock};

use core_crypto::{
    IdentityKey,
    mls::{DeviceCredential, Mls},
};
use libfuzzer_sys::fuzz_target;
use openmls_rust_crypto::OpenMlsRustCrypto;

struct World {
    bob: Mls<OpenMlsRustCrypto>,
    seeds: Vec<Vec<u8>>,
}

fn device(as_key: &IdentityKey, n: u8) -> Mls<OpenMlsRustCrypto> {
    let provider = OpenMlsRustCrypto::default();
    let signer = Mls::new_signer(&provider).unwrap();
    let id = IdentityKey::generate();
    let account = [n; 16];
    let sig = as_key.sign(&[b"siegel-as-v1".as_slice(), &account, &id.public()].concat());
    let cred = DeviceCredential::issue(&id, account, [n + 100; 16], signer.public(), sig);
    Mls::load(provider, signer.public(), &cred, as_key.public()).unwrap()
}

fn world() -> &'static Mutex<World> {
    static W: OnceLock<Mutex<World>> = OnceLock::new();
    W.get_or_init(|| {
        let as_key = IdentityKey::generate();
        let (alice, bob, carol) = (device(&as_key, 1), device(&as_key, 2), device(&as_key, 3));
        let out = alice
            .create_group(&bob.key_packages(1, false).unwrap(), None)
            .unwrap();
        alice.confirm(&out.group_id).unwrap();
        let welcome = out.welcome.clone();
        bob.receive(&welcome).unwrap();
        let text = alice.encrypt(&out.group_id, b"hello").unwrap();
        let mut seeds = vec![welcome, text];
        // A second Welcome (for Carol) never meant for Bob, and an update commit.
        if let Ok(o) = alice.create_group(&carol.key_packages(1, false).unwrap(), None) {
            seeds.push(o.welcome);
        }
        if let Ok(o) = alice.self_update(&out.group_id) {
            seeds.push(o.commit);
        }
        Mutex::new(World { bob, seeds })
    })
}

fuzz_target!(|data: &[u8]| {
    let w = world().lock().unwrap();
    match data.split_first() {
        Some((&mode, rest)) if mode & 1 == 1 && !w.seeds.is_empty() => {
            let mut msg = w.seeds[(mode as usize >> 1) % w.seeds.len()].clone();
            // Overwrite from an offset the input picks, so headers and bodies both get hit.
            let at = rest.first().map_or(0, |&b| b as usize * msg.len() / 256);
            for (i, b) in rest.iter().skip(1).enumerate() {
                if let Some(x) = msg.get_mut(at + i) {
                    *x = *b;
                }
            }
            let _ = w.bob.receive(&msg);
        }
        _ => {
            let _ = w.bob.receive(data);
        }
    }
});
