module Main (main) where

import Data.Text.IO qualified as TIO
import Options.Applicative
import System.IO (BufferMode (LineBuffering), hSetBuffering, stderr, stdout)

import SklandTool.App
import SklandTool.Config
import SklandTool.Report
import SklandTool.Types

data Command
  = Run FilePath
  | Daemon FilePath
  | Doctor FilePath

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  selected <- execParser parserInfo
  case selected of
    Run path -> withConfig path $ \config -> do
      runtime <- buildRuntime config
      runOnce runtime >>= printResult
    Daemon path -> withConfig path $ \config -> do
      runtime <- buildRuntime config
      runDaemon runtime
    Doctor path -> withConfig path $ \config ->
      runDoctor config >>= \case
        Left err -> TIO.putStrLn (renderAppError err)
        Right _ -> do
          putStrLn $ "配置 OK: " <> path
          putStrLn $
            "调度: 每天北京时间 "
              <> twoDigits config.configSchedule.scheduleHour
              <> ":"
              <> twoDigits config.configSchedule.scheduleMinute

parserInfo :: ParserInfo Command
parserInfo =
  info
    (commandParser <**> helper)
    ( fullDesc
        <> progDesc "森空岛每日签到命令行工具"
        <> header "skland-tool"
    )

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "run" (info (Run <$> configOption <**> helper) (progDesc "立即执行一次签到"))
        <> command "daemon" (info (Daemon <$> configOption <**> helper) (progDesc "常驻运行并按每天北京时间调度"))
        <> command "doctor" (info (Doctor <$> configOption <**> helper) (progDesc "校验配置文件"))
    )

configOption :: Parser FilePath
configOption =
  strOption
    ( long "config"
        <> short 'c'
        <> metavar "FILE"
        <> value defaultConfigPath
        <> showDefault
        <> help "TOML 配置文件路径"
    )

withConfig :: FilePath -> (AppConfig -> IO ()) -> IO ()
withConfig path onConfig =
  loadConfig path >>= \case
    Left err -> TIO.putStrLn $ renderAppError err
    Right config -> onConfig config

printResult :: Either AppError [SignResult] -> IO ()
printResult = \case
  Left err -> TIO.putStrLn $ renderAppError err
  Right report -> mapM_ TIO.putStrLn $ renderReport report

twoDigits :: Int -> String
twoDigits number
  | number < 10 = '0' : show number
  | otherwise = show number
