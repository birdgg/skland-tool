# Haskell 架构设计

本文基于 `API_INTERFACES.md` 设计 `skland-tool` 的 Haskell 版本架构。目标是用 `effectful` 组织业务 effect，用 `servant-client` 描述并调用森空岛接口，并支持每天北京时间 06:00 自动执行一次签到。

## 目标边界

- 从配置读取用户 `user_token`、昵称与游戏范围。
- 生成或复用设备指纹 `dId`。
- 按接口顺序完成 OAuth 授权、森空岛凭据生成、绑定角色查询和签到。
- 对《明日方舟》和《终末地》分别解析签到奖励。
- 默认同时执行《明日方舟》和《终末地》签到。
- 支持一次性执行与常驻调度执行。
- 默认调度时间为 `Asia/Shanghai` 每天 06:00。

不建议把所有逻辑写在 `Main.hs`。`Main.hs` 只负责解析命令、加载配置、创建 HTTP manager、运行 effect 栈。

## 推荐目录

```text
app/
  Main.hs
src/
  Skland/
    App.hs
    Config.hs
    Scheduler.hs
    Types.hs
    Error.hs
    Sign.hs
    Device.hs
    Api/
      Routes.hs
      Client.hs
    Effects/
      Http.hs
      DeviceId.hs
      Clock.hs
      Logger.hs
      Store.hs
```

## 分层

```text
Main
  -> Config
  -> Scheduler
  -> App
      -> DeviceId effect
      -> SklandHttp effect
      -> Clock effect
      -> Logger effect
      -> Store effect
          -> servant-client
          -> signing
          -> local cache/config files
```

### Main

职责：

- 解析命令：
  - `run-once`：立即执行一次全部用户签到。
  - `daemon`：常驻运行，每天北京时间 06:00 触发。
  - `check-config`：只校验配置和用户 token 是否存在。
- 加载 `config.yaml`。
- 构造 `ClientEnv`。
- 运行 effectful interpreter。

### App

`Skland.App` 是业务编排层，里面不直接写 HTTP 细节。

核心函数：

```haskell
runAllUsers :: AppConfig -> Eff AppEffects [UserSignReport]
runUser :: UserConfig -> Eff AppEffects UserSignReport
```

单用户执行顺序：

```text
getDeviceId
  -> getAuthorization userToken
  -> getCredential code
  -> getBindingList credential
  -> filter bindings by game_type, default AllGames
  -> sign Arknights bindings
  -> sign Endfield each role
  -> collect report
```

默认需求是《明日方舟》和《终末地》都签到，所以 `game_type` 应默认解析为 `AllGames`。实现时不能在某一个游戏签到成功后提前返回；同一用户下两个游戏的绑定都要遍历并记录结果。

## Effect 设计

推荐把外部依赖和可替换能力拆成 effect，业务层只依赖 effect API。

```haskell
type AppEffects =
  '[ Logger
   , Clock
   , Store
   , DeviceId
   , SklandHttp
   , Error SklandError
   , IOE
   ]
```

### SklandHttp

包装 servant-client 调用，隐藏 `ClientM`、`ClientEnv`、错误转换和签名头拼装。

```haskell
data SklandHttp :: Effect where
  RequestDeviceProfile :: DeviceProfileRequest -> SklandHttp m DeviceProfileResponse
  RequestAuthorization :: DeviceIdText -> UserToken -> SklandHttp m AuthorizationResponse
  RequestCredential :: DeviceIdText -> AuthorizationCode -> SklandHttp m CredentialResponse
  RequestBindingList :: DeviceIdText -> Credential -> SklandHttp m BindingListResponse
  RequestArknightsAttendance :: DeviceIdText -> Credential -> Binding -> SklandHttp m AttendanceResponse
  RequestEndfieldAttendance :: DeviceIdText -> Credential -> EndfieldRole -> SklandHttp m EndfieldAttendanceResponse
```

Interpreter：

```haskell
runSklandHttpServant
  :: ClientEnvSet
  -> Eff (SklandHttp : es) a
  -> Eff es a
```

`ClientEnvSet` 建议按 host 拆开，因为接口跨 3 个域名：

```haskell
data ClientEnvSet = ClientEnvSet
  { fpPortalEnv :: ClientEnv
  , authEnv :: ClientEnv
  , zonaiEnv :: ClientEnv
  }
```

### DeviceId

设备指纹生成需要处理加密浏览器指纹和 RSA UUID。建议单独隔离，避免污染业务层。

```haskell
data DeviceId :: Effect where
  GetDeviceId :: DeviceId m DeviceIdText
```

Interpreter 策略：

- 先从本地 cache 读取未过期 `dId`。
- 无缓存时调用设备指纹接口。
- 成功后写入 cache。

缓存文件建议：

```text
~/.config/skland-tool/device.json
```

### Store

保存低敏运行状态，不保存明文密码。用户 token 来自 `config.yaml`。

```haskell
data Store :: Effect where
  LoadDeviceCache :: Store m (Maybe DeviceCache)
  SaveDeviceCache :: DeviceCache -> Store m ()
  SaveLastReport :: DailyReport -> Store m ()
```

### Clock

用于签名 timestamp 和调度，便于测试。

```haskell
data Clock :: Effect where
  CurrentUnixSeconds :: Clock m Int64
  CurrentZonedTime :: Clock m ZonedTime
  DelayMicros :: Int -> Clock m ()
```

签名使用 `当前秒级时间戳 - 2`。

## Servant API 类型

按域名拆 API，避免一个 `BaseUrl` 混多个 host。

### 设备指纹

```haskell
type DeviceProfileApi =
  "deviceprofile" :> "v4"
    :> ReqBody '[JSON] DeviceProfileRequest
    :> Post '[JSON] DeviceProfileResponse
```

Base URL：

```text
https://fp-it.portal101.cn
```

### OAuth

```haskell
type OAuthApi =
  "user" :> "oauth2" :> "v2" :> "grant"
    :> Header' '[Required] "User-Agent" Text
    :> Header' '[Required] "Accept-Encoding" Text
    :> Header' '[Required] "Connection" Text
    :> Header' '[Required] "X-Requested-With" Text
    :> Header' '[Required] "dId" Text
    :> ReqBody '[JSON] AuthorizationRequest
    :> Post '[JSON] AuthorizationResponse
```

Base URL：

```text
https://as.hypergryph.com
```

### Zonai

```haskell
type ZonaiApi =
       "web" :> "v1" :> "user" :> "auth" :> "generate_cred_by_code"
          :> BaseHeaders
          :> ReqBody '[JSON] CredentialRequest
          :> Post '[JSON] CredentialResponse
  :<|> "api" :> "v1" :> "game" :> "player" :> "binding"
          :> SignedHeaders
          :> Get '[JSON] BindingListResponse
  :<|> "api" :> "v1" :> "game" :> "attendance"
          :> SignedHeaders
          :> ReqBody '[JSON] ArknightsAttendanceRequest
          :> Post '[JSON] AttendanceResponse
  :<|> "web" :> "v1" :> "game" :> "endfield" :> "attendance"
          :> SignedHeaders
          :> Header' '[Required] "Content-Type" Text
          :> Header' '[Required] "sk-game-role" Text
          :> Header' '[Required] "referer" Text
          :> Header' '[Required] "origin" Text
          :> ReqBody '[JSON] NoContentBody
          :> Post '[JSON] EndfieldAttendanceResponse
```

Base URL：

```text
https://zonai.skland.com
```

`BaseHeaders` 和 `SignedHeaders` 可以先用类型别名封装，但实际实现时要注意 Servant 里的 header 参数会展开到 client 函数参数中。

## 类型模型

核心类型建议集中在 `Skland.Types`：

```haskell
newtype UserToken = UserToken Text
newtype DeviceIdText = DeviceIdText Text
newtype AuthorizationCode = AuthorizationCode Text

data Credential = Credential
  { credentialCred :: Text
  , credentialToken :: Text
  }

data GameType
  = AllGames
  | ArknightsOnly
  | EndfieldOnly

data UserConfig = UserConfig
  { nickname :: Text
  , userToken :: UserToken
  , gameType :: GameType
  }

data Binding = Binding
  { appCode :: Text
  , gameName :: Text
  , nickName :: Text
  , channelName :: Text
  , uid :: Text
  , gameId :: Int
  , roles :: [EndfieldRole]
  }

data EndfieldRole = EndfieldRole
  { roleId :: Text
  , serverId :: Text
  , roleNickname :: Text
  }
```

响应类型保留原始 code/message/data：

```haskell
data ApiEnvelope a = ApiEnvelope
  { code :: Int
  , message :: Maybe Text
  , data_ :: Maybe a
  }
```

OAuth 接口是 `status == 0`，建议单独建响应类型，不强行复用 `ApiEnvelope`。

## 签名模块

`Skland.Sign` 只负责确定性签名，不做 IO。

```haskell
signedHeaders
  :: Credential
  -> DeviceIdText
  -> Int64
  -> RequestShape
  -> SignedHeaderSet

data RequestShape
  = SignGet
      { path :: Text
      , query :: Text
      }
  | SignPost
      { path :: Text
      , compactBody :: ByteString
      }
```

关键要求：

- `header_ca` JSON 必须紧凑且字段稳定为 `platform`、`timestamp`、`dId`、`vName`。
- POST 签名 body 必须与实际发送 body 的紧凑 JSON 一致。
- HMAC-SHA256 的 key 是 `credential.token`。
- `sign = md5(hex(hmacSha256(raw)))`。

建议 `compactBody` 由同一个 helper 生成后同时用于签名与请求，避免 body 空格或字段顺序导致签名失败。

## 配置

`config.yaml`：

```yaml
timezone: Asia/Shanghai
schedule:
  hour: 6
  minute: 0
users:
  - nickname: "我的大号"
    token: "森空岛 data.content"
    game_type: 0
```

`game_type: 0` 是推荐默认值，表示同一账号下《明日方舟》和《终末地》都签到。后续实现可以允许省略 `game_type`，省略时按 `0` 处理。

对应类型：

```haskell
data AppConfig = AppConfig
  { timezone :: TimeZoneName
  , schedule :: ScheduleConfig
  , users :: [UserConfig]
  }

data ScheduleConfig = ScheduleConfig
  { hour :: Int
  , minute :: Int
  }
```

## 调度

推荐同时支持两种运行方式。

### run-once

适合给 `cron`、`launchd`、GitHub Actions 或手工执行使用：

```text
skland-tool run-once --config config.yaml
```

优点是进程短、失败边界清楚。部署到 macOS 时可以用 `launchd` 设置每天 06:00 运行。

### daemon

适合用户希望程序自己常驻：

```text
skland-tool daemon --config config.yaml
```

调度逻辑：

```haskell
nextRunAt
  :: TimeZone
  -> TimeOfDay
  -> UTCTime
  -> UTCTime
```

规则：

- 把当前 UTC 转成北京时间。
- 如果今天 06:00 还没到，就返回今天 06:00。
- 如果已经过了今天 06:00，就返回明天 06:00。
- sleep 到目标时间。
- 执行 `runAllUsers`。
- 无论成功或失败，都计算下一次 06:00，避免一天内重复执行。

## 错误模型

```haskell
data SklandError
  = ConfigError Text
  | HttpError ClientError
  | ApiError
      { endpoint :: Text
      , code :: Maybe Int
      , status :: Maybe Int
      , message :: Text
      }
  | LoginExpired Text
  | SignError Text
  | DeviceProfileError Text
  | DecodeError Text
```

`message == "用户未登录"` 映射为 `LoginExpired`，方便最终报告里提醒用户更新 `user_token`。

## 报告输出

每次运行输出结构化结果，便于未来接通知渠道。

```haskell
data UserSignReport = UserSignReport
  { user :: Text
  , results :: [GameSignResult]
  }

data GameSignResult
  = SignSucceeded
      { game :: Text
      , character :: Text
      , awards :: [Award]
      }
  | AlreadySigned
      { game :: Text
      , character :: Text
      , reason :: Text
      }
  | SignFailed
      { game :: Text
      , character :: Maybe Text
      , reason :: Text
      }
```

## Cabal 依赖建议

建议把业务代码放进 library，executable 只保留 `Main.hs`：

```cabal
library
    hs-source-dirs:   src
    exposed-modules:
        Skland.App
        Skland.Config
        Skland.Scheduler
        Skland.Types
        Skland.Error
        Skland.Sign
        Skland.Device
        Skland.Api.Routes
        Skland.Api.Client
        Skland.Effects.Http
        Skland.Effects.DeviceId
        Skland.Effects.Clock
        Skland.Effects.Logger
        Skland.Effects.Store
    default-language: GHC2021

executable skland-tool
    main-is:          Main.hs
    hs-source-dirs:   app
    build-depends:    base, skland-tool
    default-language: GHC2021
```

关键扩展建议放到需要的模块顶部，不全局开启：

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
```

```cabal
build-depends:
    base
  , aeson
  , bytestring
  , crypton
  , effectful
  , effectful-core
  , http-client
  , http-client-tls
  , memory
  , servant
  , servant-client
  , text
  , time
  , unordered-containers
  , yaml
```

如果后续要做命令行参数：

```cabal
  , optparse-applicative
```

如果要严格处理 IANA 时区 `Asia/Shanghai`：

```cabal
  , timezone-olson
  , timezone-series
```

## 实现顺序

1. 补 `Types`、`Config`、`Error`，让配置能解析。
2. 补 `Api.Routes` 和 `Api.Client`，先打通 OAuth 与 credential。
3. 补 `Sign`，用固定样例测试 GET/POST raw string 与签名格式。
4. 补 binding 查询和明日方舟签到。
5. 补终末地 `sk-game-role` 多角色签到。
6. 补 `run-once` 命令。
7. 补 `daemon` 调度或 macOS `launchd` 示例。

## 关键实现注意事项

- 不要把 `credential.token` 和用户 `user_token` 打到普通日志。
- `dId` 可以缓存，但接口异常时要允许清理缓存重新生成。
- 终末地签到按 `binding.roles` 逐个角色执行。
- 明日方舟和终末地是同一用户流程里的两个独立分支，任一分支失败不应阻止另一分支继续尝试。
- 已签到、重复签到不应让整个用户流程失败，应记录为 `AlreadySigned`。
- 多用户执行建议串行开始，避免风控；之后如需并发再加限速。
- 签名 body 要和 servant 实际发送 body 保持一致，这是最容易出错的点。
