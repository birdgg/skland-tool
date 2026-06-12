# skland-tool

森空岛每日签到命令行工具，支持《明日方舟》和《终末地》。

## 配置

复制示例配置：

```bash
cp skland-tool.toml.example skland-tool.toml
```

编辑 `skland-tool.toml`，填入森空岛 `data.content`：

```toml
token = "这里填森空岛 data.content"

[schedule]
hour = 6
minute = 0
timezone = "Asia/Shanghai"
```

工具会每天同时尝试《明日方舟》和《终末地》签到。

## 使用

校验配置、立即签到一次或常驻运行：

```bash
cabal run skland-tool -- doctor --config skland-tool.toml
cabal run skland-tool -- run --config skland-tool.toml
cabal run skland-tool -- daemon --config skland-tool.toml
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
