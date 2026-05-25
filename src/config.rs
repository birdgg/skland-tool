use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};

use crate::types::{AppConfig, GameType, ScheduleConfig, UserConfig};

pub fn load_config(path: &Path) -> Result<AppConfig> {
    if !path.exists() {
        bail!("找不到 .env 文件: {}", path.display());
    }

    let env = read_env(path)?;
    let user = parse_user(&env)?;
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
        user,
        configured_device_id: lookup_many(&env, &["SKLAND_DID", "SKLAND_DEVICE_ID", "DID", "D_ID"])
            .cloned(),
        env_file: path.to_path_buf(),
    };
    check_config(&config)?;
    Ok(config)
}

pub fn check_config(config: &AppConfig) -> Result<()> {
    if config.user.user_token.is_empty() {
        bail!(".env 中没有找到用户 token");
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

fn parse_user(env: &HashMap<String, String>) -> Result<UserConfig> {
    let token =
        lookup_many(env, &["SKLAND_TOKEN"]).ok_or_else(|| anyhow!(".env 中没有找到用户 token"))?;
    Ok(UserConfig {
        user_token: token.clone(),
        game_type: game_type_from_env(env),
    })
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
    fn parses_single_user() {
        let env = HashMap::from([
            ("SKLAND_TOKEN".to_owned(), "single".to_owned()),
            ("SKLAND_GAME_TYPE".to_owned(), "2".to_owned()),
        ]);

        let user = parse_user(&env).unwrap();

        assert_eq!(user.user_token, "single");
        assert_eq!(user.game_type, GameType::EndfieldOnly);
    }

    #[test]
    fn legacy_env_allows_unquoted_spaces() {
        let env = parse_legacy_env("SOME_VALUE=我的 大号\nSKLAND_TOKEN=abc # 注释\n");

        assert_eq!(env.get("SOME_VALUE").map(String::as_str), Some("我的 大号"));
        assert_eq!(env.get("SKLAND_TOKEN").map(String::as_str), Some("abc"));
    }
}
