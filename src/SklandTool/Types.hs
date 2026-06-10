module SklandTool.Types
  ( AppConfig (..)
  , AppError (..)
  , Award (..)
  , Binding (..)
  , Credential (..)
  , EndfieldRole (..)
  , GameType (..)
  , Runtime (..)
  , ScheduleConfig (..)
  , SignResult (..)
  , renderAppError
  , wantsArknights
  , wantsEndfield
  )
where

import Control.Exception (Exception (displayException))
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Client (Manager)

data GameType
  = AllGames
  | Arknights
  | Endfield
  deriving stock (Eq, Show)

wantsArknights :: GameType -> Bool
wantsArknights = \case
  AllGames -> True
  Arknights -> True
  Endfield -> False

wantsEndfield :: GameType -> Bool
wantsEndfield = \case
  AllGames -> True
  Arknights -> False
  Endfield -> True

data ScheduleConfig = ScheduleConfig
  { scheduleHour :: !Int
  , scheduleMinute :: !Int
  , scheduleTimezone :: !Text
  }
  deriving stock (Eq, Show)

data AppConfig = AppConfig
  { configToken :: !Text
  , configGame :: !GameType
  , configDeviceId :: !(Maybe Text)
  , configSchedule :: !ScheduleConfig
  }
  deriving stock (Eq, Show)

data Credential = Credential
  { credentialCred :: !Text
  , credentialToken :: !Text
  }
  deriving stock (Eq, Show)

data EndfieldRole = EndfieldRole
  { roleId :: !Text
  , roleServerId :: !Text
  , roleNickname :: !Text
  }
  deriving stock (Eq, Show)

data Binding = Binding
  { bindingAppCode :: !Text
  , bindingGameName :: !Text
  , bindingRoleName :: !Text
  , bindingChannelName :: !Text
  , bindingUid :: !Text
  , bindingGameId :: !Int64
  , bindingRoles :: ![EndfieldRole]
  }
  deriving stock (Eq, Show)

data Award = Award
  { awardName :: !Text
  , awardCount :: !Int64
  }
  deriving stock (Eq, Show)

data SignResult
  = SignSucceeded !Text !Text ![Award]
  | AlreadySigned !Text !Text !Text
  | SignFailed !Text !(Maybe Text) !Text
  deriving stock (Eq, Show)

data AppError
  = ConfigError !Text
  | HttpError !Text
  | ParseError !Text
  | StorageError !Text
  | SchedulerError !Text
  deriving stock (Eq, Show)

renderAppError :: AppError -> Text
renderAppError = \case
  ConfigError message -> "配置错误: " <> message
  HttpError message -> "HTTP 错误: " <> message
  ParseError message -> "解析错误: " <> message
  StorageError message -> "存储错误: " <> message
  SchedulerError message -> "调度错误: " <> message

instance Exception AppError where
  displayException = T.unpack . renderAppError

data Runtime = Runtime
  { runtimeConfig :: !AppConfig
  , runtimeManager :: !Manager
  , runtimeCacheDir :: !FilePath
  }
