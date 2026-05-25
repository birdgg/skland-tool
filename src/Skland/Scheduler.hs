module Skland.Scheduler
  ( runDaemon
  , nextRunAt
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, catch)
import Data.Time

import Skland.App (printReports, runAllUsers)
import Skland.Types

beijingTimeZone :: TimeZone
beijingTimeZone = hoursToTimeZone 8

runDaemon :: AppConfig -> IO ()
runDaemon config = loop
  where
    loop = do
      now <- getCurrentTime
      let target = nextRunAt beijingTimeZone (TimeOfDay (hour (schedule config)) (minute (schedule config)) 0) now
          delay = diffUTCTime target now
      putStrLn ("下一次签到时间: " <> formatBeijing target)
      delaySeconds delay
      runOnceSafe
      loop

    runOnceSafe =
      (runAllUsers config >>= printReports)
        `catch` \(err :: SomeException) -> putStrLn ("本次签到异常: " <> show err)

nextRunAt :: TimeZone -> TimeOfDay -> UTCTime -> UTCTime
nextRunAt zone tod now =
  let localNow = utcToLocalTime zone now
      today = localDay localNow
      candidateLocal = LocalTime today tod
      candidateUtc = localTimeToUTC zone candidateLocal
   in if candidateUtc > now
        then candidateUtc
        else localTimeToUTC zone (LocalTime (addDays 1 today) tod)

delaySeconds :: NominalDiffTime -> IO ()
delaySeconds diff = go (max 0 (floor diff :: Int))
  where
    chunk = 1800
    go seconds
      | seconds <= 0 = pure ()
      | otherwise = do
          threadDelay (min chunk seconds * 1000000)
          go (seconds - chunk)

formatBeijing :: UTCTime -> String
formatBeijing utcTime =
  formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S Asia/Shanghai" (utcToLocalTime beijingTimeZone utcTime)
