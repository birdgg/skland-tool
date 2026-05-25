use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use hmac::{Hmac, Mac};
use md5::{Digest, Md5};
use sha2::Sha256;

use crate::types::{Binding, Credential};

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignedHeaders {
    pub platform: String,
    pub timestamp: String,
    pub version_name: String,
    pub sign: String,
}

pub fn current_timestamp_for_sign() -> Result<i64> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("系统时间早于 UNIX_EPOCH")?;
    Ok(i64::try_from(now.as_secs()).unwrap_or(i64::MAX) - 2)
}

pub fn signed_headers(
    credential: &Credential,
    did: &str,
    method: &str,
    path: &str,
    body: &str,
) -> Result<SignedHeaders> {
    signed_headers_at(
        credential,
        did,
        method,
        path,
        body,
        current_timestamp_for_sign()?,
    )
}

pub fn signed_headers_at(
    credential: &Credential,
    did: &str,
    method: &str,
    path: &str,
    body: &str,
    timestamp: i64,
) -> Result<SignedHeaders> {
    let timestamp = timestamp.to_string();
    let header_ca = compact_object(&[
        ("platform", "3"),
        ("timestamp", &timestamp),
        ("dId", did),
        ("vName", "1.0.0"),
    ]);
    let raw = if method == "GET" {
        format!("{path}{timestamp}{header_ca}")
    } else {
        format!("{path}{body}{timestamp}{header_ca}")
    };

    let mut mac =
        HmacSha256::new_from_slice(credential.token.as_bytes()).context("无法创建 HMAC-SHA256")?;
    mac.update(raw.as_bytes());
    let hmac_hex = hex::encode(mac.finalize().into_bytes());

    let mut md5 = Md5::new();
    md5.update(hmac_hex.as_bytes());
    let sign = hex::encode(md5.finalize());

    Ok(SignedHeaders {
        platform: "3".to_owned(),
        timestamp,
        version_name: "1.0.0".to_owned(),
        sign,
    })
}

pub fn arknights_body(binding: &Binding) -> String {
    format!(
        "{{\"gameId\":{},\"uid\":{}}}",
        binding.game_id,
        serde_json::to_string(&binding.uid).unwrap_or_else(|_| "\"\"".to_owned())
    )
}

fn compact_object(fields: &[(&str, &str)]) -> String {
    let pairs = fields
        .iter()
        .map(|(key, value)| {
            let key = serde_json::to_string(key).unwrap_or_else(|_| "\"\"".to_owned());
            let value = serde_json::to_string(value).unwrap_or_else(|_| "\"\"".to_owned());
            format!("{key}:{value}")
        })
        .collect::<Vec<_>>()
        .join(",");
    format!("{{{pairs}}}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arknights_body_is_compact() {
        let binding = Binding {
            app_code: "arknights".to_owned(),
            game_name: String::new(),
            role_name: String::new(),
            channel_name: String::new(),
            uid: "123".to_owned(),
            game_id: 1,
            roles: Vec::new(),
        };

        assert_eq!(arknights_body(&binding), "{\"gameId\":1,\"uid\":\"123\"}");
    }

    #[test]
    fn sign_is_stable_for_fixed_timestamp() {
        let credential = Credential {
            cred: "cred".to_owned(),
            token: "secret".to_owned(),
        };

        let headers = signed_headers_at(
            &credential,
            "DID",
            "GET",
            "/api/v1/game/player/binding",
            "",
            1_700_000_000,
        )
        .unwrap();

        assert_eq!(headers.platform, "3");
        assert_eq!(headers.version_name, "1.0.0");
        assert_eq!(headers.sign.len(), 32);
    }
}
