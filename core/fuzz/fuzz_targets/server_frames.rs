//! Responses and stream frames from the server, which the app must not trust to be well formed.
#![no_main]
use core_net::pb;
use libfuzzer_sys::fuzz_target;
use prost::Message as _;

fuzz_target!(|data: &[u8]| {
    let _ = pb::StreamFrame::decode(data);
    let _ = pb::KeysServiceClaimResponse::decode(data);
    let _ = pb::InvitesServiceGetResponse::decode(data);
    let _ = pb::ProfileServiceGetResponse::decode(data);
    let _ = pb::DiscoveryServiceBucketsResponse::decode(data);
});
