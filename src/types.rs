use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppConfig {
    pub schedule: ScheduleConfig,
    pub user: UserConfig,
    pub configured_device_id: Option<String>,
    pub env_file: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScheduleConfig {
    pub hour: u32,
    pub minute: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UserConfig {
    pub user_token: String,
    pub game_type: GameType,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GameType {
    AllGames,
    ArknightsOnly,
    EndfieldOnly,
}

impl GameType {
    pub const fn from_int(value: i32) -> Option<Self> {
        match value {
            0 => Some(Self::AllGames),
            1 => Some(Self::ArknightsOnly),
            2 => Some(Self::EndfieldOnly),
            _ => None,
        }
    }

    pub const fn wants_arknights(self) -> bool {
        matches!(self, Self::AllGames | Self::ArknightsOnly)
    }

    pub const fn wants_endfield(self) -> bool {
        matches!(self, Self::AllGames | Self::EndfieldOnly)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Credential {
    pub cred: String,
    pub token: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Binding {
    pub app_code: String,
    pub game_name: String,
    pub role_name: String,
    pub channel_name: String,
    pub uid: String,
    pub game_id: i64,
    pub roles: Vec<EndfieldRole>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EndfieldRole {
    pub role_id: String,
    pub server_id: String,
    pub role_nickname: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Award {
    pub name: String,
    pub count: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GameSignResult {
    SignSucceeded {
        game: String,
        character: String,
        awards: Vec<Award>,
    },
    AlreadySigned {
        game: String,
        character: String,
        reason: String,
    },
    SignFailed {
        game: String,
        character: Option<String>,
        reason: String,
    },
}
