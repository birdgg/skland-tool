module SklandTool.App
  ( buildRuntime
  , runDaemon
  , runDoctor
  , runOnce
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Effectful
import Effectful.Error.Static
import Effectful.Reader.Static
import Network.HTTP.Client (Manager)
import System.Directory
  ( XdgDirectory (XdgConfig)
  , createDirectoryIfMissing
  , doesFileExist
  , getXdgDirectory
  )
import System.FilePath ((</>))
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID

import SklandTool.Config (validateConfig)
import SklandTool.Http.Client
import SklandTool.Http.Models
import SklandTool.Report
import SklandTool.Scheduler
import SklandTool.Types

type AppEff es = (Reader Runtime :> es, Error AppError :> es, IOE :> es)

buildRuntime :: AppConfig -> IO Runtime
buildRuntime config = do
  manager <- newManager
  cacheDir <- getXdgDirectory XdgConfig "skland-tool"
  createDirectoryIfMissing True cacheDir
  pure Runtime{runtimeConfig = config, runtimeManager = manager, runtimeCacheDir = cacheDir}

runDoctor :: AppConfig -> IO (Either AppError ())
runDoctor config = do
  case validateConfig config of
    Left err -> pure $ Left err
    Right _ -> do
      runtime <- buildRuntime config
      pure $ Right $ runtime.runtimeManager `seq` ()

runOnce :: Runtime -> IO (Either AppError [SignResult])
runOnce runtime = runEff $ runErrorNoCallStack @AppError $ runReader runtime runSignIn

runDaemon :: Runtime -> IO ()
runDaemon runtime = foreverLoop
  where
    foreverLoop = do
      now <- getCurrentTime
      let target = nextRunAt runtime.runtimeConfig.configSchedule now
          seconds = max 0 $ floor $ diffUTCTime target now
      putStrLn $ "下一次签到时间: " <> formatBeijing target
      sleepChunked seconds
      result <- runOnce runtime
      case result of
        Left err -> TIO.putStrLn $ renderAppError err
        Right report -> mapM_ TIO.putStrLn $ renderReport report
      foreverLoop

runSignIn :: AppEff es => Eff es [SignResult]
runSignIn = do
  runtime <- ask @Runtime
  did <- getDeviceId
  liftIO $ TIO.putStrLn $ "使用设备 ID: " <> mask did
  report <- runUser did runtime.runtimeConfig.configToken runtime.runtimeConfig.configGame
  saveLastReport report
  pure report

runUser :: AppEff es => Text -> Text -> GameType -> Eff es [SignResult]
runUser did token gameType = do
  code <- requestAuth did token
  credential <- requestCredential did code
  bindings <- requestBindings did credential
  runBindings did credential gameType bindings

runBindings :: AppEff es => Text -> Credential -> GameType -> [Binding] -> Eff es [SignResult]
runBindings did credential gameType bindings = do
  arknightsResults <-
    if wantsArknights gameType
      then runArknights did credential bindings
      else pure []
  endfieldResults <-
    if wantsEndfield gameType
      then runEndfield did credential bindings
      else pure []
  pure $ arknightsResults <> endfieldResults

runArknights :: AppEff es => Text -> Credential -> [Binding] -> Eff es [SignResult]
runArknights did credential bindings =
  case filter ((== "arknights") . T.toLower . bindingAppCode) bindings of
    [] -> pure [SignFailed "明日方舟" Nothing "未找到明日方舟绑定角色"]
    selected -> traverse (requestArknights did credential) selected

runEndfield :: AppEff es => Text -> Credential -> [Binding] -> Eff es [SignResult]
runEndfield did credential bindings =
  case filter ((== "endfield") . T.toLower . bindingAppCode) bindings of
    [] -> pure [SignFailed "终末地" Nothing "未找到终末地绑定角色"]
    selected -> concat <$> traverse signBinding selected
  where
    signBinding binding =
      case binding.bindingRoles of
        [] -> pure [SignFailed "终末地" (Just binding.bindingRoleName) "绑定数据中没有终末地角色 roles"]
        roles -> traverse (requestEndfield did credential binding) roles

requestAuth :: AppEff es => Text -> Text -> Eff es Text
requestAuth did token = do
  response <- runHttpClient $ \manager -> clientAuthorize sklandClient manager did token
  either throwError pure $ parseAuthorization response

requestCredential :: AppEff es => Text -> Text -> Eff es Credential
requestCredential did code = do
  response <- runHttpClient $ \manager -> clientCredential sklandClient manager did code
  either throwError pure $ parseCredential response

requestBindings :: AppEff es => Text -> Credential -> Eff es [Binding]
requestBindings did credential = do
  timestamp <- currentSignTimestamp
  response <- runHttpClient $ \manager -> clientBindings sklandClient manager did credential timestamp
  either throwError pure $ parseBindings response

requestArknights :: AppEff es => Text -> Credential -> Binding -> Eff es SignResult
requestArknights did credential binding = do
  timestamp <- currentSignTimestamp
  response <- runHttpClientEither $ \manager -> clientSignArknights sklandClient manager did credential timestamp binding
  pure $ case response of
    Left err -> attendanceClientError "明日方舟" binding.bindingRoleName err
    Right body -> parseAttendanceBody "明日方舟" binding.bindingRoleName body

requestEndfield :: AppEff es => Text -> Credential -> Binding -> EndfieldRole -> Eff es SignResult
requestEndfield did credential binding role = do
  timestamp <- currentSignTimestamp
  let character = if T.null role.roleNickname then binding.bindingRoleName else role.roleNickname
  response <- runHttpClientEither $ \manager -> clientSignEndfield sklandClient manager did credential timestamp binding role
  pure $ case response of
    Left err -> attendanceClientError "终末地" character err
    Right body -> parseAttendanceBody "终末地" character body

attendanceClientError :: Text -> Text -> HttpClientError -> SignResult
attendanceClientError game character = \case
  err@(FailureResponse _ body) ->
    case parseAttendanceRaw game character body of
      Right result -> result
      Left _ -> fallback err
  err -> fallback err
  where
    fallback err = SignFailed game (Just character) (clientErrorSummary err)

runHttpClient :: AppEff es => (Manager -> IO (Either HttpClientError a)) -> Eff es a
runHttpClient action = do
  result <- runHttpClientEither action
  either (throwError . HttpError . clientErrorSummary) pure result

runHttpClientEither :: AppEff es => (Manager -> IO (Either HttpClientError a)) -> Eff es (Either HttpClientError a)
runHttpClientEither action = do
  manager <- asks @Runtime runtimeManager
  liftIO $ action manager

getDeviceId :: AppEff es => Eff es Text
getDeviceId = do
  config <- asks @Runtime runtimeConfig
  case config.configDeviceId of
    Just did | not (T.null did) -> pure did
    _ -> getCachedDeviceId

getCachedDeviceId :: AppEff es => Eff es Text
getCachedDeviceId = do
  cacheDir <- asks @Runtime runtimeCacheDir
  let path = cacheDir </> "device.env"
  exists <- liftIO $ doesFileExist path
  if exists
    then do
      raw <- readTextFile path
      maybe createDeviceId pure $ parseDeviceId raw
    else createDeviceId

createDeviceId :: AppEff es => Eff es Text
createDeviceId = do
  cacheDir <- asks @Runtime runtimeCacheDir
  uuid <- liftIO UUID.nextRandom
  let did = "B" <> T.filter (/= '-') (UUID.toText uuid)
      path = cacheDir </> "device.env"
  writeTextFile path $ "SKLAND_DID=" <> did <> "\n"
  pure did

parseDeviceId :: Text -> Maybe Text
parseDeviceId raw =
  case [T.strip value | line <- T.lines raw, Just value <- [T.stripPrefix "SKLAND_DID=" line], not (T.null $ T.strip value)] of
    value : _ -> Just value
    [] -> Nothing

saveLastReport :: AppEff es => [SignResult] -> Eff es ()
saveLastReport report = do
  cacheDir <- asks @Runtime runtimeCacheDir
  now <- liftIO getCurrentTime
  let header = "time=" <> T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
      body = T.unlines $ header : renderReport report
  writeTextFile (cacheDir </> "last-report.txt") body

readTextFile :: AppEff es => FilePath -> Eff es Text
readTextFile path = do
  result <- liftIO $ try @IOException $ TIO.readFile path
  either (throwError . StorageError . T.pack . show) pure result

writeTextFile :: AppEff es => FilePath -> Text -> Eff es ()
writeTextFile path body = do
  result <- liftIO $ try @IOException $ TIO.writeFile path body
  either (throwError . StorageError . T.pack . show) pure result

currentSignTimestamp :: IOE :> es => Eff es Int64
currentSignTimestamp = do
  now <- liftIO getCurrentTime
  pure $ floor (utcTimeToPOSIXSeconds now) - 2

sleepChunked :: Int -> IO ()
sleepChunked seconds = go seconds
  where
    go remaining
      | remaining <= 0 = pure ()
      | otherwise = do
          let current = min remaining 1800
          threadDelay $ current * 1000000
          go $ remaining - current

mask :: Text -> Text
mask value
  | T.length value <= 8 = T.replicate (T.length value) "*"
  | otherwise = T.take 4 value <> "..." <> T.takeEnd 4 value
