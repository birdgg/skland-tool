module Skland.Config
  ( loadConfig
  , checkConfig
  , cacheDir
  )
where

import Data.Char (isSpace, toUpper)
import Data.List (isPrefixOf)
import System.Directory (XdgDirectory (XdgConfig), createDirectoryIfMissing, doesFileExist, getXdgDirectory)

import Skland.Types

loadConfig :: FilePath -> IO (Either String AppConfig)
loadConfig path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left ("找不到 .env 文件: " <> path))
    else do
      raw <- readFile path
      let env = parseEnv raw
      pure (mkConfig path env)

checkConfig :: AppConfig -> Either String ()
checkConfig config
  | null (users config) = Left ".env 中没有找到用户 token"
  | any (null . userToken) (users config) = Left "存在空 token"
  | hour (schedule config) < 0 || hour (schedule config) > 23 = Left "SKLAND_SCHEDULE_HOUR 必须在 0..23"
  | minute (schedule config) < 0 || minute (schedule config) > 59 = Left "SKLAND_SCHEDULE_MINUTE 必须在 0..59"
  | otherwise = Right ()

cacheDir :: IO FilePath
cacheDir = do
  dir <- getXdgDirectory XdgConfig "skland-tool"
  createDirectoryIfMissing True dir
  pure dir

mkConfig :: FilePath -> [(String, String)] -> Either String AppConfig
mkConfig path env = do
  parsedUsers <- parseUsers env
  let parsedSchedule =
        ScheduleConfig
          { hour = readIntDefault 6 (lookupMany ["SKLAND_SCHEDULE_HOUR", "SCHEDULE_HOUR"] env)
          , minute = readIntDefault 0 (lookupMany ["SKLAND_SCHEDULE_MINUTE", "SCHEDULE_MINUTE"] env)
          }
  let config =
        AppConfig
          { schedule = parsedSchedule
          , users = parsedUsers
          , configuredDeviceId = lookupMany ["SKLAND_DID", "SKLAND_DEVICE_ID", "DID", "D_ID"] env
          , envFile = path
          }
  case checkConfig config of
    Left err -> Left err
    Right () -> Right config

parseUsers :: [(String, String)] -> Either String [UserConfig]
parseUsers env =
  case parseNumberedUsers env of
    [] ->
      case lookupMany ["SKLAND_TOKEN", "SKLAND_USER_TOKEN", "USER_TOKEN"] env of
        Just singleToken ->
          pure
            [ UserConfig
                { nickname = maybe "default" id (lookupMany ["SKLAND_NICKNAME", "NICKNAME"] env)
                , userToken = singleToken
                , gameType = gameTypeFromEnv env
                }
            ]
        Nothing ->
          case lookupMany ["SKLAND_USERS"] env of
            Just value -> traverse parsePackedUser (splitComma value)
            Nothing -> pure []
    numbered -> pure numbered

parseNumberedUsers :: [(String, String)] -> [UserConfig]
parseNumberedUsers env =
  [ UserConfig
      { nickname = maybe ("user-" <> show n) id (lookupKey ("SKLAND_USER_" <> show n <> "_NICKNAME") env)
      , userToken = tokenValue
      , gameType = readGameType (lookupKey ("SKLAND_USER_" <> show n <> "_GAME_TYPE") env)
      }
  | n <- [1 .. 20 :: Int]
  , Just tokenValue <- [lookupKey ("SKLAND_USER_" <> show n <> "_TOKEN") env]
  ]

parsePackedUser :: String -> Either String UserConfig
parsePackedUser value =
  case splitColon value of
    [name, tok] ->
      pure (UserConfig (trim name) (trim tok) AllGames)
    [name, tok, gt] ->
      case gameTypeFromInt (readIntDefault 0 (Just (trim gt))) of
        Just parsed -> pure (UserConfig (trim name) (trim tok) parsed)
        Nothing -> Left ("非法 game_type: " <> gt)
    _ -> Left "SKLAND_USERS 格式应为 nickname:token[:game_type],nickname2:token2[:game_type]"

gameTypeFromEnv :: [(String, String)] -> GameType
gameTypeFromEnv env = readGameType (lookupMany ["SKLAND_GAME_TYPE", "GAME_TYPE"] env)

readGameType :: Maybe String -> GameType
readGameType raw =
  case gameTypeFromInt (readIntDefault 0 raw) of
    Just gt -> gt
    Nothing -> AllGames

parseEnv :: String -> [(String, String)]
parseEnv = foldr parseLine [] . lines
  where
    parseLine line acc =
      let stripped = trim (takeWhile (/= '#') line)
       in if null stripped || notElem '=' stripped
            then acc
            else
              let (key, rest) = break (== '=') stripped
                  value = drop 1 rest
               in (map toUpper (trim key), unquote (trim value)) : acc

lookupMany :: [String] -> [(String, String)] -> Maybe String
lookupMany keys env = firstJust [lookupKey key env | key <- keys]

lookupKey :: String -> [(String, String)] -> Maybe String
lookupKey key env = lookup (map toUpper key) env

firstJust :: [Maybe a] -> Maybe a
firstJust [] = Nothing
firstJust (Just x : _) = Just x
firstJust (Nothing : xs) = firstJust xs

readIntDefault :: Int -> Maybe String -> Int
readIntDefault fallback Nothing = fallback
readIntDefault fallback (Just value) =
  case reads value of
    [(n, "")] -> n
    _ -> fallback

splitComma :: String -> [String]
splitComma = filter (not . null) . map trim . splitOn ','

splitColon :: String -> [String]
splitColon = map trim . splitOn ':'

splitOn :: Char -> String -> [String]
splitOn delimiter input =
  case break (== delimiter) input of
    (chunk, []) -> [chunk]
    (chunk, _ : rest) -> chunk : splitOn delimiter rest

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

unquote :: String -> String
unquote value
  | "\"" `isPrefixOf` value && lastMay value == Just '"' = drop 1 (init value)
  | "'" `isPrefixOf` value && lastMay value == Just '\'' = drop 1 (init value)
  | otherwise = value

lastMay :: [a] -> Maybe a
lastMay [] = Nothing
lastMay xs = Just (last xs)
