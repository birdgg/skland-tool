mod app;
mod config;
mod http;
mod scheduler;
mod sign;
mod types;

use std::path::PathBuf;

use anyhow::Result;
use clap::{Parser, Subcommand};

use crate::app::{print_reports, run_sign_in};
use crate::config::load_config;
use crate::http::SklandClient;
use crate::scheduler::run_daemon;

#[derive(Debug, Parser)]
#[command(name = "skland-tool", about = "森空岛每日签到命令行工具")]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    #[arg(long, alias = "config", global = true, default_value = ".env")]
    env: PathBuf,
}

#[derive(Debug, Clone, Copy, Subcommand)]
enum Command {
    #[command(name = "run-once", about = "立即执行一次签到")]
    RunOnce,
    #[command(name = "daemon", about = "常驻运行并按每天北京时间调度")]
    Daemon,
    #[command(name = "check-config", about = "校验配置文件")]
    CheckConfig,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let command = cli.command.unwrap_or(Command::RunOnce);
    let config = load_config(&cli.env)?;

    match command {
        Command::CheckConfig => {
            println!("配置 OK: {}", config.env_file.display());
            println!(
                "调度: 每天北京时间 {:02}:{:02}",
                config.schedule.hour, config.schedule.minute
            );
        }
        Command::RunOnce => {
            let client = SklandClient::new()?;
            let reports = run_sign_in(&config, &client).await;
            print_reports(&reports);
        }
        Command::Daemon => {
            let client = SklandClient::new()?;
            run_daemon(config, client).await;
        }
    }

    Ok(())
}
