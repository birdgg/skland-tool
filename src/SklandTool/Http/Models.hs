module SklandTool.Http.Models
  ( ApiResponse (..)
  , AttendanceResponse
  , BindingGroup (..)
  , BindingItem (..)
  , BindingListData (..)
  , BindingListResponse
  , CredentialData (..)
  , CredentialResponse
  , EndfieldRoleItem (..)
  , OAuthData (..)
  , OAuthRequest (..)
  , OAuthResponse (..)
  , apiMessage
  , messageText
  , parseAttendanceBody
  , parseAttendanceRaw
  , parseAuthorization
  , parseBindings
  , parseCredential
  )
where

import Data.Aeson
  ( FromJSON (parseJSON)
  , ToJSON (toJSON)
  , Value (..)
  , eitherDecode
  , object
  , withObject
  , (.=)
  )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Int (Int64)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import qualified Data.Aeson.Types as AesonTypes
import qualified Data.ByteString.Lazy as BL

import SklandTool.Types

data OAuthRequest = OAuthRequest
  { oauthAppCode :: !Text
  , oauthToken :: !Text
  , oauthType :: !Int
  }
  deriving stock (Eq, Show)

instance ToJSON OAuthRequest where
  toJSON OAuthRequest{..} =
    object
      [ "appCode" .= oauthAppCode
      , "token" .= oauthToken
      , "type" .= oauthType
      ]

data OAuthResponse = OAuthResponse
  { oauthStatus :: !(Maybe Int64)
  , oauthMessage :: !(Maybe Text)
  , oauthMsg :: !(Maybe Text)
  , oauthData :: !(Maybe OAuthData)
  }
  deriving stock (Eq, Show)

instance FromJSON OAuthResponse where
  parseJSON = withObject "OAuthResponse" $ \obj ->
    OAuthResponse
      <$> optionalField intish obj "status"
      <*> optionalField stringish obj "message"
      <*> optionalField stringish obj "msg"
      <*> optionalJSON obj "data"

data OAuthData = OAuthData
  { oauthCode :: !Text
  }
  deriving stock (Eq, Show)

instance FromJSON OAuthData where
  parseJSON = withObject "OAuthData" $ \obj ->
    OAuthData <$> fieldWithDefault "" stringish obj "code"

data ApiResponse a = ApiResponse
  { apiCode :: !(Maybe Int64)
  , apiMessageField :: !(Maybe Text)
  , apiMsg :: !(Maybe Text)
  , apiData :: !(Maybe a)
  }
  deriving stock (Eq, Show)

instance FromJSON a => FromJSON (ApiResponse a) where
  parseJSON = withObject "ApiResponse" $ \obj ->
    ApiResponse
      <$> optionalField intish obj "code"
      <*> optionalField stringish obj "message"
      <*> optionalField stringish obj "msg"
      <*> optionalJSON obj "data"

type CredentialResponse = ApiResponse CredentialData
type BindingListResponse = ApiResponse BindingListData
type AttendanceResponse = ApiResponse Value

data CredentialData = CredentialData
  { credentialDataCred :: !Text
  , credentialDataToken :: !Text
  }
  deriving stock (Eq, Show)

instance FromJSON CredentialData where
  parseJSON = withObject "CredentialData" $ \obj ->
    CredentialData
      <$> fieldWithDefault "" stringish obj "cred"
      <*> fieldWithDefault "" stringish obj "token"

data BindingListData = BindingListData
  { bindingListGroups :: ![BindingGroup]
  }
  deriving stock (Eq, Show)

instance FromJSON BindingListData where
  parseJSON = withObject "BindingListData" $ \obj ->
    BindingListData <$> fieldWithDefault [] parseJSON obj "list"

data BindingGroup = BindingGroup
  { groupAppCode :: !Text
  , groupBindings :: ![BindingItem]
  }
  deriving stock (Eq, Show)

instance FromJSON BindingGroup where
  parseJSON = withObject "BindingGroup" $ \obj ->
    BindingGroup
      <$> fieldWithDefault "" stringish obj "appCode"
      <*> fieldWithDefault [] parseJSON obj "bindingList"

data BindingItem = BindingItem
  { itemGameName :: !Text
  , itemNickName :: !Text
  , itemNickname :: !Text
  , itemName :: !Text
  , itemChannelName :: !Text
  , itemUid :: !Text
  , itemGameId :: !Int64
  , itemRoles :: ![EndfieldRoleItem]
  }
  deriving stock (Eq, Show)

instance FromJSON BindingItem where
  parseJSON = withObject "BindingItem" $ \obj ->
    BindingItem
      <$> fieldWithDefault "" stringish obj "gameName"
      <*> fieldWithDefault "" stringish obj "nickName"
      <*> fieldWithDefault "" stringish obj "nickname"
      <*> fieldWithDefault "" stringish obj "name"
      <*> fieldWithDefault "" stringish obj "channelName"
      <*> fieldWithDefault "" stringish obj "uid"
      <*> fieldWithDefault 0 intish obj "gameId"
      <*> fieldWithDefault [] parseJSON obj "roles"

data EndfieldRoleItem = EndfieldRoleItem
  { roleItemRoleId :: !Text
  , roleItemId :: !Text
  , roleItemServerId :: !Text
  , roleItemServer :: !Text
  , roleItemNickname :: !Text
  , roleItemNickName :: !Text
  , roleItemName :: !Text
  }
  deriving stock (Eq, Show)

instance FromJSON EndfieldRoleItem where
  parseJSON = withObject "EndfieldRoleItem" $ \obj ->
    EndfieldRoleItem
      <$> fieldWithDefault "" stringish obj "roleId"
      <*> fieldWithDefault "" stringish obj "id"
      <*> fieldWithDefault "" stringish obj "serverId"
      <*> fieldWithDefault "" stringish obj "server"
      <*> fieldWithDefault "" stringish obj "nickname"
      <*> fieldWithDefault "" stringish obj "nickName"
      <*> fieldWithDefault "" stringish obj "name"

parseAuthorization :: OAuthResponse -> Either AppError Text
parseAuthorization response =
  case response.oauthStatus of
    Just 0 ->
      case response.oauthData >>= nonEmpty . oauthCode of
        Just code -> Right code
        Nothing -> Left $ ParseError "OAuth 响应缺少 data.code"
    status -> Left $ HttpError $ "OAuth 授权失败: " <> messageText response.oauthMessage response.oauthMsg <> " status=" <> T.pack (show status)

parseCredential :: CredentialResponse -> Either AppError Credential
parseCredential response =
  case response.apiCode of
    Just 0 ->
      case response.apiData of
        Nothing -> Left $ ParseError "credential 响应缺少 data"
        Just data_
          | T.null data_.credentialDataCred -> Left $ ParseError "credential 响应缺少 data.cred"
          | T.null data_.credentialDataToken -> Left $ ParseError "credential 响应缺少 data.token"
          | otherwise -> Right $ Credential data_.credentialDataCred data_.credentialDataToken
    code -> Left $ HttpError $ "credential 生成失败: " <> apiMessage response <> " code=" <> T.pack (show code)

parseBindings :: BindingListResponse -> Either AppError [Binding]
parseBindings response =
  case response.apiCode of
    Just 0 ->
      case response.apiData of
        Nothing -> Left $ ParseError "绑定响应缺少 data.list"
        Just data_ -> Right $ concatMap parseGroup data_.bindingListGroups
    code -> Left $ HttpError $ "查询绑定角色失败: " <> apiMessage response <> " code=" <> T.pack (show code)

parseGroup :: BindingGroup -> [Binding]
parseGroup group = map (parseBinding group.groupAppCode) group.groupBindings

parseBinding :: Text -> BindingItem -> Binding
parseBinding appCode item =
  Binding
    { bindingAppCode = appCode
    , bindingGameName = item.itemGameName
    , bindingRoleName = firstNonEmpty [item.itemNickName, item.itemNickname, item.itemName]
    , bindingChannelName = item.itemChannelName
    , bindingUid = item.itemUid
    , bindingGameId = item.itemGameId
    , bindingRoles = map parseRole item.itemRoles
    }

parseRole :: EndfieldRoleItem -> EndfieldRole
parseRole item =
  EndfieldRole
    { roleId = firstNonEmpty [item.roleItemRoleId, item.roleItemId]
    , roleServerId = firstNonEmpty [item.roleItemServerId, item.roleItemServer]
    , roleNickname = firstNonEmpty [item.roleItemNickname, item.roleItemNickName, item.roleItemName]
    }

parseAttendanceBody :: Text -> Text -> AttendanceResponse -> SignResult
parseAttendanceBody game character response
  | response.apiCode == Just 0 =
      SignSucceeded game character (maybe [] parseAwards response.apiData)
  | isAlreadySigned message =
      AlreadySigned game character message
  | otherwise =
      SignFailed game (Just character) message
  where
    message = apiMessage response

parseAttendanceRaw :: Text -> Text -> BL.ByteString -> Either Text SignResult
parseAttendanceRaw game character raw =
  case eitherDecode raw of
    Left err -> Left $ T.pack err
    Right response -> Right $ parseAttendanceBody game character response

parseAwards :: Value -> [Award]
parseAwards data_ =
  case data_ of
    Object obj ->
      case KeyMap.lookup "awards" obj of
        Just (Array awards) -> map parseArknightsAward $ foldr (:) [] awards
        _ -> parseEndfieldAwards obj
    _ -> []

parseArknightsAward :: Value -> Award
parseArknightsAward value =
  Award
    { awardName = firstNonEmpty [pointerString ["resource", "name"] value, objectText "name" value]
    , awardCount = objectInt "count" value
    }

parseEndfieldAwards :: KeyMap.KeyMap Value -> [Award]
parseEndfieldAwards obj =
  case KeyMap.lookup "awardIds" obj of
    Just (Array ids) -> mapMaybe parseOne $ foldr (:) [] ids
    _ -> []
  where
    resourceMap =
      case KeyMap.lookup "resourceInfoMap" obj of
        Just (Object values) -> Just values
        _ -> Nothing
    parseOne item =
      let awardId = firstNonEmpty [objectText "id" item, scalarText item]
       in if T.null awardId
            then Nothing
            else
              let resource = resourceMap >>= KeyMap.lookup (Key.fromText awardId)
               in Just $
                    Award
                      { awardName = resourceName awardId resource
                      , awardCount = max 1 $ maybe 1 (objectInt "count") resource
                      }

resourceName :: Text -> Maybe Value -> Text
resourceName fallback = maybe fallback $ \value ->
  firstNonEmpty [objectText "name" value, pointerString ["resource", "name"] value, fallback]

apiMessage :: ApiResponse a -> Text
apiMessage response = messageText response.apiMessageField response.apiMsg

messageText :: Maybe Text -> Maybe Text -> Text
messageText first second = firstNonEmpty [maybe "" id first, maybe "" id second, "未知错误"]

isAlreadySigned :: Text -> Bool
isAlreadySigned message = any (`T.isInfixOf` message) ["已", "重复", "already", "signed"]

optionalJSON :: FromJSON a => KeyMap.KeyMap Value -> Text -> AesonTypes.Parser (Maybe a)
optionalJSON obj key =
  case KeyMap.lookup (Key.fromText key) obj of
    Nothing -> pure Nothing
    Just Null -> pure Nothing
    Just value -> Just <$> parseJSON value

optionalField :: (Value -> AesonTypes.Parser a) -> KeyMap.KeyMap Value -> Text -> AesonTypes.Parser (Maybe a)
optionalField parser obj key =
  case KeyMap.lookup (Key.fromText key) obj of
    Nothing -> pure Nothing
    Just Null -> pure Nothing
    Just value -> Just <$> parser value

fieldWithDefault :: a -> (Value -> AesonTypes.Parser a) -> KeyMap.KeyMap Value -> Text -> AesonTypes.Parser a
fieldWithDefault fallback parser obj key =
  case KeyMap.lookup (Key.fromText key) obj of
    Nothing -> pure fallback
    Just Null -> pure fallback
    Just value -> parser value

stringish :: Value -> AesonTypes.Parser Text
stringish = \case
  String value -> pure value
  Number n -> pure $ either (T.pack . show) (T.pack . show) (floatingOrInteger n :: Either Double Int64)
  Bool True -> pure "true"
  Bool False -> pure "false"
  Null -> pure ""
  _ -> pure ""

intish :: Value -> AesonTypes.Parser Int64
intish = \case
  Number n -> pure $ either (const 0) id (floatingOrInteger n :: Either Double Int64)
  String text ->
    pure $ case TR.signed TR.decimal text of
      Right (value, _) -> value
      Left _ -> 0
  _ -> pure 0

objectText :: Text -> Value -> Text
objectText key = \case
  Object obj ->
    case KeyMap.lookup (Key.fromText key) obj of
      Just value -> either (const "") id $ AesonTypes.parseEither stringish value
      Nothing -> ""
  _ -> ""

objectInt :: Text -> Value -> Int64
objectInt key = \case
  Object obj ->
    case KeyMap.lookup (Key.fromText key) obj of
      Just value -> either (const 0) id $ AesonTypes.parseEither intish value
      Nothing -> 0
  _ -> 0

pointerString :: [Text] -> Value -> Text
pointerString keys value = go keys value
  where
    go [] current = either (const "") id $ AesonTypes.parseEither stringish current
    go (key : rest) (Object obj) =
      maybe "" (go rest) $ KeyMap.lookup (Key.fromText key) obj
    go _ _ = ""

scalarText :: Value -> Text
scalarText value = either (const "") id $ AesonTypes.parseEither stringish value

firstNonEmpty :: [Text] -> Text
firstNonEmpty = \case
  [] -> ""
  value : rest
    | T.null value -> firstNonEmpty rest
    | otherwise -> value

nonEmpty :: Text -> Maybe Text
nonEmpty text
  | T.null text = Nothing
  | otherwise = Just text

mapMaybe :: (a -> Maybe b) -> [a] -> [b]
mapMaybe f = foldr (\x acc -> maybe acc (: acc) (f x)) []
