module Skland.App
  ( runAllUsers
  , printReports
  , getDeviceId
  )
where

import Control.Exception (IOException, catch)
import Control.Monad (forM)
import Data.Char (isSpace, toLower)
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

import Skland.Config (cacheDir)
import Skland.Http
import Skland.Types

runAllUsers :: AppConfig -> IO [UserSignReport]
runAllUsers config = do
  did <- getDeviceId config
  putStrLn ("使用设备 ID: " <> mask did)
  reports <- forM (users config) (runUser did)
  saveLastReport reports
  pure reports

runUser :: String -> UserConfig -> IO UserSignReport
runUser did user = do
  putStrLn ("开始签到用户: " <> nickname user)
  auth <- getAuthorization did user
  case auth of
    Left err -> pure (UserSignReport (nickname user) [SignFailed "森空岛授权" Nothing err])
    Right code -> do
      credential <- getCredential did code
      case credential of
        Left err -> pure (UserSignReport (nickname user) [SignFailed "森空岛凭据" Nothing err])
        Right credValue -> do
          bindingResult <- getBindingList did credValue
          case bindingResult of
            Left err -> pure (UserSignReport (nickname user) [SignFailed "绑定角色查询" Nothing err])
            Right bindings -> do
              results <- runBindings did credValue user bindings
              pure (UserSignReport (nickname user) results)

runBindings :: String -> Credential -> UserConfig -> [Binding] -> IO [GameSignResult]
runBindings did credential user bindings = do
  arknightsResults <-
    if wantsArknights (gameType user)
      then do
        let arks = filter ((== "arknights") . lower . appCode) bindings
        if null arks
          then pure [SignFailed "明日方舟" Nothing "未找到明日方舟绑定角色"]
          else mapM (signArknights did credential) arks
      else pure []
  endfieldResults <-
    if wantsEndfield (gameType user)
      then do
        let endfields = filter ((== "endfield") . lower . appCode) bindings
        if null endfields
          then pure [SignFailed "终末地" Nothing "未找到终末地绑定角色"]
          else fmap concat (mapM signEndfieldBinding endfields)
      else pure []
  pure (arknightsResults <> endfieldResults)
  where
    signEndfieldBinding binding =
      if null (roles binding)
        then pure [SignFailed "终末地" (Just (roleName binding)) "绑定数据中没有终末地角色 roles"]
        else mapM (signEndfield did credential binding) (roles binding)

getDeviceId :: AppConfig -> IO String
getDeviceId config =
  case configuredDeviceId config of
    Just did | not (null did) -> pure did
    _ -> do
      dir <- cacheDir
      let path = dir </> "device.env"
      exists <- doesFileExist path
      if exists
        then do
          raw <- readFile path
          case parseDeviceId raw of
            Just did | not (null did) -> pure did
            _ -> createDeviceId path
        else createDeviceId path

createDeviceId :: FilePath -> IO String
createDeviceId path = do
  did <- generatedDeviceId
  writeFile path ("SKLAND_DID=" <> did <> "\n")
  pure did

generatedDeviceId :: IO String
generatedDeviceId = do
  now <- getPOSIXTime
  let seed = show (floor (now * 1000000) :: Integer)
  pure ("B" <> take 32 (cycle (fnvHex seed)))

parseDeviceId :: String -> Maybe String
parseDeviceId raw =
  case [drop 1 rest | line <- lines raw, let (key, rest) = break (== '=') line, trim key == "SKLAND_DID", not (null rest)] of
    did : _ -> Just (trim did)
    [] -> Nothing

saveLastReport :: [UserSignReport] -> IO ()
saveLastReport reports = do
  dir <- cacheDir
  now <- getCurrentTime
  let path = dir </> "last-report.txt"
      header = "time=" <> formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now
  writeFile path (unlines (header : renderReports reports))
    `catch` \(_ :: IOException) -> pure ()

printReports :: [UserSignReport] -> IO ()
printReports reports = mapM_ putStrLn (renderReports reports)

renderReports :: [UserSignReport] -> [String]
renderReports = concatMap renderUserReport

renderUserReport :: UserSignReport -> [String]
renderUserReport report =
  ("用户: " <> reportUser report) : map renderResult (reportResults report)

renderResult :: GameSignResult -> String
renderResult (SignSucceeded game character awards) =
  "  [成功] " <> game <> " / " <> character <> renderAwards awards
renderResult (AlreadySigned game character reason) =
  "  [已签到] " <> game <> " / " <> character <> " - " <> reason
renderResult (SignFailed game Nothing reason) =
  "  [失败] " <> game <> " - " <> reason
renderResult (SignFailed game (Just character) reason) =
  "  [失败] " <> game <> " / " <> character <> " - " <> reason

renderAwards :: [Award] -> String
renderAwards [] = ""
renderAwards awards = " - " <> joinWith ", " [awardName award <> " x" <> show (awardCount award) | award <- awards]

mask :: String -> String
mask value
  | length value <= 8 = replicate (length value) '*'
  | otherwise = take 4 value <> "..." <> drop (length value - 4) value

lower :: String -> String
lower = map toLower

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

fnvHex :: String -> String
fnvHex = padHex . foldl fnv 2166136261
  where
    fnv acc c = (acc `xorInt` fromEnum c) * 16777619 `mod` 4294967296

xorInt :: Int -> Int -> Int
xorInt a b = sum [bit i | i <- [0 .. 31 :: Int], test a i /= test b i]
  where
    bit i = 2 ^ i
    test n i = (n `div` (2 ^ i)) `mod` 2 == 1

padHex :: Int -> String
padHex n =
  let value = toHex n
   in replicate (8 - length value) '0' <> value

toHex :: Int -> String
toHex n =
  let digits = "0123456789abcdef"
      go x
        | x < 16 = [digits !! x]
        | otherwise = go (x `div` 16) <> [digits !! (x `mod` 16)]
   in go n

joinWith :: String -> [String] -> String
joinWith _ [] = ""
joinWith _ [x] = x
joinWith sep (x : xs) = x <> sep <> joinWith sep xs
