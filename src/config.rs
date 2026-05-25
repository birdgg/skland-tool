use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};

use crate::types::{AppConfig, GameType, ScheduleConfig, UserConfig};

pub fn load_config(path: &Path) -> Result<AppConfig> {
    if !path.exists() {
        bail!("找不到 .env 文件: {}", path.display());
    }

    let env = read_env(path)?;
    let users = parse_users(&env)?;
    let schedule = ScheduleConfig {
        hour: read_u32_default(
            6,
            lookup_many(&env, &["SKLAND_SCHEDULE_HOUR", "SCHEDULE_HOUR"]),
        ),
        minute: read_u32_default(
            0,
            lookup_many(&env, &["SKLAND_SCHEDULE_MINUTE", "SCHEDULE_MINUTE"]),
        ),
    };
    let config = AppConfig {
        schedule,
        users,
        configured_device_id: lookup_many(&env, &["SKLAND_DID", "SKLAND_DEVICE_ID", "DID", "D_ID"])
            .cloned(),
        env_file: path.to_path_buf(),
    };
    check_config(&config)?;
    Ok(config)
}

pub fn check_config(config: &AppConfig) -> Result<()> {
    if config.users.is_empty() {
        bail!(".env 中没有找到用户 token");
    }
    if config.users.iter().any(|user| user.user_token.is_empty()) {
        bail!("存在空 token");
    }
    if config.schedule.hour > 23 {
        bail!("SKLAND_SCHEDULE_HOUR 必须在 0..23");
    }
    if config.schedule.minute > 59 {
        bail!("SKLAND_SCHEDULE_MINUTE 必须在 0..59");
    }
    Ok(())
}

pub fn cache_dir() -> Result<PathBuf> {
    let dir = dirs::config_dir()
        .ok_or_else(|| anyhow!("无法定位用户配置目录"))?
        .join("skland-tool");
    std::fs::create_dir_all(&dir)
        .with_context(|| format!("无法创建缓存目录: {}", dir.display()))?;
    Ok(dir)
}

fn read_env(path: &Path) -> Result<HashMap<String, String>> {
    let Ok(iter) = dotenvy::from_path_iter(path) else {
        return read_legacy_env(path);
    };
    let mut env = HashMap::new();
    for item in iter {
        let Ok((key, value)) = item else {
            return read_legacy_env(path);
        };
        env.insert(key.trim().to_ascii_uppercase(), value.trim().to_owned());
    }
    Ok(env)
}

fn read_legacy_env(path: &Path) -> Result<HashMap<String, String>> {
    let raw = std::fs::read_to_string(path)
        .with_context(|| format!("无法读取 env 文件: {}", path.display()))?;
    Ok(parse_legacy_env(&raw))
}

fn parse_legacy_env(raw: &str) -> HashMap<String, String> {
    raw.lines()
        .filter_map(|line| {
            let stripped = line.split('#').next().unwrap_or_default().trim();
            let (key, value) = stripped.split_once('=')?;
            Some((
                key.trim().to_ascii_uppercase(),
                unquote(value.trim()).to_owned(),
            ))
        })
        .collect()
}

fn unquote(value: &str) -> &str {
    if value.len() >= 2
        && ((value.starts_with('"') && value.ends_with('"'))
            || (value.starts_with('\'') && value.ends_with('\'')))
    {
        &value[1..value.len() - 1]
    } else {
        value
    }
}

fn parse_users(env: &HashMap<String, String>) -> Result<Vec<UserConfig>> {
    let numbered = parse_numbered_users(env);
    if !numbered.is_empty() {
        return Ok(numbered);
    }

    if let Some(token) = lookup_many(env, &["SKLAND_TOKEN", "SKLAND_USER_TOKEN", "USER_TOKEN"]) {
        return Ok(vec![UserConfig {
            nickname: lookup_many(env, &["SKLAND_NICKNAME", "NICKNAME"])
                .cloned()
                .unwrap_or_else(|| "default".to_owned()),
            user_token: token.clone(),
            game_type: game_type_from_env(env),
        }]);
    }

    if let Some(value) = lookup_many(env, &["SKLAND_USERS"]) {
        return value
            .split(',')
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(parse_packed_user)
            .collect();
    }

    Ok(Vec::new())
}

fn parse_numbered_users(env: &HashMap<String, String>) -> Vec<UserConfig> {
    (1..=20)
        .filter_map(|n| {
            let token_key = format!("SKLAND_USER_{n}_TOKEN");
            let token = env.get(&token_key)?;
            let nickname = env
                .get(&format!("SKLAND_USER_{n}_NICKNAME"))
                .cloned()
                .unwrap_or_else(|| format!("user-{n}"));
            let game_type = read_game_type(env.get(&format!("SKLAND_USER_{n}_GAME_TYPE")));
            Some(UserConfig {
                nickname,
                user_token: token.clone(),
                game_type,
            })
        })
        .collect()
}

fn parse_packed_user(value: &str) -> Result<UserConfig> {
    let parts = value.split(':').map(str::trim).collect::<Vec<_>>();
    match parts.as_slice() {
        [name, token] => Ok(UserConfig {
            nickname: (*name).to_owned(),
            user_token: (*token).to_owned(),
            game_type: GameType::AllGames,
        }),
        [name, token, game_type] => {
            let raw = game_type.parse::<i32>().unwrap_or(0);
            let game_type =
                GameType::from_int(raw).ok_or_else(|| anyhow!("非法 game_type: {game_type}"))?;
            Ok(UserConfig {
                nickname: (*name).to_owned(),
                user_token: (*token).to_owned(),
                game_type,
            })
        }
        _ => bail!("SKLAND_USERS 格式应为 nickname:token[:game_type],nickname2:token2[:game_type]"),
    }
}

fn game_type_from_env(env: &HashMap<String, String>) -> GameType {
    read_game_type(lookup_many(env, &["SKLAND_GAME_TYPE", "GAME_TYPE"]))
}

fn read_game_type(raw: Option<&String>) -> GameType {
    let value = raw.and_then(|value| value.parse::<i32>().ok()).unwrap_or(0);
    GameType::from_int(value).unwrap_or(GameType::AllGames)
}

fn read_u32_default(fallback: u32, raw: Option<&String>) -> u32 {
    raw.and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(fallback)
}

fn lookup_many<'a>(env: &'a HashMap<String, String>, keys: &[&str]) -> Option<&'a String> {
    keys.iter()
        .find_map(|key| env.get(&key.to_ascii_uppercase()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_numbered_users_first() {
        let env = HashMap::from([
            ("SKLAND_TOKEN".to_owned(), "single".to_owned()),
            ("SKLAND_USER_1_TOKEN".to_owned(), "numbered".to_owned()),
            ("SKLAND_USER_1_GAME_TYPE".to_owned(), "2".to_owned()),
        ]);

        let users = parse_users(&env).unwrap();

        assert_eq!(users.len(), 1);
        assert_eq!(users[0].user_token, "numbered");
        assert_eq!(users[0].game_type, GameType::EndfieldOnly);
    }

    #[test]
    fn legacy_env_allows_unquoted_spaces() {
        let env = parse_legacy_env("SKLAND_NICKNAME=我的 大号\nSKLAND_TOKEN=abc # 注释\n");

        assert_eq!(
            env.get("SKLAND_NICKNAME").map(String::as_str),
            Some("我的 大号")
        );
        assert_eq!(env.get("SKLAND_TOKEN").map(String::as_str), Some("abc"));
    }
}
