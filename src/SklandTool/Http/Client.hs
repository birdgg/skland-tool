module SklandTool.Http.Client
  ( HttpClientError (..)
  , SklandClient (..)
  , clientErrorSummary
  , newManager
  , sklandClient
  )
where

import Control.Exception (try)
import Data.Aeson (FromJSON, eitherDecode, encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Client
  ( HttpException
  , Manager
  , Request (..)
  , RequestBody (RequestBodyLBS)
  , Response
  , httpLbs
  , parseRequest
  , responseBody
  , responseStatus
  )
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Header (RequestHeaders)
import Network.HTTP.Types.Status (statusCode)

import SklandTool.Http.Models
import SklandTool.Sign
import SklandTool.Types

data HttpClientError
  = FailureResponse !Int !BL.ByteString
  | DecodeFailure !Text
  | ConnectionFailure !Text
  deriving stock (Eq, Show)

data SklandClient = SklandClient
  { clientAuthorize :: Manager -> Text -> Text -> IO (Either HttpClientError OAuthResponse)
  , clientCredential :: Manager -> Text -> Text -> IO (Either HttpClientError CredentialResponse)
  , clientBindings :: Manager -> Text -> Credential -> Int64 -> IO (Either HttpClientError BindingListResponse)
  , clientSignArknights :: Manager -> Text -> Credential -> Int64 -> Binding -> IO (Either HttpClientError AttendanceResponse)
  , clientSignEndfield :: Manager -> Text -> Credential -> Int64 -> Binding -> EndfieldRole -> IO (Either HttpClientError AttendanceResponse)
  }

newManager :: IO Manager
newManager = newTlsManager

sklandClient :: SklandClient
sklandClient =
  SklandClient
    { clientAuthorize = \manager did token ->
        postJson manager authBase "/user/oauth2/v2/grant" did [] $
          encode (OAuthRequest "4ca99fa6b56cc2ba" token 0)
    , clientCredential = \manager did code ->
        postJson manager zonaiBase "/web/v1/user/auth/generate_cred_by_code" did [] $
          encode (object ["code" .= code, "kind" .= (1 :: Int)])
    , clientBindings = \manager did credential timestamp ->
        let signed = signedHeadersAt credential did "GET" "/api/v1/game/player/binding" "" timestamp
         in getJson manager zonaiBase "/api/v1/game/player/binding" did $
              signedHeaderValues credential signed
    , clientSignArknights = \manager did credential timestamp binding ->
        let body = arknightsBody binding
            signed = signedHeadersAt credential did "POST" "/api/v1/game/attendance" body timestamp
         in postJson manager zonaiBase "/api/v1/game/attendance" did (signedHeaderValues credential signed) body
    , clientSignEndfield = \manager did credential timestamp _binding role ->
        let body = ""
            roleHeader = "3_" <> role.roleId <> "_" <> role.roleServerId
            signed = signedHeadersAt credential did "POST" "/web/v1/game/endfield/attendance" body timestamp
            headers =
              signedHeaderValues credential signed
                <> [ ("sk-game-role", encodeUtf8 roleHeader)
                   , ("referer", "https://game.skland.com/")
                   , ("origin", "https://game.skland.com/")
                   ]
         in postJson manager zonaiBase "/web/v1/game/endfield/attendance" did headers body
    }

authBase :: String
authBase = "https://as.hypergryph.com"

zonaiBase :: String
zonaiBase = "https://zonai.skland.com"

baseHeaderValues :: Text -> RequestHeaders
baseHeaderValues did =
  [ ("User-Agent", "Mozilla/5.0 SKLand/1.52.1")
  , ("Accept-Encoding", "identity")
  , ("Connection", "close")
  , ("X-Requested-With", "com.hypergryph.skland")
  , ("dId", encodeUtf8 did)
  ]

signedHeaderValues :: Credential -> SignedHeaders -> RequestHeaders
signedHeaderValues credential signed =
  [ ("cred", encodeUtf8 credential.credentialCred)
  , ("platform", encodeUtf8 signed.signedPlatform)
  , ("timestamp", encodeUtf8 signed.signedTimestamp)
  , ("vName", encodeUtf8 signed.signedVersionName)
  , ("sign", encodeUtf8 signed.signedSign)
  ]

getJson
  :: FromJSON a
  => Manager
  -> String
  -> String
  -> Text
  -> RequestHeaders
  -> IO (Either HttpClientError a)
getJson manager base path did extraHeaders =
  sendJson manager base path did "GET" extraHeaders Nothing

postJson
  :: FromJSON a
  => Manager
  -> String
  -> String
  -> Text
  -> RequestHeaders
  -> BL.ByteString
  -> IO (Either HttpClientError a)
postJson manager base path did extraHeaders body =
  sendJson manager base path did "POST" extraHeaders (Just body)

sendJson
  :: FromJSON a
  => Manager
  -> String
  -> String
  -> Text
  -> BS.ByteString
  -> RequestHeaders
  -> Maybe BL.ByteString
  -> IO (Either HttpClientError a)
sendJson manager base path did method extraHeaders maybeBody = do
  initial <- parseRequest $ base <> path
  let contentHeaders =
        case maybeBody of
          Nothing -> []
          Just _ -> [("Content-Type", "application/json")]
      request =
        initial
          { method = method
          , requestHeaders =
              baseHeaderValues did
                <> [("Accept", "application/json")]
                <> contentHeaders
                <> extraHeaders
          , requestBody = maybe mempty RequestBodyLBS maybeBody
          }
  result <- try @HttpException $ httpLbs request manager
  case result of
    Left err -> pure $ Left $ ConnectionFailure $ T.pack $ show err
    Right response -> decodeJsonResponse response

decodeJsonResponse :: FromJSON a => Response BL.ByteString -> IO (Either HttpClientError a)
decodeJsonResponse response =
  if code >= 200 && code < 300
    then
      pure $ case eitherDecode response.responseBody of
        Left err -> Left $ DecodeFailure $ T.pack err
        Right value -> Right value
    else pure $ Left $ FailureResponse code response.responseBody
  where
    code = statusCode response.responseStatus

clientErrorSummary :: HttpClientError -> Text
clientErrorSummary = \case
  FailureResponse code _ ->
    "HTTP 请求失败: status=" <> T.pack (show code)
  DecodeFailure message ->
    "HTTP 响应 JSON 解析失败: " <> message
  ConnectionFailure err ->
    "HTTP 连接失败: " <> err
