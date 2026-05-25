use anyhow::{Context, Result, anyhow, bail};
use reqwest::header::{
    ACCEPT_ENCODING, CONNECTION, CONTENT_TYPE, HeaderMap, HeaderName, HeaderValue, ORIGIN, REFERER,
    USER_AGENT,
};
use reqwest::{Client, Method};
use serde_json::{Value, json};

use crate::sign::{arknights_body, signed_headers};
use crate::types::{Award, Binding, Credential, EndfieldRole, GameSignResult, UserConfig};

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
        let path = "/api/v1/game/player/binding";
        let headers = signed_header_map(
            did,
            credential,
            &signed_headers(credential, did, "GET", path, "")?,
        )?;
        let response = self
            .request(Method::GET, ZONAI_BASE_URL, path, headers, String::new())
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
        let response = async {
            let headers = signed_header_map(
                did,
                credential,
                &signed_headers(credential, did, "POST", path, &body)?,
            )?;
            self.request(Method::POST, ZONAI_BASE_URL, path, headers, body)
                .await
        }
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
        let response = async {
            let mut headers = signed_header_map(
                did,
                credential,
                &signed_headers(credential, did, "POST", path, "")?,
            )?;
            headers.insert(
                HeaderName::from_static("sk-game-role"),
                HeaderValue::from_str(&role_header).context("非法 sk-game-role header")?,
            );
            headers.insert(
                REFERER,
                HeaderValue::from_static("https://game.skland.com/"),
            );
            headers.insert(ORIGIN, HeaderValue::from_static("https://game.skland.com/"));
            self.request(Method::POST, ZONAI_BASE_URL, path, headers, String::new())
                .await
        }
        .await;
        parse_attendance_result("终末地", character, response)
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
        if !status.is_success() {
            bail!("HTTP 请求失败: status={} body={}", status.as_u16(), text);
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

fn parse_authorization(raw: &str) -> Result<String> {
    let json: Value = serde_json::from_str(raw).context("OAuth 响应 JSON 解析失败")?;
    match json.get("status").and_then(Value::as_i64) {
        Some(0) => json
            .pointer("/data/code")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .ok_or_else(|| anyhow!("OAuth 响应缺少 data.code")),
        status => bail!("OAuth 授权失败: {} status={status:?}", message_of(&json)),
    }
}

fn parse_credential(raw: &str) -> Result<Credential> {
    let json: Value = serde_json::from_str(raw).context("credential 响应 JSON 解析失败")?;
    match json.get("code").and_then(Value::as_i64) {
        Some(0) => Ok(Credential {
            cred: json
                .pointer("/data/cred")
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow!("credential 响应缺少 data.cred"))?
                .to_owned(),
            token: json
                .pointer("/data/token")
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow!("credential 响应缺少 data.token"))?
                .to_owned(),
        }),
        code => bail!("credential 生成失败: {} code={code:?}", message_of(&json)),
    }
}

fn parse_bindings(raw: &str) -> Result<Vec<Binding>> {
    let json: Value = serde_json::from_str(raw).context("绑定响应 JSON 解析失败")?;
    match json.get("code").and_then(Value::as_i64) {
        Some(0) => {
            let groups = json
                .pointer("/data/list")
                .and_then(Value::as_array)
                .ok_or_else(|| anyhow!("绑定响应缺少 data.list"))?;
            Ok(groups.iter().flat_map(parse_group).collect())
        }
        code => bail!("查询绑定角色失败: {} code={code:?}", message_of(&json)),
    }
}

fn parse_group(group: &Value) -> Vec<Binding> {
    let app_code = string_field(group, "appCode");
    group
        .get("bindingList")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .map(|item| parse_binding(&app_code, item))
                .collect()
        })
        .unwrap_or_default()
}

fn parse_binding(app_code: &str, value: &Value) -> Binding {
    Binding {
        app_code: app_code.to_owned(),
        game_name: string_field(value, "gameName"),
        role_name: first_non_empty(&[
            string_field(value, "nickName"),
            string_field(value, "nickname"),
            string_field(value, "name"),
        ]),
        channel_name: string_field(value, "channelName"),
        uid: string_field(value, "uid"),
        game_id: int_field(value, "gameId"),
        roles: value
            .get("roles")
            .and_then(Value::as_array)
            .map(|items| items.iter().map(parse_role).collect())
            .unwrap_or_default(),
    }
}

fn parse_role(value: &Value) -> EndfieldRole {
    EndfieldRole {
        role_id: first_non_empty(&[string_field(value, "roleId"), string_field(value, "id")]),
        server_id: first_non_empty(&[
            string_field(value, "serverId"),
            string_field(value, "server"),
        ]),
        role_nickname: first_non_empty(&[
            string_field(value, "nickname"),
            string_field(value, "nickName"),
            string_field(value, "name"),
        ]),
    }
}

fn parse_attendance_result(
    game: &str,
    character: &str,
    response: Result<String>,
) -> GameSignResult {
    match response {
        Err(err) => GameSignResult::SignFailed {
            game: game.to_owned(),
            character: Some(character.to_owned()),
            reason: err.to_string(),
        },
        Ok(raw) => match serde_json::from_str::<Value>(&raw) {
            Err(err) => GameSignResult::SignFailed {
                game: game.to_owned(),
                character: Some(character.to_owned()),
                reason: format!("签到响应 JSON 解析失败: {err}"),
            },
            Ok(json) => {
                if json.get("code").and_then(Value::as_i64) == Some(0) {
                    GameSignResult::SignSucceeded {
                        game: game.to_owned(),
                        character: character.to_owned(),
                        awards: parse_awards(&json),
                    }
                } else {
                    let message = message_of(&json);
                    if is_already_signed(&message) {
                        GameSignResult::AlreadySigned {
                            game: game.to_owned(),
                            character: character.to_owned(),
                            reason: message,
                        }
                    } else {
                        GameSignResult::SignFailed {
                            game: game.to_owned(),
                            character: Some(character.to_owned()),
                            reason: message,
                        }
                    }
                }
            }
        },
    }
}

fn parse_awards(json: &Value) -> Vec<Award> {
    if let Some(awards) = json.pointer("/data/awards").and_then(Value::as_array) {
        return awards.iter().map(parse_arknights_award).collect();
    }
    parse_endfield_awards(json)
}

fn parse_arknights_award(value: &Value) -> Award {
    Award {
        name: first_non_empty(&[
            value
                .pointer("/resource/name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            string_field(value, "name"),
        ]),
        count: int_field(value, "count"),
    }
}

fn parse_endfield_awards(json: &Value) -> Vec<Award> {
    let Some(ids) = json.pointer("/data/awardIds").and_then(Value::as_array) else {
        return Vec::new();
    };
    let resource_map = json
        .pointer("/data/resourceInfoMap")
        .and_then(Value::as_object);
    ids.iter()
        .filter_map(|item| {
            let award_id = first_non_empty(&[
                string_field(item, "id"),
                item.as_str().unwrap_or_default().to_owned(),
            ]);
            if award_id.is_empty() {
                return None;
            }
            let resource = resource_map.and_then(|map| map.get(&award_id));
            Some(Award {
                name: resource_name(&award_id, resource),
                count: resource
                    .and_then(|value| value.get("count"))
                    .and_then(Value::as_i64)
                    .unwrap_or(1)
                    .max(1),
            })
        })
        .collect()
}

fn resource_name(award_id: &str, resource: Option<&Value>) -> String {
    resource.map_or_else(
        || award_id.to_owned(),
        |value| {
            first_non_empty(&[
                string_field(value, "name"),
                value
                    .pointer("/resource/name")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                award_id.to_owned(),
            ])
        },
    )
}

fn message_of(json: &Value) -> String {
    first_non_empty(&[
        json.get("message")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        json.get("msg")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        "未知错误".to_owned(),
    ])
}

fn is_already_signed(message: &str) -> bool {
    ["已", "重复", "already", "signed"]
        .iter()
        .any(|needle| message.contains(needle))
}

fn string_field(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(|value| {
            value
                .as_str()
                .map(ToOwned::to_owned)
                .or_else(|| value.as_i64().map(|n| n.to_string()))
        })
        .unwrap_or_default()
}

fn int_field(value: &Value, key: &str) -> i64 {
    value
        .get(key)
        .and_then(|value| {
            value
                .as_i64()
                .or_else(|| value.as_str().and_then(|value| value.parse().ok()))
        })
        .unwrap_or(0)
}

fn first_non_empty(values: &[String]) -> String {
    values
        .iter()
        .find(|value| !value.is_empty())
        .cloned()
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_binding_groups() {
        let raw = r#"{"code":0,"data":{"list":[{"appCode":"arknights","bindingList":[{"gameName":"明日方舟","nickName":"博士","uid":"1","gameId":1}]}]}}"#;

        let bindings = parse_bindings(raw).unwrap();

        assert_eq!(bindings.len(), 1);
        assert_eq!(bindings[0].app_code, "arknights");
        assert_eq!(bindings[0].role_name, "博士");
    }
}
