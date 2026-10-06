//! Message search, with Rails' filter syntax (`shared/_search_filter_options`):
//! `from: user`, `in: channel`, `has: file|image|link`, `before:` / `after:` /
//! `on: YYYY-MM-DD`, and `pinned: true`. Anything else is free text, matched
//! case-insensitively against the message body. Rails searched server
//! channels plus people; Flutter only had from/in.
//!
//! Search runs over the local cache: what this device has seen.

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Query {
    pub text: String,
    pub from: Vec<String>,
    pub in_channels: Vec<String>,
    pub has: Vec<Has>,
    /// Unix seconds bounds (UTC days).
    pub after: Option<i64>,
    pub before: Option<i64>,
    pub pinned: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Has {
    Link,
    Image,
    File,
}

const IMAGE_EXT: &[&str] = &[".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif"];

/// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// `YYYY-MM-DD` → the day's first second (UTC).
pub fn parse_date(s: &str) -> Option<i64> {
    let mut parts = s.trim().splitn(3, '-');
    let y: i64 = parts.next()?.parse().ok()?;
    let m: i64 = parts.next()?.parse().ok()?;
    let d: i64 = parts.next()?.parse().ok()?;
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    Some(days_from_civil(y, m, d) * 86_400)
}

impl Query {
    /// Parses `"deploy from: tac in: dev-log has: link after: 2026-10-01"`.
    /// A filter's value is the next word (`from: tac` or `from:tac`).
    pub fn parse(input: &str) -> Query {
        let mut q = Query::default();
        let mut text = Vec::new();
        let mut words = input.split_whitespace().peekable();
        while let Some(word) = words.next() {
            let Some((key, inline)) = word.split_once(':').filter(|(k, _)| {
                matches!(k.to_ascii_lowercase().as_str(), "from" | "in" | "has" | "before" | "after" | "on" | "pinned")
            }) else {
                text.push(word);
                continue;
            };
            let value = if inline.is_empty() { words.next().unwrap_or("").to_owned() } else { inline.to_owned() };
            let value = value.trim_start_matches('@').trim_start_matches('#').to_owned();
            match key.to_ascii_lowercase().as_str() {
                "from" if !value.is_empty() => q.from.push(value.to_lowercase()),
                "in" if !value.is_empty() => q.in_channels.push(value.to_lowercase()),
                "has" => match value.to_lowercase().as_str() {
                    "link" | "links" => q.has.push(Has::Link),
                    "image" | "images" => q.has.push(Has::Image),
                    "file" | "files" => q.has.push(Has::File),
                    _ => {}
                },
                "before" => q.before = parse_date(&value),
                "after" => q.after = parse_date(&value).map(|d| d + 86_400),
                "on" => {
                    if let Some(d) = parse_date(&value) {
                        q.after = Some(d);
                        q.before = Some(d + 86_400);
                    }
                }
                "pinned" => q.pinned = matches!(value.to_lowercase().as_str(), "true" | "yes" | "1"),
                _ => {}
            }
        }
        q.text = text.join(" ").to_lowercase();
        q
    }

    pub fn is_empty(&self) -> bool {
        self == &Query::default()
    }

    /// Whether a message matches. `author` is every name the author goes by
    /// (nickname, display name, username, npub/hex prefix); `channel` the
    /// channel's name.
    pub fn matches(&self, body: &str, at: i64, pinned: bool, author: &[String], channel: &str) -> bool {
        let lower = body.to_lowercase();
        if !self.text.is_empty() && !lower.contains(&self.text) {
            return false;
        }
        if !self.from.is_empty()
            && !self.from.iter().any(|f| author.iter().any(|a| a.to_lowercase().starts_with(f.as_str())))
        {
            return false;
        }
        if !self.in_channels.is_empty() && !self.in_channels.iter().any(|c| c == &channel.to_lowercase()) {
            return false;
        }
        if self.after.is_some_and(|a| at < a) || self.before.is_some_and(|b| at >= b) {
            return false;
        }
        if self.pinned && !pinned {
            return false;
        }
        self.has.iter().all(|h| has(&lower, *h))
    }
}

fn urls(body: &str) -> impl Iterator<Item = &str> {
    body.split_whitespace().filter(|w| w.starts_with("http://") || w.starts_with("https://"))
}

fn has(body: &str, h: Has) -> bool {
    let is_image = |u: &str| IMAGE_EXT.iter().any(|e| u.split(['?', '#']).next().unwrap_or(u).ends_with(e));
    match h {
        Has::Link => urls(body).next().is_some(),
        Has::Image => urls(body).any(is_image),
        // Uploads are Blossom URLs: a path ending in a file name with an
        // extension, that isn't an image.
        Has::File => urls(body).any(|u| {
            let path = u.split("://").nth(1).and_then(|rest| rest.split_once('/')).map(|(_, p)| p).unwrap_or("");
            let name = path.split(['?', '#']).next().unwrap_or("").rsplit('/').next().unwrap_or("");
            !is_image(u) && name.contains('.')
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_rails_filters_both_spellings() {
        let q = Query::parse("Deploy from: @Tac in:#dev-log has: link pinned: true after: 2026-10-01");
        assert_eq!(q.text, "deploy");
        assert_eq!(q.from, vec!["tac"]);
        assert_eq!(q.in_channels, vec!["dev-log"]);
        assert_eq!(q.has, vec![Has::Link]);
        assert!(q.pinned);
        assert_eq!(q.after, Some(parse_date("2026-10-02").unwrap()), "after a day means from the next day");
        assert!(!q.is_empty());
        assert!(Query::parse("   ").is_empty());
    }

    #[test]
    fn dates() {
        assert_eq!(parse_date("1970-01-01"), Some(0));
        assert_eq!(parse_date("2026-10-05"), Some(1_791_158_400));
        assert_eq!(parse_date("2026-13-01"), None);
        let q = Query::parse("on: 2026-10-05");
        assert_eq!((q.after, q.before), (Some(1_791_158_400), Some(1_791_244_800)));
    }

    #[test]
    fn matching() {
        let names = vec!["Tac (A)".to_owned(), "tac".to_owned(), "npub1abc".to_owned()];
        let q = Query::parse("relay from: tac");
        assert!(q.matches("the Relay is up", 0, false, &names, "general"));
        assert!(!q.matches("nothing here", 0, false, &names, "general"));
        assert!(!q.matches("relay", 0, false, &["ember".into()], "general"));

        assert!(Query::parse("in: general").matches("x", 0, false, &names, "General"));
        assert!(!Query::parse("in: dev").matches("x", 0, false, &names, "general"));
        assert!(Query::parse("pinned: true").matches("x", 0, true, &names, "g"));
        assert!(!Query::parse("pinned: true").matches("x", 0, false, &names, "g"));
    }

    #[test]
    fn has_link_image_file() {
        let n: Vec<String> = vec![];
        let img = "look https://blossom.example/abc.png?x=1";
        let file = "notes https://blossom.example/plan.pdf";
        let link = "see https://example.com";
        assert!(Query::parse("has: image").matches(img, 0, false, &n, "g"));
        assert!(!Query::parse("has: image").matches(file, 0, false, &n, "g"));
        assert!(Query::parse("has: file").matches(file, 0, false, &n, "g"));
        assert!(!Query::parse("has: file").matches(link, 0, false, &n, "g"));
        assert!(Query::parse("has: link").matches(link, 0, false, &n, "g"));
        assert!(!Query::parse("has: link").matches("no links", 0, false, &n, "g"));
    }
}
