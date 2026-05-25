use std::time::Duration;

use chrono::{DateTime, Days, FixedOffset, LocalResult, NaiveTime, TimeZone, Utc};

use crate::app::{print_reports, run_sign_in};
use crate::http::SklandClient;
use crate::types::{AppConfig, ScheduleConfig};

const MAX_SLEEP_SECONDS: u64 = 1_800;

pub async fn run_daemon(config: AppConfig, client: SklandClient) {
    loop {
        let now = Utc::now();
        let target = next_run_at(config.schedule, now);
        let delay =
            u64::try_from(target.signed_duration_since(now).num_seconds().max(0)).unwrap_or(0);
        println!("下一次签到时间: {}", format_beijing(target));
        sleep_chunked(delay).await;

        let reports = run_sign_in(&config, &client).await;
        print_reports(&reports);
    }
}

pub fn next_run_at(schedule: ScheduleConfig, now: DateTime<Utc>) -> DateTime<Utc> {
    let offset = beijing_offset();
    let local_now = now.with_timezone(&offset);
    let time = NaiveTime::from_hms_opt(schedule.hour, schedule.minute, 0).unwrap_or(NaiveTime::MIN);
    let today = local_now.date_naive();
    let candidate_local = today.and_time(time);
    let candidate = match offset.from_local_datetime(&candidate_local) {
        LocalResult::Single(value) => value.with_timezone(&Utc),
        _ => now,
    };
    if candidate > now {
        candidate
    } else {
        let tomorrow = today.checked_add_days(Days::new(1)).unwrap_or(today);
        let tomorrow_local = tomorrow.and_time(time);
        match offset.from_local_datetime(&tomorrow_local) {
            LocalResult::Single(value) => value.with_timezone(&Utc),
            _ => now,
        }
    }
}

async fn sleep_chunked(seconds: u64) {
    let mut remaining = seconds;
    while remaining > 0 {
        let current = remaining.min(MAX_SLEEP_SECONDS);
        tokio::time::sleep(Duration::from_secs(current)).await;
        remaining -= current;
    }
}

fn format_beijing(utc_time: DateTime<Utc>) -> String {
    utc_time
        .with_timezone(&beijing_offset())
        .format("%Y-%m-%d %H:%M:%S Asia/Shanghai")
        .to_string()
}

fn beijing_offset() -> FixedOffset {
    FixedOffset::east_opt(8 * 3_600).expect("Asia/Shanghai fixed offset should be valid")
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;

    use super::*;

    #[test]
    fn next_run_uses_today_when_future() {
        let now = Utc.with_ymd_and_hms(2026, 5, 24, 21, 0, 0).unwrap();
        let target = next_run_at(ScheduleConfig { hour: 6, minute: 0 }, now);

        assert_eq!(target, Utc.with_ymd_and_hms(2026, 5, 24, 22, 0, 0).unwrap());
    }

    #[test]
    fn next_run_uses_tomorrow_when_elapsed() {
        let now = Utc.with_ymd_and_hms(2026, 5, 24, 23, 0, 0).unwrap();
        let target = next_run_at(ScheduleConfig { hour: 6, minute: 0 }, now);

        assert_eq!(target, Utc.with_ymd_and_hms(2026, 5, 25, 22, 0, 0).unwrap());
    }
}
