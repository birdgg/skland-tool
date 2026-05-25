# skland-tool

森空岛每日签到命令行工具，支持《明日方舟》和《终末地》。

## 配置

复制示例配置：

```bash
cp .env.example .env
```

编辑 `.env`，填入森空岛 `data.content`：

```env
SKLAND_TOKEN=这里填森空岛 data.content
SKLAND_GAME_TYPE=0
```

`SKLAND_GAME_TYPE` 可选值：

```text
0 = 明日方舟 + 终末地
1 = 仅明日方舟
2 = 仅终末地
```

## 使用

检查配置：

```bash
cargo run -- check-config
```

立即签到一次：

```bash
cargo run -- run-once
```

常驻运行，每天按 `.env` 中的北京时间执行：

```bash
cargo run -- daemon
```

## Release 二进制

```bash
cargo build --release
./target/release/skland-tool run-once --env .env
./target/release/skland-tool daemon --env .env
```

## 日志

最近一次签到报告会保存到：

```bash
cat "$HOME/Library/Application Support/skland-tool/last-report.txt"
```

如果使用 `launchctl` 后台运行，并把输出重定向到项目日志，可查看：

```bash
tail -f /Users/birdgg/skland-tool/skland-tool.daemon.log
```
