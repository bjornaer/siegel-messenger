//! What arrives inside an MLS message once decrypted: message bodies, attachment metadata,
//! group events, profiles, and links people paste or scan.
#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    core_api::fuzz::content(data);
    core_api::fuzz::profile(data);
    if let Ok(s) = std::str::from_utf8(data) {
        core_api::fuzz::links(s);
    }
});
