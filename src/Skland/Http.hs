module Skland.Http
  ( getAuthorization
  , getCredential
  , getBindingList
  , signArknights
  , signEndfield
  )
where

import System.Exit (ExitCode (..))
import System.Process (CreateProcess, proc, readCreateProcessWithExitCode)

import Skland.Json
import Skland.Sign
import Skland.Types

userAgent :: String
userAgent = "Mozilla/5.0 SKLand/1.52.1"

baseHeaders :: String -> [(String, String)]
baseHeaders did =
  [ ("User-Agent", userAgent)
  , ("Accept-Encoding", "gzip")
  , ("Connection", "close")
  , ("X-Requested-With", "com.hypergryph.skland")
  , ("dId", did)
  ]

getAuthorization :: String -> UserConfig -> IO (Either String String)
getAuthorization did user = do
  let body =
        "{\"appCode\":\"4ca99fa6b56cc2ba\",\"token\":"
          <> compactString (userToken user)
          <> ",\"type\":0}"
  response <- curlPost "https://as.hypergryph.com/user/oauth2/v2/grant" (baseHeaders did) body
  pure (response >>= parseAuthorization)

getCredential :: String -> String -> IO (Either String Credential)
getCredential did code = do
  let body = "{\"code\":" <> compactString code <> ",\"kind\":1}"
  response <- curlPost "https://zonai.skland.com/web/v1/user/auth/generate_cred_by_code" (baseHeaders did) body
  pure (response >>= parseCredential)

getBindingList :: String -> Credential -> IO (Either String [Binding])
getBindingList did credential = do
  let path = "/api/v1/game/player/binding"
  signed <- signedHeaders credential did "GET" path ""
  case signed of
    Left err -> pure (Left err)
    Right signHeaders -> do
      response <- curlGet ("https://zonai.skland.com" <> path) (baseHeaders did <> [("cred", cred credential)] <> signHeaders)
      pure (response >>= parseBindings)

signArknights :: String -> Credential -> Binding -> IO GameSignResult
signArknights did credential binding = do
  let path = "/api/v1/game/attendance"
      body = arknightsBody binding
  signed <- signedHeaders credential did "POST" path body
  case signed of
    Left err -> pure (SignFailed "明日方舟" (Just (roleName binding)) err)
    Right signHeaders -> do
      response <- curlPost ("https://zonai.skland.com" <> path) (baseHeaders did <> [("cred", cred credential)] <> signHeaders) body
      pure (parseAttendanceResult "明日方舟" (roleName binding) response)

signEndfield :: String -> Credential -> Binding -> EndfieldRole -> IO GameSignResult
signEndfield did credential binding role = do
  let path = "/web/v1/game/endfield/attendance"
      body = ""
      roleHeader = "3_" <> roleId role <> "_" <> serverId role
      character =
        if null (roleNickname role)
          then roleName binding
          else roleNickname role
  signed <- signedHeaders credential did "POST" path body
  case signed of
    Left err -> pure (SignFailed "终末地" (Just character) err)
    Right signHeaders -> do
      response <-
        curlPost
          ("https://zonai.skland.com" <> path)
          ( baseHeaders did
              <> [ ("cred", cred credential)
                 , ("Content-Type", "application/json")
                 , ("sk-game-role", roleHeader)
                 , ("referer", "https://game.skland.com/")
                 , ("origin", "https://game.skland.com/")
                 ]
              <> signHeaders
          )
          body
      pure (parseAttendanceResult "终末地" character response)

curlGet :: String -> [(String, String)] -> IO (Either String String)
curlGet url headers = runCurl (["-sS", "--compressed", "-X", "GET", url] <> headerArgs headers)

curlPost :: String -> [(String, String)] -> String -> IO (Either String String)
curlPost url headers body =
  runCurl (["-sS", "--compressed", "-X", "POST", url] <> headerArgs headers <> ["--data-binary", body])

runCurl :: [String] -> IO (Either String String)
runCurl args = do
  (code, out, err) <- readCreateProcessWithExitCode (procSpec args) ""
  case code of
    ExitSuccess -> pure (Right out)
    ExitFailure _ -> pure (Left ("curl 失败: " <> err))

procSpec :: [String] -> CreateProcess
procSpec = proc "curl"

headerArgs :: [(String, String)] -> [String]
headerArgs headers = concat [["-H", key <> ": " <> value] | (key, value) <- headers]

parseAuthorization :: String -> Either String String
parseAuthorization raw = do
  json <- parseJson raw
  case lookupKey "status" json >>= asInt of
    Just 0 ->
      maybe (Left "OAuth 响应缺少 data.code") Right (lookupPath ["data", "code"] json >>= asString)
    statusValue ->
      Left ("OAuth 授权失败: " <> messageOf json <> " status=" <> show statusValue)

parseCredential :: String -> Either String Credential
parseCredential raw = do
  json <- parseJson raw
  case lookupKey "code" json >>= asInt of
    Just 0 -> do
      credentialCred <- maybe (Left "credential 响应缺少 data.cred") Right (lookupPath ["data", "cred"] json >>= asString)
      credentialToken <- maybe (Left "credential 响应缺少 data.token") Right (lookupPath ["data", "token"] json >>= asString)
      Right (Credential credentialCred credentialToken)
    codeValue ->
      Left ("credential 生成失败: " <> messageOf json <> " code=" <> show codeValue)

parseBindings :: String -> Either String [Binding]
parseBindings raw = do
  json <- parseJson raw
  case lookupKey "code" json >>= asInt of
    Just 0 -> do
      groups <- maybe (Left "绑定响应缺少 data.list") Right (lookupPath ["data", "list"] json >>= asArray)
      pure (concatMap parseGroup groups)
    codeValue ->
      Left ("查询绑定角色失败: " <> messageOf json <> " code=" <> show codeValue)

parseGroup :: Json -> [Binding]
parseGroup group =
  let code = stringField "appCode" group
      list = maybe [] id (lookupKey "bindingList" group >>= asArray)
   in map (parseBinding code) list

parseBinding :: String -> Json -> Binding
parseBinding code value =
  Binding
    { appCode = code
    , gameName = stringField "gameName" value
    , roleName = firstNonEmpty [stringField "nickName" value, stringField "nickname" value, stringField "name" value]
    , channelName = stringField "channelName" value
    , uid = stringField "uid" value
    , gameId = intField "gameId" value
    , roles = maybe [] (map parseRole) (lookupKey "roles" value >>= asArray)
    }

parseRole :: Json -> EndfieldRole
parseRole value =
  EndfieldRole
    { roleId = firstNonEmpty [stringField "roleId" value, stringField "id" value]
    , serverId = firstNonEmpty [stringField "serverId" value, stringField "server" value]
    , roleNickname = firstNonEmpty [stringField "nickname" value, stringField "nickName" value, stringField "name" value]
    }

parseAttendanceResult :: String -> String -> Either String String -> GameSignResult
parseAttendanceResult game character (Left err) = SignFailed game (Just character) err
parseAttendanceResult game character (Right raw) =
  case parseJson raw of
    Left err -> SignFailed game (Just character) ("签到响应 JSON 解析失败: " <> err)
    Right json ->
      case lookupKey "code" json >>= asInt of
        Just 0 -> SignSucceeded game character (parseAwards json)
        _ ->
          let msg = messageOf json
           in if isAlreadySigned msg
                then AlreadySigned game character msg
                else SignFailed game (Just character) msg

parseAwards :: Json -> [Award]
parseAwards json =
  case lookupPath ["data", "awards"] json >>= asArray of
    Just awards -> map parseArknightsAward awards
    Nothing -> parseEndfieldAwards json

parseArknightsAward :: Json -> Award
parseArknightsAward value =
  Award
    { awardName = firstNonEmpty [maybe "" id (lookupPath ["resource", "name"] value >>= asString), stringField "name" value]
    , awardCount = intField "count" value
    }

parseEndfieldAwards :: Json -> [Award]
parseEndfieldAwards json =
  let ids = maybe [] id (lookupPath ["data", "awardIds"] json >>= asArray)
      resourceMap = maybe [] id (lookupPath ["data", "resourceInfoMap"] json >>= asObject)
   in [ Award (resourceName awardId resourceMap) (resourceCount awardId resourceMap)
      | item <- ids
      , let awardId = firstNonEmpty [stringField "id" item, maybe "" id (asString item)]
      , not (null awardId)
      ]

resourceName :: String -> [(String, Json)] -> String
resourceName awardId resourceMap =
  case lookup awardId resourceMap of
    Just value -> firstNonEmpty [stringField "name" value, maybe "" id (lookupPath ["resource", "name"] value >>= asString), awardId]
    Nothing -> awardId

resourceCount :: String -> [(String, Json)] -> Int
resourceCount awardId resourceMap =
  case lookup awardId resourceMap of
    Just value -> max 1 (intField "count" value)
    Nothing -> 1

messageOf :: Json -> String
messageOf json = firstNonEmpty [maybe "" id (lookupKey "message" json >>= asString), maybe "" id (lookupKey "msg" json >>= asString), "未知错误"]

isAlreadySigned :: String -> Bool
isAlreadySigned msg = any (`contains` msg) ["已", "重复", "already", "signed"]

contains :: String -> String -> Bool
contains needle haystack = any (needle `prefixOf`) (tails haystack)

prefixOf :: String -> String -> Bool
prefixOf [] _ = True
prefixOf _ [] = False
prefixOf (x : xs) (y : ys) = x == y && prefixOf xs ys

tails :: [a] -> [[a]]
tails [] = [[]]
tails xs@(_ : rest) = xs : tails rest

firstNonEmpty :: [String] -> String
firstNonEmpty [] = ""
firstNonEmpty (x : xs)
  | null x = firstNonEmpty xs
  | otherwise = x
