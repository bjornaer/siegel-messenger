//! Server API client: Connect protocol, unary calls, protobuf bodies (SRV-02).
//! ponytail: no TLS pinning yet (SEC-06); add rustls pinned verifier before beta.

use prost::Message;

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

impl Client {
    pub fn new(base: &str) -> Self {
        Self {
            http: reqwest::Client::new(),
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
