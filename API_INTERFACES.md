# 森空岛登录与签到接口归纳

本文整理当前项目中与森空岛登录授权、角色绑定查询、每日签到相关的接口。代码入口主要在 `skland_api.py`，完整执行顺序由 `SklandAPI.do_full_sign_in()` 串联。

## 整体流程

1. 用户先在浏览器登录森空岛官网，并手动获取 `user_token`。
2. 生成设备指纹 `dId`。
3. 使用 `user_token` 换取 OAuth 授权码 `code`。
4. 使用授权码 `code` 换取森空岛接口凭据 `cred` 与签名密钥 `token`。
5. 使用 `cred`、签名、`dId` 查询账号绑定的游戏角色。
6. 按绑定角色调用《明日方舟》或《终末地》签到接口。

## 用户 Token 获取

该步骤不在脚本内自动执行，由用户在浏览器中完成。

| 项目 | 内容 |
| --- | --- |
| 入口 | `README.md` 中的 Token 获取说明 |
| 前置条件 | 已在浏览器登录森空岛官网 |
| 地址 | `https://web-api.skland.com/account/info/hg` |
| 返回字段 | `data.content` |
| 项目用途 | 将 `data.content` 配置到 `.env` 的 `SKLAND_TOKEN` |

示例配置：

```env
SKLAND_TOKEN=这里填入 data.content 的长字符串
SKLAND_GAME_TYPE=0
```

## 设备指纹接口

用于获取后续森空岛请求需要携带的 `dId`。代码中会缓存生成结果，避免同一次运行重复生成。

| 项目 | 内容 |
| --- | --- |
| 调用方法 | `SklandAPI.get_device_id()` |
| 请求方法 | `POST` |
| 地址 | `https://fp-it.portal101.cn/deviceprofile/v4` |
| 鉴权 | 无用户鉴权；请求体内包含加密后的浏览器指纹 |
| 成功判断 | `code == 1100` |
| 产物 | `B` + `detail.deviceId`，作为 `dId` |

请求体字段：

```json
{
  "appId": "default",
  "compress": 2,
  "data": "加密后的浏览器指纹数据",
  "encode": 5,
  "ep": "RSA 加密后的 UUID",
  "organization": "UWXspnCCJN4sfYlNfqps",
  "os": "web"
}
```

## OAuth 授权码接口

使用用户配置的 `user_token` 换取一次性授权码。

| 项目 | 内容 |
| --- | --- |
| 调用方法 | `SklandAPI.get_authorization(user_token)` |
| 请求方法 | `POST` |
| 地址 | `https://as.hypergryph.com/user/oauth2/v2/grant` |
| 成功判断 | `status == 0` |
| 返回使用字段 | `data.code` |

请求头：

```http
User-Agent: Mozilla/5.0 ... SKLand/1.52.1
Accept-Encoding: gzip
Connection: close
X-Requested-With: com.hypergryph.skland
dId: <设备指纹>
```

请求体：

```json
{
  "appCode": "4ca99fa6b56cc2ba",
  "token": "<.env 中的 SKLAND_TOKEN>",
  "type": 0
}
```

## 森空岛凭据接口

使用 OAuth 授权码换取后续接口所需的 `cred` 和签名密钥 `token`。

| 项目 | 内容 |
| --- | --- |
| 调用方法 | `SklandAPI.get_credential(authorization)` |
| 请求方法 | `POST` |
| 地址 | `https://zonai.skland.com/web/v1/user/auth/generate_cred_by_code` |
| 成功判断 | `code == 0` |
| 返回使用字段 | `data.token`、`data.cred` |

请求头同 OAuth 授权码接口的基础请求头。

请求体：

```json
{
  "code": "<OAuth 授权码>",
  "kind": 1
}
```

## 签名请求头

查询绑定与签到接口都需要签名请求头，由 `SklandAPI._get_signed_headers()` 生成。

固定基础头：

```http
User-Agent: Mozilla/5.0 ... SKLand/1.52.1
Accept-Encoding: gzip
Connection: close
X-Requested-With: com.hypergryph.skland
dId: <设备指纹>
cred: <generate_cred_by_code 返回的 data.cred>
```

额外签名头：

```http
platform: 3
timestamp: <当前秒级时间戳 - 2>
dId: <设备指纹>
vName: 1.0.0
sign: <签名结果>
```

签名逻辑：

```text
header_ca = {"platform":"3","timestamp":"...","dId":"...","vName":"1.0.0"}

GET:
  raw = path + query + timestamp + compact_json(header_ca)

POST:
  raw = path + compact_json_body + timestamp + compact_json(header_ca)

hmac = HMAC-SHA256(key = credential.token, message = raw).hexdigest()
sign = MD5(hmac).hexdigest()
```

注意：`POST` 请求用于签名的 body 必须与实际请求 JSON 的紧凑格式一致，例如 `{"gameId":1,"uid":"123"}`。

## 角色绑定查询接口

用于获取当前账号绑定的游戏与角色信息。项目只保留 `arknights` 和 `endfield` 两类游戏绑定。

| 项目 | 内容 |
| --- | --- |
| 调用方法 | `SklandAPI.get_binding_list(cred)` |
| 请求方法 | `GET` |
| 地址 | `https://zonai.skland.com/api/v1/game/player/binding` |
| 鉴权 | 需要 `cred`、`sign`、`dId` 等签名头 |
| 成功判断 | `code == 0` |
| 登录过期判断 | `message == "用户未登录"` |

返回使用字段：

```text
data.list[].appCode
data.list[].bindingList[].gameName
data.list[].bindingList[].nickName
data.list[].bindingList[].channelName
data.list[].bindingList[].uid
data.list[].bindingList[].gameId
data.list[].bindingList[].roles
```

`roles` 主要用于《终末地》签到，因为终末地需要按角色逐个签到。

## 明日方舟签到接口

| 项目 | 内容 |
| --- | --- |
| 调用方法 | `SklandAPI.sign_arknights(cred, binding)` |
| 请求方法 | `POST` |
| 地址 | `https://zonai.skland.com/api/v1/game/attendance` |
| 鉴权 | 需要 `cred`、`sign`、`dId` 等签名头 |
| 成功判断 | `code == 0` |
| 奖励字段 | `data.awards[].resource.name`、`data.awards[].count` |

请求体：

```json
{
  "gameId": 1,
  "uid": "<角色 UID>"
}
```

`gameId` 实际来自绑定接口返回的 `binding.gameId`，不在代码中写死。

失败时项目会读取 `message` 作为错误原因。已签到、重复签到等响应会被上层当作“今日已签到”状态处理。

## 终末地签到接口

| 项目 | 内容 |
| --- | --- |
| 调用方法 | `SklandAPI.sign_endfield(cred, binding)` |
| 请求方法 | `POST` |
| 地址 | `https://zonai.skland.com/web/v1/game/endfield/attendance` |
| 鉴权 | 需要 `cred`、`sign`、`dId` 等签名头 |
| 成功判断 | `code == 0` |
| 奖励字段 | `data.awardIds[].id` 与 `data.resourceInfoMap` |

该接口请求体为空，签名时传入的 body 也是空字符串。

额外请求头：

```http
Content-Type: application/json
sk-game-role: 3_<roleId>_<serverId>
referer: https://game.skland.com/
origin: https://game.skland.com/
```

角色来源：

```text
binding.roles[].roleId
binding.roles[].serverId
binding.roles[].nickname
```

奖励解析逻辑：

1. 读取 `data.awardIds` 中的奖励 ID。
2. 使用奖励 ID 到 `data.resourceInfoMap` 查找资源详情。
3. 输出 `name x count`。

## 当前代码中的游戏签到范围

当前 Haskell 版本通过 `skland-tool.toml` 中的 `token` 登录，并固定每天同时尝试《明日方舟》和《终末地》签到。

执行分支在 `SklandTool.App.runBindings` 中：

```text
appCode == "arknights" -> 明日方舟签到
appCode == "endfield" -> 终末地签到
```

## 接口调用顺序速查

```text
浏览器登录森空岛
  -> GET https://web-api.skland.com/account/info/hg
  -> 复制 data.content 到 config.yaml

脚本运行
  -> POST https://fp-it.portal101.cn/deviceprofile/v4
  -> POST https://as.hypergryph.com/user/oauth2/v2/grant
  -> POST https://zonai.skland.com/web/v1/user/auth/generate_cred_by_code
  -> GET  https://zonai.skland.com/api/v1/game/player/binding
  -> POST https://zonai.skland.com/api/v1/game/attendance
  -> POST https://zonai.skland.com/web/v1/game/endfield/attendance
```
