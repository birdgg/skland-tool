module Main (main) where

import System.Environment (getArgs)
import System.Exit (exitFailure)

import Skland.App (printReports, runAllUsers)
import Skland.Config (loadConfig)
import Skland.Scheduler (runDaemon)
import Skland.Types

main :: IO ()
main = do
  args <- getArgs
  let command = parseArgs args
  case command of
    Left err -> putStrLn err >> usage >> exitFailure
    Right (cmd, envPath) -> do
      loaded <- loadConfig envPath
      case loaded of
        Left err -> putStrLn ("配置错误: " <> err) >> exitFailure
        Right config -> runCommand cmd config

data Command = RunOnce | Daemon | CheckConfig
  deriving (Eq, Show)

runCommand :: Command -> AppConfig -> IO ()
runCommand CheckConfig config = do
  putStrLn ("配置 OK: " <> envFile config)
  putStrLn ("用户数: " <> show (length (users config)))
  putStrLn ("调度: 每天北京时间 " <> two (hour (schedule config)) <> ":" <> two (minute (schedule config)))
runCommand RunOnce config = runAllUsers config >>= printReports
runCommand Daemon config = runDaemon config

parseArgs :: [String] -> Either String (Command, FilePath)
parseArgs args =
  case args of
    [] -> Right (RunOnce, ".env")
    cmd : rest -> do
      parsedCommand <- parseCommand cmd
      envPath <- parseEnvPath rest
      Right (parsedCommand, envPath)

parseCommand :: String -> Either String Command
parseCommand "run-once" = Right RunOnce
parseCommand "daemon" = Right Daemon
parseCommand "check-config" = Right CheckConfig
parseCommand other = Left ("未知命令: " <> other)

parseEnvPath :: [String] -> Either String FilePath
parseEnvPath [] = Right ".env"
parseEnvPath ["--env", path] = Right path
parseEnvPath ["--config", path] = Right path
parseEnvPath other = Left ("无法解析参数: " <> unwords other)

usage :: IO ()
usage = do
  putStrLn "用法:"
  putStrLn "  skland-tool run-once [--env .env]"
  putStrLn "  skland-tool daemon [--env .env]"
  putStrLn "  skland-tool check-config [--env .env]"
  putStrLn ""
  putStrLn ".env 示例:"
  putStrLn "  SKLAND_TOKEN=森空岛 data.content"
  putStrLn "  SKLAND_NICKNAME=我的大号"
  putStrLn "  SKLAND_GAME_TYPE=0"
  putStrLn "  SKLAND_SCHEDULE_HOUR=6"
  putStrLn "  SKLAND_SCHEDULE_MINUTE=0"

two :: Int -> String
two n
  | n < 10 = "0" <> show n
  | otherwise = show n
