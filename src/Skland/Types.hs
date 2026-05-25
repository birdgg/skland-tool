module Skland.Types
  ( AppConfig (..)
  , ScheduleConfig (..)
  , UserConfig (..)
  , GameType (..)
  , Credential (..)
  , Binding (..)
  , EndfieldRole (..)
  , Award (..)
  , GameSignResult (..)
  , UserSignReport (..)
  , HttpResult (..)
  , gameTypeFromInt
  , wantsArknights
  , wantsEndfield
  )
where

data AppConfig = AppConfig
  { schedule :: ScheduleConfig
  , users :: [UserConfig]
  , configuredDeviceId :: Maybe String
  , envFile :: FilePath
  }
  deriving (Eq, Show)

data ScheduleConfig = ScheduleConfig
  { hour :: Int
  , minute :: Int
  }
  deriving (Eq, Show)

data UserConfig = UserConfig
  { nickname :: String
  , userToken :: String
  , gameType :: GameType
  }
  deriving (Eq, Show)

data GameType
  = AllGames
  | ArknightsOnly
  | EndfieldOnly
  deriving (Eq, Show)

data Credential = Credential
  { cred :: String
  , token :: String
  }
  deriving (Eq, Show)

data Binding = Binding
  { appCode :: String
  , gameName :: String
  , roleName :: String
  , channelName :: String
  , uid :: String
  , gameId :: Int
  , roles :: [EndfieldRole]
  }
  deriving (Eq, Show)

data EndfieldRole = EndfieldRole
  { roleId :: String
  , serverId :: String
  , roleNickname :: String
  }
  deriving (Eq, Show)

data Award = Award
  { awardName :: String
  , awardCount :: Int
  }
  deriving (Eq, Show)

data GameSignResult
  = SignSucceeded
      { resultGame :: String
      , resultCharacter :: String
      , resultAwards :: [Award]
      }
  | AlreadySigned
      { resultGame :: String
      , resultCharacter :: String
      , resultReason :: String
      }
  | SignFailed
      { resultGame :: String
      , resultCharacterMaybe :: Maybe String
      , resultReason :: String
      }
  deriving (Eq, Show)

data UserSignReport = UserSignReport
  { reportUser :: String
  , reportResults :: [GameSignResult]
  }
  deriving (Eq, Show)

data HttpResult = HttpResult
  { httpStatus :: Int
  , httpBody :: String
  , httpError :: String
  }
  deriving (Eq, Show)

gameTypeFromInt :: Int -> Maybe GameType
gameTypeFromInt 0 = Just AllGames
gameTypeFromInt 1 = Just ArknightsOnly
gameTypeFromInt 2 = Just EndfieldOnly
gameTypeFromInt _ = Nothing

wantsArknights :: GameType -> Bool
wantsArknights AllGames = True
wantsArknights ArknightsOnly = True
wantsArknights EndfieldOnly = False

wantsEndfield :: GameType -> Bool
wantsEndfield AllGames = True
wantsEndfield ArknightsOnly = False
wantsEndfield EndfieldOnly = True
