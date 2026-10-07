//! Times as the user's device shows them: Rails' formats, in the OS
//! timezone (DST included) rather than UTC. Rails formatted on the server,
//! so everyone saw the server's zone; the Flutter build did the same.

use chrono::{DateTime, Local, NaiveDate, TimeZone};

fn local<Tz: TimeZone>(at: i64, tz: &Tz) -> Option<DateTime<Tz>> {
    tz.timestamp_opt(at, 0).single()
}

/// Rails' `%l:%M %p`: "4:30 PM".
pub fn clock(at: i64) -> String {
    clock_in(at, &Local)
}

/// Rails' `%m/%d/%Y %l:%M %p`: "10/05/2026 4:30 PM".
/// Rails' distance_of_time_in_words, for a span in seconds: "5 minutes",
/// "about 1 hour", "3 days".
pub fn in_words(secs: i64) -> String {
    let s = secs.max(0);
    let mins = (s + 30) / 60;
    let plural = |n: i64, unit: &str| if n == 1 { format!("1 {unit}") } else { format!("{n} {unit}s") };
    match mins {
        0 => "less than a minute".into(),
        1..=44 => plural(mins, "minute"),
        45..=89 => "about 1 hour".into(),
        90..=1439 => format!("about {}", plural((mins + 30) / 60, "hour")),
        1440..=2519 => "1 day".into(),
        2520..=43199 => plural((mins + 720) / 1440, "day"),
        _ => format!("about {}", plural((mins + 21600) / 43200, "month")),
    }
}

/// Rails' "%b %d, %Y" (Oct 06, 2026), in the device's zone.
pub fn date_short(at: i64) -> String {
    chrono::DateTime::from_timestamp(at, 0)
        .map(|t| t.with_timezone(&chrono::Local).format("%b %d, %Y").to_string())
        .unwrap_or_default()
}

pub fn date_time(at: i64) -> String {
    date_time_in(at, &Local)
}

/// Rails' `%b %d, %Y`: "Oct 05, 2026".
pub fn date_long(at: i64) -> String {
    date_long_in(at, &Local)
}

pub fn clock_in<Tz: TimeZone>(at: i64, tz: &Tz) -> String
where
    Tz::Offset: std::fmt::Display,
{
    local(at, tz).map(|t| t.format("%-I:%M %p").to_string()).unwrap_or_default()
}

pub fn date_time_in<Tz: TimeZone>(at: i64, tz: &Tz) -> String
where
    Tz::Offset: std::fmt::Display,
{
    local(at, tz).map(|t| t.format("%m/%d/%Y %-I:%M %p").to_string()).unwrap_or_default()
}

pub fn date_long_in<Tz: TimeZone>(at: i64, tz: &Tz) -> String
where
    Tz::Offset: std::fmt::Display,
{
    local(at, tz).map(|t| t.format("%b %d, %Y").to_string()).unwrap_or_default()
}

/// The first second of a local calendar day, given that day's UTC midnight
/// (what the core's search parses `YYYY-MM-DD` into). On a DST change at
/// midnight the earliest valid instant is used.
pub fn local_midnight(utc_midnight: i64) -> i64 {
    local_midnight_in(utc_midnight, &Local)
}

pub fn local_midnight_in<Tz: TimeZone>(utc_midnight: i64, tz: &Tz) -> i64 {
    let Some(date) = DateTime::from_timestamp(utc_midnight, 0).map(|d| d.date_naive()) else { return utc_midnight };
    day_start(date, tz).unwrap_or(utc_midnight)
}

fn day_start<Tz: TimeZone>(date: NaiveDate, tz: &Tz) -> Option<i64> {
    let midnight = date.and_hms_opt(0, 0, 0)?;
    tz.from_local_datetime(&midnight)
        .earliest()
        // A zone that skips midnight (a few DST rules do) starts the day at 1:00.
        .or_else(|| tz.from_local_datetime(&date.and_hms_opt(1, 0, 0)?).earliest())
        .map(|t| t.timestamp())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::FixedOffset;

    // 2026-10-05 21:30 UTC.
    const AT: i64 = 1_791_235_800;

    #[test]
    fn words_like_rails() {
        assert_eq!(in_words(10), "less than a minute");
        assert_eq!(in_words(5 * 60), "5 minutes");
        assert_eq!(in_words(3599), "about 1 hour");
        assert_eq!(in_words(6 * 3600), "about 6 hours");
        assert_eq!(in_words(86400), "1 day");
        assert_eq!(in_words(7 * 86400), "7 days");
    }

    #[test]
    fn formats_in_the_given_zone() {
        let utc = FixedOffset::east_opt(0).unwrap();
        let new_york = FixedOffset::west_opt(4 * 3600).unwrap();
        let tokyo = FixedOffset::east_opt(9 * 3600).unwrap();
        assert_eq!(clock_in(AT, &utc), "9:30 PM");
        assert_eq!(clock_in(AT, &new_york), "5:30 PM");
        assert_eq!(date_time_in(AT, &tokyo), "10/06/2026 6:30 AM", "the next day in Tokyo");
        assert_eq!(date_long_in(AT, &tokyo), "Oct 06, 2026");
        assert_eq!(clock_in(AT - 21 * 3600 - 1800, &utc), "12:00 AM");
    }

    #[test]
    fn a_local_day_starts_at_local_midnight() {
        let utc_midnight = 1_791_158_400; // 2026-10-05 00:00 UTC
        let new_york = FixedOffset::west_opt(4 * 3600).unwrap();
        assert_eq!(local_midnight_in(utc_midnight, &new_york), utc_midnight + 4 * 3600);
        let tokyo = FixedOffset::east_opt(9 * 3600).unwrap();
        assert_eq!(local_midnight_in(utc_midnight, &tokyo), utc_midnight - 9 * 3600);
    }
}
