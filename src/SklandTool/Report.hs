module SklandTool.Report
  ( renderReport
  , renderResult
  )
where

import Data.Text (Text)
import qualified Data.Text as T

import SklandTool.Types

renderReport :: [SignResult] -> [Text]
renderReport = map renderResult

renderResult :: SignResult -> Text
renderResult = \case
  SignSucceeded game character awards ->
    "  [成功] " <> game <> " / " <> character <> renderAwards awards
  AlreadySigned game character reason ->
    "  [已签到] " <> game <> " / " <> character <> " - " <> reason
  SignFailed game Nothing reason ->
    "  [失败] " <> game <> " - " <> reason
  SignFailed game (Just character) reason ->
    "  [失败] " <> game <> " / " <> character <> " - " <> reason

renderAwards :: [Award] -> Text
renderAwards [] = ""
renderAwards awards =
  " - "
    <> T.intercalate
      ", "
      [ award.awardName <> " x" <> T.pack (show award.awardCount)
      | award <- awards
      ]
