//! Ciphertext anyone can hand us: attachment blobs, profiles from the server, discovery
//! results and bucket entries.
#![no_main]
use core_crypto::{discovery as d, profile::ProfileKey};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let (key, rest) = data.split_at(data.len().min(32));
    let size = rest.len().saturating_sub(16);
    let _ = core_media::decrypt(key, rest, size);
    let _ = core_media::decrypt(&[1; 32], data, data.len());
    let _ = ProfileKey([3; 32]).decrypt(data);
    let (r, _) = d::blind("+34600000000");
    if let Some(o) = d::finalize(&r, data) {
        let _ = d::open(&o, data);
    }
    let _ = d::open(&[5; 32], data);
    let _ = d::bucket_of(data, data.first().copied().unwrap_or(0) as u32);
});
