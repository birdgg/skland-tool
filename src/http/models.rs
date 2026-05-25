use serde::{Deserialize, Deserializer};
use serde_json::Value;

#[derive(Debug, Deserialize)]
pub struct OAuthResponse {
    pub status: Option<i64>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub msg: Option<String>,
    pub data: Option<OAuthData>,
}

#[derive(Debug, Deserialize)]
pub struct OAuthData {
    #[serde(default, deserialize_with = "deserialize_stringish")]
    pub code: String,
}

#[derive(Debug, Deserialize)]
pub struct ApiResponse<T> {
    pub code: Option<i64>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub msg: Option<String>,
    pub data: Option<T>,
}

#[derive(Debug, Deserialize)]
pub struct CredentialData {
    #[serde(default, deserialize_with = "deserialize_stringish")]
    pub cred: String,
    #[serde(default, deserialize_with = "deserialize_stringish")]
    pub token: String,
}

#[derive(Debug, Deserialize)]
pub struct BindingListData {
    #[serde(default)]
    pub list: Vec<BindingGroup>,
}

#[derive(Debug, Deserialize)]
pub struct BindingGroup {
    #[serde(
        rename = "appCode",
        default,
        deserialize_with = "deserialize_stringish"
    )]
    pub app_code: String,
    #[serde(rename = "bindingList", default)]
    pub binding_list: Vec<BindingItem>,
}

#[derive(Debug, Deserialize)]
pub struct BindingItem {
    #[serde(
        rename = "gameName",
        default,
        deserialize_with = "deserialize_stringish"
    )]
    pub game_name: String,
    #[serde(
        rename = "nickName",
        default,
        deserialize_with = "deserialize_stringish"
    )]
    pub nick_name: String,
    #[serde(default, deserialize_with = "deserialize_stringish")]
    pub nickname: String,
    #[serde(default, deserialize_with = "deserialize_stringish")]
    pub name: String,
    #[serde(
        rename = "channelName",
        default,
        deserialize_with = "deserialize_stringish"
    )]
    pub channel_name: String,
    #[serde(default, deserialize_with = "deserialize_stringish")]
    pub uid: String,
    #[serde(rename = "gameId", default, deserialize_with = "deserialize_i64ish")]
    pub game_id: i64,
    #[serde(default)]
    pub roles: Vec<EndfieldRoleItem>,
}

#[derive(Debug, Deserialize)]
pub struct EndfieldRoleItem {
    #[serde(rename = "roleId", default, deserialize_with = "deserialize_stringish")]
    pub role_id: String,
    #[serde(default, deserialize_with = "deserialize_stringish")]
    pub id: String,
    #[serde(
        rename = "serverId",
        default,
        deserialize_with = "deserialize_stringish"
    )]
    pub server_id: String,
    #[serde(default, deserialize_with = "deserialize_stringish")]
    pub server: String,
    #[serde(default, deserialize_with = "deserialize_stringish")]
    pub nickname: String,
    #[serde(
        rename = "nickName",
        default,
        deserialize_with = "deserialize_stringish"
    )]
    pub nick_name: String,
    #[serde(default, deserialize_with = "deserialize_stringish")]
    pub name: String,
}

impl OAuthResponse {
    pub fn message(&self) -> String {
        first_non_empty([
            self.message.as_deref(),
            self.msg.as_deref(),
            Some("未知错误"),
        ])
    }
}

impl<T> ApiResponse<T> {
    pub fn message(&self) -> String {
        first_non_empty([
            self.message.as_deref(),
            self.msg.as_deref(),
            Some("未知错误"),
        ])
    }
}

fn first_non_empty<'a>(values: impl IntoIterator<Item = Option<&'a str>>) -> String {
    values
        .into_iter()
        .flatten()
        .find(|value| !value.is_empty())
        .unwrap_or_default()
        .to_owned()
}

fn deserialize_stringish<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<Value>::deserialize(deserializer)?;
    Ok(match value {
        Some(Value::String(value)) => value,
        Some(Value::Number(value)) => value.to_string(),
        Some(Value::Bool(value)) => value.to_string(),
        _ => String::new(),
    })
}

fn deserialize_i64ish<'de, D>(deserializer: D) -> Result<i64, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<Value>::deserialize(deserializer)?;
    Ok(match value {
        Some(Value::Number(value)) => value.as_i64().unwrap_or_default(),
        Some(Value::String(value)) => value.parse().unwrap_or_default(),
        _ => 0,
    })
}
