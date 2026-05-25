use anyhow::{Context, Result, bail};
use reqwest::header::{
    ACCEPT_ENCODING, CONNECTION, CONTENT_TYPE, HeaderMap, HeaderName, HeaderValue, ORIGIN, REFERER,
    USER_AGENT,
};
use reqwest::{Client, Method};
use serde_json::json;

use super::parser::{
    parse_attendance_result, parse_authorization, parse_bindings, parse_credential,
};
use crate::sign::{arknights_body, signed_headers};
use crate::types::{Binding, Credential, EndfieldRole, GameSignResult, UserConfig};

const USER_AGENT_VALUE: &str = "Mozilla/5.0 SKLand/1.52.1";
const AUTH_BASE_URL: &str = "https://as.hypergryph.com";
const ZONAI_BASE_URL: &str = "https://zonai.skland.com";

#[derive(Debug, Clone)]
pub struct SklandClient {
    client: Client,
}

impl SklandClient {
    pub fn new() -> Result<Self> {
        let client = Client::builder()
            .gzip(true)
            .build()
            .context("无法创建 HTTP client")?;
        Ok(Self { client })
    }

    pub async fn get_authorization(&self, did: &str, user: &UserConfig) -> Result<String> {
        let body = json!({
            "appCode": "4ca99fa6b56cc2ba",
            "token": user.user_token,
            "type": 0,
        })
        .to_string();
        let response = self
            .request(
                Method::POST,
                AUTH_BASE_URL,
                "/user/oauth2/v2/grant",
                base_headers(did),
                body,
            )
            .await?;
        parse_authorization(&response)
    }

    pub async fn get_credential(&self, did: &str, code: &str) -> Result<Credential> {
        let body = json!({
            "code": code,
            "kind": 1,
        })
        .to_string();
        let response = self
            .request(
                Method::POST,
                ZONAI_BASE_URL,
                "/web/v1/user/auth/generate_cred_by_code",
                base_headers(did),
                body,
            )
            .await?;
        parse_credential(&response)
    }

    pub async fn get_binding_list(
        &self,
        did: &str,
        credential: &Credential,
    ) -> Result<Vec<Binding>> {
        let response = self
            .signed_request(
                Method::GET,
                did,
                credential,
                "/api/v1/game/player/binding",
                String::new(),
                |_| Ok(()),
            )
            .await?;
        parse_bindings(&response)
    }

    pub async fn sign_arknights(
        &self,
        did: &str,
        credential: &Credential,
        binding: &Binding,
    ) -> GameSignResult {
        let path = "/api/v1/game/attendance";
        let body = arknights_body(binding);
        let response = self
            .signed_request(Method::POST, did, credential, path, body, |_| Ok(()))
            .await;
        parse_attendance_result("明日方舟", &binding.role_name, response)
    }

    pub async fn sign_endfield(
        &self,
        did: &str,
        credential: &Credential,
        binding: &Binding,
        role: &EndfieldRole,
    ) -> GameSignResult {
        let path = "/web/v1/game/endfield/attendance";
        let role_header = format!("3_{}_{}", role.role_id, role.server_id);
        let character = if role.role_nickname.is_empty() {
            binding.role_name.as_str()
        } else {
            role.role_nickname.as_str()
        };
        let response = self
            .signed_request(
                Method::POST,
                did,
                credential,
                path,
                String::new(),
                |headers| {
                    headers.insert(
                        HeaderName::from_static("sk-game-role"),
                        HeaderValue::from_str(&role_header).context("非法 sk-game-role header")?,
                    );
                    headers.insert(
                        REFERER,
                        HeaderValue::from_static("https://game.skland.com/"),
                    );
                    headers.insert(ORIGIN, HeaderValue::from_static("https://game.skland.com/"));
                    Ok(())
                },
            )
            .await;
        parse_attendance_result("终末地", character, response)
    }

    async fn signed_request<F>(
        &self,
        method: Method,
        did: &str,
        credential: &Credential,
        path: &str,
        body: String,
        extra_headers: F,
    ) -> Result<String>
    where
        F: FnOnce(&mut HeaderMap) -> Result<()>,
    {
        let signed = signed_headers(credential, did, method.as_str(), path, &body)?;
        let mut headers = signed_header_map(did, credential, &signed)?;
        extra_headers(&mut headers)?;
        self.request(method, ZONAI_BASE_URL, path, headers, body)
            .await
    }

    async fn request(
        &self,
        method: Method,
        base_url: &str,
        path: &str,
        headers: HeaderMap,
        body: String,
    ) -> Result<String> {
        let url = format!("{base_url}{path}");
        let mut request = self.client.request(method, url).headers(headers);
        if !body.is_empty() {
            request = request.body(body);
        }
        let response = request.send().await.context("HTTP 请求发送失败")?;
        let status = response.status();
        let text = response.text().await.context("HTTP 响应读取失败")?;
        if !status.is_success() && text.trim().is_empty() {
            bail!("HTTP 请求失败: status={} body=<empty>", status.as_u16());
        }
        Ok(text)
    }
}

fn base_headers(did: &str) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(USER_AGENT, HeaderValue::from_static(USER_AGENT_VALUE));
    headers.insert(ACCEPT_ENCODING, HeaderValue::from_static("gzip"));
    headers.insert(CONNECTION, HeaderValue::from_static("close"));
    headers.insert(
        HeaderName::from_static("x-requested-with"),
        HeaderValue::from_static("com.hypergryph.skland"),
    );
    if let Ok(value) = HeaderValue::from_str(did) {
        headers.insert(HeaderName::from_static("did"), value);
    }
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    headers
}

fn signed_header_map(
    did: &str,
    credential: &Credential,
    signed: &crate::sign::SignedHeaders,
) -> Result<HeaderMap> {
    let mut headers = base_headers(did);
    headers.insert(
        HeaderName::from_static("cred"),
        HeaderValue::from_str(&credential.cred)?,
    );
    headers.insert(
        HeaderName::from_static("platform"),
        HeaderValue::from_str(&signed.platform)?,
    );
    headers.insert(
        HeaderName::from_static("timestamp"),
        HeaderValue::from_str(&signed.timestamp)?,
    );
    headers.insert(
        HeaderName::from_static("vname"),
        HeaderValue::from_str(&signed.version_name)?,
    );
    headers.insert(
        HeaderName::from_static("sign"),
        HeaderValue::from_str(&signed.sign)?,
    );
    Ok(headers)
}
