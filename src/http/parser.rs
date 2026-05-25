use anyhow::{Context, Result, anyhow, bail};
use serde_json::Value;

use super::models::{
    ApiResponse, BindingGroup, BindingItem, BindingListData, CredentialData, EndfieldRoleItem,
    OAuthResponse,
};
use crate::types::{Award, Binding, Credential, EndfieldRole, GameSignResult};

type CredentialResponse = ApiResponse<CredentialData>;
type BindingListResponse = ApiResponse<BindingListData>;
type AttendanceResponse = ApiResponse<Value>;

pub fn parse_authorization(raw: &str) -> Result<String> {
    let response: OAuthResponse = serde_json::from_str(raw).context("OAuth 响应 JSON 解析失败")?;
    match response.status {
        Some(0) => response
            .data
            .map(|data| data.code)
            .filter(|code| !code.is_empty())
            .ok_or_else(|| anyhow!("OAuth 响应缺少 data.code")),
        status => bail!("OAuth 授权失败: {} status={status:?}", response.message()),
    }
}

pub fn parse_credential(raw: &str) -> Result<Credential> {
    let response: CredentialResponse =
        serde_json::from_str(raw).context("credential 响应 JSON 解析失败")?;
    match response.code {
        Some(0) => {
            let data = response
                .data
                .ok_or_else(|| anyhow!("credential 响应缺少 data"))?;
            if data.cred.is_empty() {
                bail!("credential 响应缺少 data.cred");
            }
            if data.token.is_empty() {
                bail!("credential 响应缺少 data.token");
            }
            Ok(Credential {
                cred: data.cred,
                token: data.token,
            })
        }
        code => bail!("credential 生成失败: {} code={code:?}", response.message()),
    }
}

pub fn parse_bindings(raw: &str) -> Result<Vec<Binding>> {
    let response: BindingListResponse =
        serde_json::from_str(raw).context("绑定响应 JSON 解析失败")?;
    match response.code {
        Some(0) => {
            let data = response
                .data
                .ok_or_else(|| anyhow!("绑定响应缺少 data.list"))?;
            Ok(data.list.iter().flat_map(parse_group).collect())
        }
        code => bail!("查询绑定角色失败: {} code={code:?}", response.message()),
    }
}

fn parse_group(group: &BindingGroup) -> Vec<Binding> {
    group
        .binding_list
        .iter()
        .map(|item| parse_binding(&group.app_code, item))
        .collect()
}

fn parse_binding(app_code: &str, value: &BindingItem) -> Binding {
    Binding {
        app_code: app_code.to_owned(),
        game_name: value.game_name.clone(),
        role_name: first_non_empty([
            value.nick_name.as_str(),
            value.nickname.as_str(),
            value.name.as_str(),
        ]),
        channel_name: value.channel_name.clone(),
        uid: value.uid.clone(),
        game_id: value.game_id,
        roles: value.roles.iter().map(parse_role).collect(),
    }
}

fn parse_role(value: &EndfieldRoleItem) -> EndfieldRole {
    EndfieldRole {
        role_id: first_non_empty([value.role_id.as_str(), value.id.as_str()]),
        server_id: first_non_empty([value.server_id.as_str(), value.server.as_str()]),
        role_nickname: first_non_empty([
            value.nickname.as_str(),
            value.nick_name.as_str(),
            value.name.as_str(),
        ]),
    }
}

pub fn parse_attendance_result(
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
        Ok(raw) => parse_attendance_body(game, character, &raw),
    }
}

fn parse_attendance_body(game: &str, character: &str, raw: &str) -> GameSignResult {
    let response = match serde_json::from_str::<AttendanceResponse>(raw) {
        Ok(response) => response,
        Err(err) => {
            return GameSignResult::SignFailed {
                game: game.to_owned(),
                character: Some(character.to_owned()),
                reason: format!("签到响应 JSON 解析失败: {err}"),
            };
        }
    };

    if response.code == Some(0) {
        GameSignResult::SignSucceeded {
            game: game.to_owned(),
            character: character.to_owned(),
            awards: response.data.as_ref().map_or_else(Vec::new, parse_awards),
        }
    } else {
        let message = response.message();
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

fn parse_awards(data: &Value) -> Vec<Award> {
    if let Some(awards) = data.get("awards").and_then(Value::as_array) {
        return awards.iter().map(parse_arknights_award).collect();
    }
    parse_endfield_awards(data)
}

fn parse_arknights_award(value: &Value) -> Award {
    Award {
        name: first_non_empty([
            value
                .pointer("/resource/name")
                .and_then(Value::as_str)
                .unwrap_or_default(),
            string_field(value, "name").as_str(),
        ]),
        count: int_field(value, "count"),
    }
}

fn parse_endfield_awards(data: &Value) -> Vec<Award> {
    let Some(ids) = data.get("awardIds").and_then(Value::as_array) else {
        return Vec::new();
    };
    let resource_map = data.get("resourceInfoMap").and_then(Value::as_object);
    ids.iter()
        .filter_map(|item| {
            let award_id = first_non_empty([
                string_field(item, "id").as_str(),
                item.as_str().unwrap_or_default(),
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
            first_non_empty([
                string_field(value, "name").as_str(),
                value
                    .pointer("/resource/name")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                award_id,
            ])
        },
    )
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

fn first_non_empty<'a>(values: impl IntoIterator<Item = &'a str>) -> String {
    values
        .into_iter()
        .find(|value| !value.is_empty())
        .unwrap_or_default()
        .to_owned()
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

    #[test]
    fn parses_stringish_binding_fields() {
        let raw = r#"{"code":0,"data":{"list":[{"appCode":"arknights","bindingList":[{"uid":123,"gameId":"1"}]}]}}"#;

        let bindings = parse_bindings(raw).unwrap();

        assert_eq!(bindings[0].uid, "123");
        assert_eq!(bindings[0].game_id, 1);
    }
}
