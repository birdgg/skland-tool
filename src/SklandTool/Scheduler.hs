module SklandTool.Scheduler
  ( formatBeijing
  , nextRunAt
  )
where

import Data.Time

import SklandTool.Types

nextRunAt :: ScheduleConfig -> UTCTime -> UTCTime
nextRunAt schedule now =
  if candidate > now
    then candidate
    else localTimeToUTC beijingZone $ LocalTime (addDays 1 localDay) targetTime
  where
    LocalTime localDay _ = utcToLocalTime beijingZone now
    targetTime =
      TimeOfDay
        (fromIntegral schedule.scheduleHour)
        (fromIntegral schedule.scheduleMinute)
        0
    candidate = localTimeToUTC beijingZone $ LocalTime localDay targetTime

formatBeijing :: UTCTime -> String
formatBeijing =
  formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S Asia/Shanghai"
    . utcToLocalTime beijingZone

beijingZone :: TimeZone
beijingZone = hoursToTimeZone 8
