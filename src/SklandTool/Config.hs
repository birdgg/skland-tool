module SklandTool.Config
  ( configCodec
  , defaultConfigPath
  , loadConfig
  , parseGameType
  , validateConfig
  )
where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Toml
import Toml ((.=), TomlCodec)

import SklandTool.Types

defaultConfigPath :: FilePath
defaultConfigPath = "skland-tool.toml"

loadConfig :: FilePath -> IO (Either AppError AppConfig)
loadConfig path = do
  decoded <- Toml.decodeFileEither configCodec path
  pure $ case decoded of
    Left err -> Left $ ConfigError $ T.pack $ show err
    Right config -> validateConfig config

configCodec :: TomlCodec AppConfig
configCodec =
  AppConfig
    <$> Toml.text "token" .= configToken
    <*> Toml.textBy gameToText parseGameType "game" .= configGame
    <*> Toml.dioptional (Toml.text "device_id") .= configDeviceId
    <*> Toml.table scheduleCodec "schedule" .= configSchedule

scheduleCodec :: TomlCodec ScheduleConfig
scheduleCodec =
  ScheduleConfig
    <$> Toml.int "hour" .= scheduleHour
    <*> Toml.int "minute" .= scheduleMinute
    <*> Toml.dimap encodeTimezone decodeTimezone (Toml.dioptional (Toml.text "timezone")) .= scheduleTimezone
  where
    encodeTimezone zone =
      if zone == "Asia/Shanghai" || T.null zone
        then Nothing
        else Just zone
    decodeTimezone = maybe "Asia/Shanghai" id

parseGameType :: Text -> Either Text GameType
parseGameType = \case
  "all" -> Right AllGames
  "arknights" -> Right Arknights
  "endfield" -> Right Endfield
  other -> Left $ "game 必须是 all、arknights 或 endfield，当前值: " <> other

gameToText :: GameType -> Text
gameToText = \case
  AllGames -> "all"
  Arknights -> "arknights"
  Endfield -> "endfield"

validateConfig :: AppConfig -> Either AppError AppConfig
validateConfig config
  | T.null (T.strip config.configToken) = Left $ ConfigError "token 不能为空"
  | schedule.scheduleHour < 0 || schedule.scheduleHour > 23 =
      Left $ ConfigError "schedule.hour 必须在 0..23"
  | schedule.scheduleMinute < 0 || schedule.scheduleMinute > 59 =
      Left $ ConfigError "schedule.minute 必须在 0..59"
  | schedule.scheduleTimezone /= "Asia/Shanghai" =
      Left $ ConfigError "当前仅支持 schedule.timezone = \"Asia/Shanghai\""
  | otherwise = Right config
  where
    schedule = config.configSchedule
