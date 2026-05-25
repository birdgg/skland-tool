# Rust 架构设计

`skland-tool` 现在是 Rust CLI。核心拆分如下：

- `src/main.rs`: CLI 入口，使用 `clap` 解析 `run-once`、`daemon`、`check-config`。
- `src/config.rs`: 读取 `.env`、解析单账号/多账号配置、校验调度时间。
- `src/app.rs`: 业务编排，按单账号执行授权、凭据、绑定查询、签到和报告保存。
- `src/http.rs`: 森空岛 HTTP client，使用 `reqwest` 和 `serde_json` 处理接口。
- `src/sign.rs`: HMAC-SHA256 + MD5 签名，替代旧版本外部 `openssl` 进程。
- `src/scheduler.rs`: 每天北京时间定时调度，使用 `tokio` 异步 sleep。
- `src/types.rs`: 配置、绑定、奖励、签到结果等领域类型。

主要依赖：

- `clap`: 命令行参数。
- `tokio`: 异步运行时与调度等待。
- `reqwest`: HTTPS 请求。
- `serde_json`: JSON 请求/响应处理。
- `hmac`、`sha2`、`md-5`、`hex`: 森空岛签名。
- `dotenvy`: `.env` 配置解析。
- `chrono`: 北京时间调度计算。

默认配置文件仍是 `.env`，设备 ID 和最后报告仍写入用户配置目录下的 `skland-tool` 子目录。
