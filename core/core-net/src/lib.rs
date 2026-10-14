//! Server API client: Connect protocol, unary calls, protobuf bodies (SRV-02).

use std::sync::Arc;

use prost::Message;
use rustls::pki_types::{CertificateDer, pem::PemObject};

pub mod pb {
    include!(concat!(env!("OUT_DIR"), "/siegel.v1.rs"));
}

/// A stable machine code: the server's error string ("otp_invalid", "rate_limited", ...),
/// or "network" / "bad_response" for local failures.
#[derive(Debug, Clone, PartialEq)]
pub struct Error {
    pub code: String,
}

impl Error {
    fn new(code: &str) -> Self {
        Self { code: code.into() }
    }
}

pub struct Client {
    http: reqwest::Client,
    base: String,
}

/// SEC-06 pins: the server's certificate comes from Let's Encrypt, whose leaf key rotates on
/// every renewal, so we pin the CA roots instead. X1 and X2 chain today's certificates; YE and
/// YR are the next-generation roots, kept so the app survives when the cross-signs expire.
/// No other CA is trusted, which blocks rogue-CA and interception-proxy certificates.
const PINNED_ROOTS: [&[u8]; 4] = [
    include_bytes!("../certs/isrg-root-x1.pem"),
    include_bytes!("../certs/isrg-root-x2.pem"),
    include_bytes!("../certs/isrg-root-ye.pem"),
    include_bytes!("../certs/isrg-root-yr.pem"),
];

fn pinned_tls() -> rustls::ClientConfig {
    let mut roots = rustls::RootCertStore::empty();
    for pem in PINNED_ROOTS {
        roots
            .add(CertificateDer::from_pem_slice(pem).expect("bundled root"))
            .expect("valid root");
    }
    rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .with_protocol_versions(&[&rustls::version::TLS13]) // ARCH-02: the server is TLS 1.3 only
        .expect("TLS 1.3")
        .with_root_certificates(roots)
        .with_no_client_auth()
}

impl Client {
    /// `https` bases get the pinned TLS config; `http` is for the local dev server only.
    pub fn new(base: &str) -> Self {
        let mut b = reqwest::Client::builder();
        if base.starts_with("https://") {
            b = b.use_preconfigured_tls(pinned_tls());
        }
        Self {
            http: b.build().expect("http client"),
            base: base.trim_end_matches('/').into(),
        }
    }

    async fn call<Res: Message + Default>(
        &self,
        method: &str,
        req: &impl Message,
        token: Option<&str>,
    ) -> Result<Res, Error> {
        let mut r = self
            .http
            .post(format!("{}/siegel.v1.{method}", self.base))
            .header("Content-Type", "application/proto")
            .body(req.encode_to_vec());
        if let Some(t) = token {
            r = r.bearer_auth(t);
        }
        let res = r.send().await.map_err(|_| Error::new("network"))?;
        let ok = res.status().is_success();
        let body = res.bytes().await.map_err(|_| Error::new("network"))?;
        if ok {
            return Res::decode(body).map_err(|_| Error::new("bad_response"));
        }
        #[derive(serde::Deserialize)]
        struct ConnectError {
            code: Option<String>,
            message: Option<String>,
        }
        let e: ConnectError =
            serde_json::from_slice(&body).map_err(|_| Error::new("bad_response"))?;
        Err(Error {
            code: e
                .message
                .or(e.code)
                .unwrap_or_else(|| "bad_response".into()),
        })
    }

    pub async fn request_otp(
        &self,
        phone_e164: &str,
        attestation_token: &str,
    ) -> Result<(), Error> {
        let req = pb::RequestOtpRequest {
            phone_e164: phone_e164.into(),
            attestation_token: attestation_token.into(),
        };
        self.call::<pb::RequestOtpResponse>("RegistrationService/RequestOtp", &req, None)
            .await
            .map(|_| ())
    }

    pub async fn verify(&self, req: pb::VerifyRequest) -> Result<pb::VerifyResponse, Error> {
        self.call("RegistrationService/Verify", &req, None).await
    }

    pub async fn set_username(&self, token: &str, username: &str) -> Result<(), Error> {
        let req = pb::UsernameServiceSetRequest {
            username: username.into(),
        };
        self.call::<pb::UsernameServiceSetResponse>("UsernameService/Set", &req, Some(token))
            .await
            .map(|_| ())
    }

    pub async fn lookup_username(
        &self,
        token: &str,
        username: &str,
    ) -> Result<pb::UsernameServiceLookupResponse, Error> {
        let req = pb::UsernameServiceLookupRequest {
            username: username.into(),
        };
        self.call("UsernameService/Lookup", &req, Some(token)).await
    }

    pub async fn set_registration_lock(&self, token: &str, pin: &str) -> Result<(), Error> {
        let req = pb::SetRegistrationLockRequest { pin: pin.into() };
        self.call::<pb::SetRegistrationLockResponse>(
            "AccountService/SetRegistrationLock",
            &req,
            Some(token),
        )
        .await
        .map(|_| ())
    }

    pub async fn delete_account(&self, token: &str) -> Result<(), Error> {
        self.call::<pb::AccountServiceDeleteResponse>(
            "AccountService/Delete",
            &pb::AccountServiceDeleteRequest {},
            Some(token),
        )
        .await
        .map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pins_parse() {
        let _ = pinned_tls();
    }

    // Needs the network: cargo test -p core-net -- --ignored
    #[tokio::test]
    #[ignore]
    async fn pinning_accepts_our_server_and_rejects_other_cas() {
        let ours = Client::new("https://siegel.schlk.in");
        assert_eq!(
            ours.request_otp("0034", "").await.unwrap_err().code,
            "phone_invalid",
            "reached our server"
        );
        let other = Client::new("https://www.google.com"); // Google Trust Services, not Let's Encrypt
        assert_eq!(
            other.request_otp("0034", "").await.unwrap_err().code,
            "network",
            "foreign CA rejected"
        );
    }
}
