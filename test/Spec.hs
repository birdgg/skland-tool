module Main (main) where

import Data.Aeson (FromJSON, eitherDecode)
import qualified Data.ByteString.Lazy as BL
import Data.Either (isLeft)
import Data.Time
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Test.Tasty
import Test.Tasty.HUnit

import SklandTool.Config
import SklandTool.Api.Models
import SklandTool.Api.Signature
import SklandTool.Scheduler
import SklandTool.Types

main :: IO ()
main =
  defaultMain $
    testGroup
      "skland-tool"
      [ configTests
      , signTests
      , parserTests
      , schedulerTests
      ]

configTests :: TestTree
configTests =
  testGroup
    "config"
    [ testCase "accepts valid config defaults" $
        validateConfig validConfig @?= Right validConfig
    , testCase "rejects invalid schedule" $
        assertBool "invalid hour should fail" $
          isLeft $
            validateConfig validConfig{configSchedule = ScheduleConfig 24 0 "Asia/Shanghai"}
    , testCase "rejects empty token" $
        assertBool "empty token should fail" $
          isLeft $
            validateConfig validConfig{configToken = ""}
    ]
  where
    validConfig =
      AppConfig
        { configToken = "token"
        , configDeviceId = Nothing
        , configSchedule = ScheduleConfig 6 0 "Asia/Shanghai"
        }

signTests :: TestTree
signTests =
  testGroup
    "sign"
    [ testCase "arknights body is compact" $ do
        arknightsBody sampleBinding @?= "{\"gameId\":1,\"uid\":\"123\"}"
    , testCase "compact header object keeps required order" $ do
        compactObject [("platform", "3"), ("timestamp", "1"), ("dId", "DID"), ("vName", "1.0.0")]
          @?= "{\"platform\":\"3\",\"timestamp\":\"1\",\"dId\":\"DID\",\"vName\":\"1.0.0\"}"
    , testCase "sign length is stable" $ do
        let signed = signedHeadersAt sampleCredential "DID" "GET" "/api/v1/game/player/binding" "" 1700000000
        signed.signedPlatform @?= "3"
        signed.signedVersionName @?= "1.0.0"
        T.length signed.signedSign @?= 32
    ]

parserTests :: TestTree
parserTests =
  testGroup
    "parser"
    [ testCase "parses oauth" $ do
        response <- decodeJson "{\"status\":0,\"data\":{\"code\":\"abc\"}}"
        parseAuthorization response @?= Right "abc"
    , testCase "parses credential" $ do
        response <- decodeJson "{\"code\":0,\"data\":{\"cred\":\"cred\",\"token\":\"token\"}}"
        parseCredential response @?= Right sampleCredential
    , testCase "parses stringish binding fields" $ do
        response <- decodeJson "{\"code\":0,\"data\":{\"list\":[{\"appCode\":\"arknights\",\"bindingList\":[{\"uid\":123,\"gameId\":\"1\",\"nickName\":\"博士\"}]}]}}"
        parseBindings response @?= Right [sampleBinding{bindingRoleName = "博士"}]
    , testCase "parses arknights award" $ do
        response <- decodeJson "{\"code\":0,\"data\":{\"awards\":[{\"resource\":{\"name\":\"合成玉\"},\"count\":200}]}}"
        parseAttendanceBody "明日方舟" "博士" response
          @?= SignSucceeded "明日方舟" "博士" [Award "合成玉" 200]
    , testCase "parses endfield award map" $ do
        response <- decodeJson "{\"code\":0,\"data\":{\"awardIds\":[{\"id\":\"a\"}],\"resourceInfoMap\":{\"a\":{\"name\":\"材料\",\"count\":2}}}}"
        parseAttendanceBody "终末地" "管理员" response
          @?= SignSucceeded "终末地" "管理员" [Award "材料" 2]
    , testCase "detects already signed" $ do
        response <- decodeJson "{\"code\":100,\"message\":\"今日已签到\"}"
        parseAttendanceBody "明日方舟" "博士" response
          @?= AlreadySigned "明日方舟" "博士" "今日已签到"
    , testCase "parses non-2xx attendance body" $ do
        parseAttendanceRaw "明日方舟" "博士" (BL.fromStrict $ encodeUtf8 "{\"code\":10001,\"message\":\"请勿重复签到！\"}")
          @?= Right (AlreadySigned "明日方舟" "博士" "请勿重复签到！")
    ]

schedulerTests :: TestTree
schedulerTests =
  testGroup
    "scheduler"
    [ testCase "uses today when future" $ do
        let now = UTCTime (fromGregorian 2026 5 24) (secondsToDiffTime $ 21 * 3600)
            target = UTCTime (fromGregorian 2026 5 24) (secondsToDiffTime $ 22 * 3600)
        nextRunAt (ScheduleConfig 6 0 "Asia/Shanghai") now @?= target
    , testCase "uses tomorrow when elapsed" $ do
        let now = UTCTime (fromGregorian 2026 5 24) (secondsToDiffTime $ 23 * 3600)
            target = UTCTime (fromGregorian 2026 5 25) (secondsToDiffTime $ 22 * 3600)
        nextRunAt (ScheduleConfig 6 0 "Asia/Shanghai") now @?= target
    ]

decodeJson :: FromJSON a => Text -> IO a
decodeJson raw =
  case eitherDecode (BL.fromStrict $ encodeUtf8 raw) of
    Left err -> assertFailure err
    Right value -> pure value

sampleCredential :: Credential
sampleCredential = Credential "cred" "token"

sampleBinding :: Binding
sampleBinding =
  Binding
    { bindingAppCode = "arknights"
    , bindingGameName = ""
    , bindingRoleName = ""
    , bindingChannelName = ""
    , bindingUid = "123"
    , bindingGameId = 1
    , bindingRoles = []
    }
