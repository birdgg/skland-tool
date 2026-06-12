module SklandTool.Api.Signature
  ( SignedHeaders (..)
  , arknightsBody
  , compactObject
  , signedHeadersAt
  )
where

import qualified Crypto.Hash.MD5 as MD5
import qualified Crypto.Hash.SHA256 as SHA256
import Data.Aeson (encode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)

import SklandTool.Types

data SignedHeaders = SignedHeaders
  { signedPlatform :: !Text
  , signedTimestamp :: !Text
  , signedVersionName :: !Text
  , signedSign :: !Text
  }
  deriving stock (Eq, Show)

signedHeadersAt :: Credential -> Text -> Text -> Text -> BL.ByteString -> Int64 -> SignedHeaders
signedHeadersAt credential did method path body timestamp =
  SignedHeaders
    { signedPlatform = "3"
    , signedTimestamp = timestampText
    , signedVersionName = "1.0.0"
    , signedSign = decodeUtf8 md5Hex
    }
  where
    timestampText = T.pack (show timestamp)
    headerCa =
      compactObject
        [ ("platform", "3")
        , ("timestamp", timestampText)
        , ("dId", did)
        , ("vName", "1.0.0")
        ]
    raw =
      if method == "GET"
        then encodeUtf8 path <> encodeUtf8 timestampText <> BL.toStrict headerCa
        else encodeUtf8 path <> BL.toStrict body <> encodeUtf8 timestampText <> BL.toStrict headerCa
    hmacHex = Base16.encode $ SHA256.hmac (encodeUtf8 credential.credentialToken) raw
    md5Hex = Base16.encode $ MD5.hash hmacHex

arknightsBody :: Binding -> BL.ByteString
arknightsBody binding =
  BL.fromStrict $
    BS.concat
      [ "{\"gameId\":"
      , encodeUtf8 $ T.pack $ show binding.bindingGameId
      , ",\"uid\":"
      , BL.toStrict $ encode binding.bindingUid
      , "}"
      ]

compactObject :: [(Text, Text)] -> BL.ByteString
compactObject fields =
  BL.fromStrict $
    BS.concat
      [ "{"
      , BS.intercalate "," (map renderPair fields)
      , "}"
      ]
  where
    renderPair (key, value) =
      BS.concat
        [ BL.toStrict $ encode key
        , ":"
        , BL.toStrict $ encode value
        ]
