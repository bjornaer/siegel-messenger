//! Server API client: Connect protocol, unary calls, protobuf bodies (SRV-02).

use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use prost::Message;
use rustls::pki_types::{CertificateDer, ServerName, pem::PemObject};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_tungstenite::{WebSocketStream, tungstenite};

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
    tls: Option<Arc<rustls::ClientConfig>>,
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
        let tls = base.starts_with("https://").then(|| Arc::new(pinned_tls()));
        if let Some(t) = &tls {
            b = b.use_preconfigured_tls((**t).clone());
        }
        Self {
            http: b.build().expect("http client"),
            base: base.trim_end_matches('/').into(),
            tls,
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

    /// (latest, minimum) published app builds for the platform; 0 = not set.
    pub async fn app_version(&self, platform: pb::Platform) -> Result<(u32, u32), Error> {
        let req = pb::AppVersionRequest {
            platform: platform as i32,
        };
        let r: pb::AppVersionResponse = self
            .call("RegistrationService/AppVersion", &req, None)
            .await?;
        Ok((r.latest, r.minimum))
    }

    pub async fn request_otp(
        &self,
        phone_e164: &str,
        attestation_token: &str,
        platform: pb::Platform,
    ) -> Result<u32, Error> {
        let req = pb::RequestOtpRequest {
            phone_e164: phone_e164.into(),
            attestation_token: attestation_token.into(),
            platform: platform as i32,
        };
        self.call::<pb::RequestOtpResponse>("RegistrationService/RequestOtp", &req, None)
            .await
            .map(|r| r.resend_after_seconds)
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

    /// FCM or APNs token for this device; empty clears it (MSG-17).
    pub async fn set_push_token(&self, token: &str, push_token: &str) -> Result<(), Error> {
        let req = pb::SetPushTokenRequest {
            push_token: push_token.into(),
        };
        self.call::<pb::SetPushTokenResponse>("AccountService/SetPushToken", &req, Some(token))
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

impl Client {
    /// Adds one-time KeyPackages and optionally replaces the last-resort one (CRY-09).
    /// Returns how many one-time packages the server still holds for this device.
    pub async fn upload_key_packages(
        &self,
        token: &str,
        key_packages: Vec<Vec<u8>>,
        last_resort: Vec<u8>,
        replace: bool,
    ) -> Result<u32, Error> {
        let req = pb::KeysServiceUploadRequest {
            key_packages,
            last_resort,
            replace,
        };
        let res: pb::KeysServiceUploadResponse =
            self.call("KeysService/Upload", &req, Some(token)).await?;
        Ok(res.remaining)
    }

    /// One KeyPackage per device of the account (GRP-09).
    pub async fn claim_key_packages(
        &self,
        token: &str,
        account_id: &[u8],
    ) -> Result<Vec<pb::ClaimedKeyPackage>, Error> {
        let req = pb::KeysServiceClaimRequest {
            account_id: account_id.to_vec(),
        };
        let res: pb::KeysServiceClaimResponse =
            self.call("KeysService/Claim", &req, Some(token)).await?;
        Ok(res.key_packages)
    }

    pub async fn set_profile(
        &self,
        token: &str,
        encrypted_profile: Vec<u8>,
        verifier: Vec<u8>,
    ) -> Result<(), Error> {
        let req = pb::ProfileServiceSetRequest {
            encrypted_profile,
            delivery_token_verifier: verifier,
        };
        self.call::<pb::ProfileServiceSetResponse>("ProfileService/Set", &req, Some(token))
            .await
            .map(|_| ())
    }

    pub async fn get_profile(&self, token: &str, account_id: &[u8]) -> Result<Vec<u8>, Error> {
        let req = pb::ProfileServiceGetRequest {
            account_id: account_id.to_vec(),
        };
        let res: pb::ProfileServiceGetResponse =
            self.call("ProfileService/Get", &req, Some(token)).await?;
        Ok(res.encrypted_profile)
    }

    /// Sealed sender (MSG-10): sent without credentials. Returns (revoked, rejected) devices.
    pub async fn send_sealed(
        &self,
        recipients: Vec<pb::SealedRecipient>,
        payload: Vec<u8>,
    ) -> Result<(Vec<pb::DeviceAddress>, Vec<pb::DeviceAddress>), Error> {
        let req = pb::MessagesServiceSendSealedRequest {
            recipients,
            payload,
        };
        let res: pb::MessagesServiceSendSealedResponse =
            self.call("MessagesService/SendSealed", &req, None).await?;
        Ok((res.revoked, res.rejected))
    }

    /// Queues an MLS message for each recipient; returns revoked devices (ID-13).
    pub async fn send_identified(
        &self,
        token: &str,
        recipients: Vec<pb::DeviceAddress>,
        payload: Vec<u8>,
    ) -> Result<Vec<pb::DeviceAddress>, Error> {
        let req = pb::MessagesServiceSendIdentifiedRequest {
            recipients,
            payload,
        };
        let res: pb::MessagesServiceSendIdentifiedResponse = self
            .call("MessagesService/SendIdentified", &req, Some(token))
            .await?;
        Ok(res.revoked)
    }

    /// Submits a commit for `req.epoch`; "epoch_conflict" means another commit won (CRY-14).
    pub async fn commit(
        &self,
        token: &str,
        req: pb::GroupsServiceCommitRequest,
    ) -> Result<Vec<pb::DeviceAddress>, Error> {
        let res: pb::GroupsServiceCommitResponse =
            self.call("GroupsService/Commit", &req, Some(token)).await?;
        Ok(res.revoked)
    }

    /// Opens WS /v1/stream (SRV-03), over the same pinned TLS as every other call.
    pub async fn stream(&self, token: &str) -> Result<Stream, Error> {
        let url = reqwest::Url::parse(&format!("{}/v1/stream", self.base)).map_err(net)?;
        let host = url.host_str().ok_or(Error::new("network"))?.to_string();
        let port = url.port_or_known_default().ok_or(Error::new("network"))?;
        let ws_url = format!(
            "{}://{}/v1/stream",
            if self.tls.is_some() { "wss" } else { "ws" },
            url.authority()
        );
        let mut req =
            tungstenite::client::IntoClientRequest::into_client_request(ws_url).map_err(net)?;
        req.headers_mut().insert(
            "Authorization",
            format!("Bearer {token}").parse().map_err(net)?,
        );
        let tcp = tokio::net::TcpStream::connect((host.as_str(), port))
            .await
            .map_err(net)?;
        let io: Box<dyn Io> = match &self.tls {
            Some(cfg) => {
                let name = ServerName::try_from(host).map_err(net)?;
                Box::new(
                    tokio_rustls::TlsConnector::from(cfg.clone())
                        .connect(name, tcp)
                        .await
                        .map_err(net)?,
                )
            }
            None => Box::new(tcp),
        };
        let (ws, _) = tokio_tungstenite::client_async(req, io)
            .await
            .map_err(|e| match e {
                tungstenite::Error::Http(r) if r.status() == 401 => Error::new("unauthenticated"),
                _ => Error::new("network"),
            })?;
        Ok(Stream { ws })
    }
}

fn net<E>(_: E) -> Error {
    Error::new("network")
}

trait Io: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Io for T {}

/// One device's message stream. Queued messages arrive in order; acknowledge them to delete
/// them from the server. Unacknowledged ones come again on the next connection.
pub struct Stream {
    ws: WebSocketStream<Box<dyn Io>>,
}

pub enum Frame {
    Message {
        id: i64,
        payload: Vec<u8>,
    },
    /// This device was revoked or its account deleted: wipe (ID-12).
    Deregistered,
}

impl Stream {
    /// The next frame, or None when the server closed the stream.
    pub async fn next(&mut self) -> Result<Option<Frame>, Error> {
        while let Some(msg) = self.ws.next().await {
            let tungstenite::Message::Binary(b) = msg.map_err(|_| Error::new("network"))? else {
                continue; // pings are answered by tungstenite
            };
            let f = pb::StreamFrame::decode(b).map_err(|_| Error::new("bad_response"))?;
            return Ok(match f.kind {
                Some(pb::stream_frame::Kind::Message(m)) => Some(Frame::Message {
                    id: m.id,
                    payload: m.payload,
                }),
                Some(pb::stream_frame::Kind::Deregistered(_)) => Some(Frame::Deregistered),
                None => continue,
            });
        }
        Ok(None)
    }

    pub async fn ack(&mut self, ids: Vec<i64>) -> Result<(), Error> {
        let b = pb::StreamAck { ids }.encode_to_vec();
        self.ws
            .send(tungstenite::Message::Binary(b.into()))
            .await
            .map_err(|_| Error::new("network"))
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
            ours.request_otp("0034", "", pb::Platform::Android)
                .await
                .unwrap_err()
                .code,
            "phone_invalid",
            "reached our server"
        );
        let other = Client::new("https://www.google.com"); // Google Trust Services, not Let's Encrypt
        assert_eq!(
            other
                .request_otp("0034", "", pb::Platform::Android)
                .await
                .unwrap_err()
                .code,
            "network",
            "foreign CA rejected"
        );
    }
}
