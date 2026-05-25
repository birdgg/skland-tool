use std::io::ErrorKind;
use std::path::Path;

use anyhow::{Context, Result};
use chrono::Utc;
use uuid::Uuid;

use crate::config::cache_dir;
use crate::http::SklandClient;
use crate::types::{AppConfig, Binding, Credential, GameSignResult, UserConfig, UserSignReport};

pub async fn run_all_users(config: &AppConfig, client: &SklandClient) -> Vec<UserSignReport> {
    let did = match get_device_id(config) {
        Ok(did) => did,
        Err(err) => {
            return config
                .users
                .iter()
                .map(|user| UserSignReport {
                    user: user.nickname.clone(),
                    results: vec![GameSignResult::SignFailed {
                        game: "设备 ID".to_owned(),
                        character: None,
                        reason: format_error(&err),
                    }],
                })
                .collect();
        }
    };
    println!("使用设备 ID: {}", mask(&did));

    let mut reports = Vec::with_capacity(config.users.len());
    for user in &config.users {
        reports.push(run_user(client, &did, user).await);
    }
    if let Err(err) = save_last_report(&reports) {
        eprintln!("保存最后报告失败: {err}");
    }
    reports
}

async fn run_user(client: &SklandClient, did: &str, user: &UserConfig) -> UserSignReport {
    println!("开始签到用户: {}", user.nickname);
    let results = match run_user_inner(client, did, user).await {
        Ok(results) => results,
        Err(err) => vec![GameSignResult::SignFailed {
            game: "森空岛".to_owned(),
            character: None,
            reason: format_error(&err),
        }],
    };
    UserSignReport {
        user: user.nickname.clone(),
        results,
    }
}

async fn run_user_inner(
    client: &SklandClient,
    did: &str,
    user: &UserConfig,
) -> Result<Vec<GameSignResult>> {
    let code = client
        .get_authorization(did, user)
        .await
        .context("森空岛授权")?;
    let credential = client
        .get_credential(did, &code)
        .await
        .context("森空岛凭据")?;
    let bindings = client
        .get_binding_list(did, &credential)
        .await
        .context("绑定角色查询")?;
    Ok(run_bindings(client, did, &credential, user, &bindings).await)
}

async fn run_bindings(
    client: &SklandClient,
    did: &str,
    credential: &Credential,
    user: &UserConfig,
    bindings: &[Binding],
) -> Vec<GameSignResult> {
    let mut results = Vec::new();

    if user.game_type.wants_arknights() {
        let arknights = bindings
            .iter()
            .filter(|binding| binding.app_code.eq_ignore_ascii_case("arknights"))
            .collect::<Vec<_>>();
        if arknights.is_empty() {
            results.push(GameSignResult::SignFailed {
                game: "明日方舟".to_owned(),
                character: None,
                reason: "未找到明日方舟绑定角色".to_owned(),
            });
        } else {
            for binding in arknights {
                results.push(client.sign_arknights(did, credential, binding).await);
            }
        }
    }

    if user.game_type.wants_endfield() {
        let endfields = bindings
            .iter()
            .filter(|binding| binding.app_code.eq_ignore_ascii_case("endfield"))
            .collect::<Vec<_>>();
        if endfields.is_empty() {
            results.push(GameSignResult::SignFailed {
                game: "终末地".to_owned(),
                character: None,
                reason: "未找到终末地绑定角色".to_owned(),
            });
        } else {
            for binding in endfields {
                if binding.roles.is_empty() {
                    results.push(GameSignResult::SignFailed {
                        game: "终末地".to_owned(),
                        character: Some(binding.role_name.clone()),
                        reason: "绑定数据中没有终末地角色 roles".to_owned(),
                    });
                } else {
                    for role in &binding.roles {
                        results.push(client.sign_endfield(did, credential, binding, role).await);
                    }
                }
            }
        }
    }

    results
}

pub fn get_device_id(config: &AppConfig) -> Result<String> {
    if let Some(did) = &config.configured_device_id
        && !did.is_empty()
    {
        return Ok(did.clone());
    }

    let path = cache_dir()?.join("device.env");
    match std::fs::read_to_string(&path) {
        Ok(raw) => match parse_device_id(&raw) {
            Some(did) => Ok(did),
            None => create_device_id(&path),
        },
        Err(err) if err.kind() == ErrorKind::NotFound => create_device_id(&path),
        Err(err) => Err(err).with_context(|| format!("读取设备 ID 缓存失败: {}", path.display())),
    }
}

fn create_device_id(path: &Path) -> Result<String> {
    let did = generated_device_id();
    std::fs::write(path, format!("SKLAND_DID={did}\n"))
        .with_context(|| format!("写入设备 ID 缓存失败: {}", path.display()))?;
    Ok(did)
}

fn generated_device_id() -> String {
    format!("B{}", Uuid::new_v4().simple())
}

fn parse_device_id(raw: &str) -> Option<String> {
    raw.lines().find_map(|line| {
        let (key, value) = line.split_once('=')?;
        (key.trim() == "SKLAND_DID")
            .then(|| value.trim().to_owned())
            .filter(|value| !value.is_empty())
    })
}

fn save_last_report(reports: &[UserSignReport]) -> Result<()> {
    let path = cache_dir()?.join("last-report.txt");
    let header = format!("time={}", Utc::now().format("%Y-%m-%dT%H:%M:%SZ"));
    let mut lines = vec![header];
    lines.extend(render_reports(reports));
    std::fs::write(&path, format!("{}\n", lines.join("\n")))
        .with_context(|| format!("写入最后报告失败: {}", path.display()))
}

pub fn print_reports(reports: &[UserSignReport]) {
    for line in render_reports(reports) {
        println!("{line}");
    }
}

fn render_reports(reports: &[UserSignReport]) -> Vec<String> {
    reports.iter().flat_map(render_user_report).collect()
}

fn render_user_report(report: &UserSignReport) -> Vec<String> {
    let mut lines = vec![format!("用户: {}", report.user)];
    lines.extend(report.results.iter().map(render_result));
    lines
}

fn render_result(result: &GameSignResult) -> String {
    match result {
        GameSignResult::SignSucceeded {
            game,
            character,
            awards,
        } => format!("  [成功] {game} / {character}{}", render_awards(awards)),
        GameSignResult::AlreadySigned {
            game,
            character,
            reason,
        } => format!("  [已签到] {game} / {character} - {reason}"),
        GameSignResult::SignFailed {
            game,
            character: None,
            reason,
        } => format!("  [失败] {game} - {reason}"),
        GameSignResult::SignFailed {
            game,
            character: Some(character),
            reason,
        } => format!("  [失败] {game} / {character} - {reason}"),
    }
}

fn render_awards(awards: &[crate::types::Award]) -> String {
    if awards.is_empty() {
        String::new()
    } else {
        let rendered = awards
            .iter()
            .map(|award| format!("{} x{}", award.name, award.count))
            .collect::<Vec<_>>()
            .join(", ");
        format!(" - {rendered}")
    }
}

fn mask(value: &str) -> String {
    if value.len() <= 8 {
        "*".repeat(value.len())
    } else {
        format!("{}...{}", &value[..4], &value[value.len() - 4..])
    }
}

fn format_error(err: &anyhow::Error) -> String {
    err.chain()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(": ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_cached_device_id() {
        assert_eq!(
            parse_device_id("SKLAND_DID=Babc\n").as_deref(),
            Some("Babc")
        );
    }

    #[test]
    fn renders_awards() {
        let text = render_awards(&[crate::types::Award {
            name: "合成玉".to_owned(),
            count: 200,
        }]);
        assert_eq!(text, " - 合成玉 x200");
    }
}
