{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module SklandTool.Api.Client
  ( HttpClientError (..)
  , SklandClient (..)
  , clientErrorSummary
  , newManager
  , sklandClient
  )
where

import Data.Aeson (FromJSON, eitherDecode, encode, object, (.=))
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Client (Manager)
import Network.HTTP.Client.TLS (newTlsManager)
import qualified Network.HTTP.Media as Media
import Network.HTTP.Types.Status (statusCode)
import Servant.API
  ( (:<|>) (..)
  , (:>)
  , Accept (..)
  , Get
  , Header'
  , MimeRender (..)
  , MimeUnrender (..)
  , Post
  , ReqBody
  , Required
  , Strict
  )
import qualified Servant.Client as Servant

import SklandTool.Api.Models
import SklandTool.Api.Signature
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

data SklandJson

newtype RawJsonBody = RawJsonBody BL.ByteString

instance Accept SklandJson where
  contentType _ = "application" Media.// "json"

instance MimeRender SklandJson RawJsonBody where
  mimeRender _ (RawJsonBody body) = body

instance FromJSON a => MimeUnrender SklandJson a where
  mimeUnrender _ = eitherDecode

type CommonHeaders api =
  Header' '[Required, Strict] "User-Agent" Text
    :> Header' '[Required, Strict] "Accept-Encoding" Text
    :> Header' '[Required, Strict] "Connection" Text
    :> Header' '[Required, Strict] "X-Requested-With" Text
    :> Header' '[Required, Strict] "dId" Text
    :> api

type SignedHeaderParams api =
  Header' '[Required, Strict] "cred" Text
    :> Header' '[Required, Strict] "platform" Text
    :> Header' '[Required, Strict] "timestamp" Text
    :> Header' '[Required, Strict] "vName" Text
    :> Header' '[Required, Strict] "sign" Text
    :> api

type EndfieldHeaderParams api =
  Header' '[Required, Strict] "sk-game-role" Text
    :> Header' '[Required, Strict] "referer" Text
    :> Header' '[Required, Strict] "origin" Text
    :> api

type AuthApi =
  CommonHeaders
    ( "user"
        :> "oauth2"
        :> "v2"
        :> "grant"
        :> ReqBody '[SklandJson] RawJsonBody
        :> Post '[SklandJson] OAuthResponse
    )

type ZonaiApi =
  CommonHeaders
    ( "web"
        :> "v1"
        :> "user"
        :> "auth"
        :> "generate_cred_by_code"
        :> ReqBody '[SklandJson] RawJsonBody
        :> Post '[SklandJson] CredentialResponse
    )
    :<|> CommonHeaders
      ( SignedHeaderParams
          ( "api"
              :> "v1"
              :> "game"
              :> "player"
              :> "binding"
              :> Get '[SklandJson] BindingListResponse
          )
      )
    :<|> CommonHeaders
      ( SignedHeaderParams
          ( "api"
              :> "v1"
              :> "game"
              :> "attendance"
              :> ReqBody '[SklandJson] RawJsonBody
              :> Post '[SklandJson] AttendanceResponse
          )
      )
    :<|> CommonHeaders
      ( SignedHeaderParams
          ( EndfieldHeaderParams
              ( "web"
                  :> "v1"
                  :> "game"
                  :> "endfield"
                  :> "attendance"
                  :> ReqBody '[SklandJson] RawJsonBody
                  :> Post '[SklandJson] AttendanceResponse
              )
          )
      )

authClient
  :: Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> RawJsonBody
  -> Servant.ClientM OAuthResponse
authClient = Servant.client (Proxy @AuthApi)

credentialClient
  :: Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> RawJsonBody
  -> Servant.ClientM CredentialResponse
bindingsClient
  :: Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Servant.ClientM BindingListResponse
arknightsClient
  :: Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> RawJsonBody
  -> Servant.ClientM AttendanceResponse
endfieldClient
  :: Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> RawJsonBody
  -> Servant.ClientM AttendanceResponse
credentialClient :<|> bindingsClient :<|> arknightsClient :<|> endfieldClient =
  Servant.client (Proxy @ZonaiApi)

sklandClient :: SklandClient
sklandClient =
  SklandClient
    { clientAuthorize = \manager did token ->
        runSklandClient manager authBase $
          withCommonHeaders authClient did $
            RawJsonBody $ encode (OAuthRequest "4ca99fa6b56cc2ba" token 0)
    , clientCredential = \manager did code ->
        runSklandClient manager zonaiBase $
          withCommonHeaders credentialClient did $
            RawJsonBody $ encode (object ["code" .= code, "kind" .= (1 :: Int)])
    , clientBindings = \manager did credential timestamp ->
        let signed = signedHeadersAt credential did "GET" "/api/v1/game/player/binding" "" timestamp
         in runSklandClient manager zonaiBase $
              withSignedHeaders (withCommonHeaders bindingsClient did) $
                signedHeaderValues credential signed
    , clientSignArknights = \manager did credential timestamp binding ->
        let body = arknightsBody binding
            signed = signedHeadersAt credential did "POST" "/api/v1/game/attendance" body timestamp
         in runSklandClient manager zonaiBase $
              withSignedHeaders (withCommonHeaders arknightsClient did) (signedHeaderValues credential signed) $
                RawJsonBody body
    , clientSignEndfield = \manager did credential timestamp _binding role ->
        let body = ""
            roleHeader = "3_" <> role.roleId <> "_" <> role.roleServerId
            signed = signedHeadersAt credential did "POST" "/web/v1/game/endfield/attendance" body timestamp
         in runSklandClient manager zonaiBase $
              withEndfieldHeaders
                (withSignedHeaders (withCommonHeaders endfieldClient did) (signedHeaderValues credential signed))
                roleHeader
                (RawJsonBody body)
    }

authBase :: Servant.BaseUrl
authBase = Servant.BaseUrl Servant.Https "as.hypergryph.com" 443 ""

zonaiBase :: Servant.BaseUrl
zonaiBase = Servant.BaseUrl Servant.Https "zonai.skland.com" 443 ""

userAgentHeader :: Text
userAgentHeader = "Mozilla/5.0 SKLand/1.52.1"

acceptEncodingHeader :: Text
acceptEncodingHeader = "identity"

connectionHeader :: Text
connectionHeader = "close"

xRequestedWithHeader :: Text
xRequestedWithHeader = "com.hypergryph.skland"

refererHeader :: Text
refererHeader = "https://game.skland.com/"

originHeader :: Text
originHeader = "https://game.skland.com/"

data SignedHeaderValues = SignedHeaderValues
  { signedHeaderCred :: !Text
  , signedHeaderPlatform :: !Text
  , signedHeaderTimestamp :: !Text
  , signedHeaderVersionName :: !Text
  , signedHeaderSign :: !Text
  }

signedHeaderValues :: Credential -> SignedHeaders -> SignedHeaderValues
signedHeaderValues credential signed =
  SignedHeaderValues
    { signedHeaderCred = credential.credentialCred
    , signedHeaderPlatform = signed.signedPlatform
    , signedHeaderTimestamp = signed.signedTimestamp
    , signedHeaderVersionName = signed.signedVersionName
    , signedHeaderSign = signed.signedSign
    }

withCommonHeaders
  :: (Text -> Text -> Text -> Text -> Text -> a)
  -> Text
  -> a
withCommonHeaders action did =
  action userAgentHeader acceptEncodingHeader connectionHeader xRequestedWithHeader did

withSignedHeaders
  :: (Text -> Text -> Text -> Text -> Text -> a)
  -> SignedHeaderValues
  -> a
withSignedHeaders action signed =
  action
    signed.signedHeaderCred
    signed.signedHeaderPlatform
    signed.signedHeaderTimestamp
    signed.signedHeaderVersionName
    signed.signedHeaderSign

withEndfieldHeaders
  :: (Text -> Text -> Text -> a)
  -> Text
  -> a
withEndfieldHeaders action roleHeader =
  action roleHeader refererHeader originHeader

runSklandClient :: Manager -> Servant.BaseUrl -> Servant.ClientM a -> IO (Either HttpClientError a)
runSklandClient manager baseUrl action = do
  result <- Servant.runClientM action $ Servant.mkClientEnv manager baseUrl
  pure $ either (Left . mapClientError) Right result

mapClientError :: Servant.ClientError -> HttpClientError
mapClientError = \case
  Servant.FailureResponse _ response ->
    FailureResponse
      (statusCode response.responseStatusCode)
      response.responseBody
  Servant.DecodeFailure message _ ->
    DecodeFailure message
  Servant.UnsupportedContentType mediaType _ ->
    DecodeFailure $ "HTTP 响应 Content-Type 不支持: " <> T.pack (show mediaType)
  Servant.InvalidContentTypeHeader _ ->
    DecodeFailure "HTTP 响应 Content-Type header 无效"
  Servant.ConnectionError err ->
    ConnectionFailure $ T.pack $ show err

clientErrorSummary :: HttpClientError -> Text
clientErrorSummary = \case
  FailureResponse code _ ->
    "HTTP 请求失败: status=" <> T.pack (show code)
  DecodeFailure message ->
    "HTTP 响应 JSON 解析失败: " <> message
  ConnectionFailure err ->
    "HTTP 连接失败: " <> err
