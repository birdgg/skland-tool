module Skland.Sign
  ( signedHeaders
  , currentTimestampForSign
  , arknightsBody
  )
where

import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Exit (ExitCode (..))
import System.Process (proc, readCreateProcessWithExitCode)

import Skland.Json (compactObject, compactString)
import Skland.Types

currentTimestampForSign :: IO Int
currentTimestampForSign = do
  now <- getPOSIXTime
  pure (floor now - 2)

signedHeaders :: Credential -> String -> String -> String -> String -> IO (Either String [(String, String)])
signedHeaders credential did method path body = do
  ts <- currentTimestampForSign
  let timestamp = show ts
      headerCa =
        compactObject
          [ ("platform", "3")
          , ("timestamp", timestamp)
          , ("dId", did)
          , ("vName", "1.0.0")
          ]
      raw =
        case method of
          "GET" -> path <> timestamp <> headerCa
          _ -> path <> body <> timestamp <> headerCa
  hmacResult <- openssl ["dgst", "-sha256", "-hmac", token credential, "-hex"] raw
  case hmacResult of
    Left err -> pure (Left err)
    Right hmacHex -> do
      md5Result <- openssl ["dgst", "-md5", "-hex"] hmacHex
      pure
        ( fmap
            ( \signValue ->
                [ ("platform", "3")
                , ("timestamp", timestamp)
                , ("dId", did)
                , ("vName", "1.0.0")
                , ("sign", signValue)
                ]
            )
            md5Result
        )

arknightsBody :: Binding -> String
arknightsBody binding =
  "{\"gameId\":" <> show (gameId binding) <> ",\"uid\":" <> compactString (uid binding) <> "}"

openssl :: [String] -> String -> IO (Either String String)
openssl args input = do
  (code, out, err) <- readCreateProcessWithExitCode (proc "openssl" args) input
  case code of
    ExitSuccess ->
      case words out of
        [] -> pure (Left ("openssl 没有输出: openssl " <> unwords args))
        xs -> pure (Right (last xs))
    ExitFailure _ -> pure (Left ("openssl 失败: " <> err))
