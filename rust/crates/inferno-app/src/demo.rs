//! Synthetic history for the list spike: 10,000 messages from a handful of
//! authors, with bursts that exercise grouping, replies, long wraps and
//! system lines. Deterministic, so screenshots and timings are repeatable.

#[derive(Debug, Clone, PartialEq)]
pub struct DemoAuthor {
    pub name: &'static str,
    pub role_color: u32,
    pub avatar_color: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DemoMessage {
    pub author: usize,
    pub at: i64,
    pub body: String,
    pub system: bool,
    pub reply_to: Option<usize>,
    pub edited: bool,
}

pub const AUTHORS: [DemoAuthor; 6] = [
    DemoAuthor { name: "Tac", role_color: 0xdc2626, avatar_color: 0x7f1d1d },
    DemoAuthor { name: "ember", role_color: 0xf59e0b, avatar_color: 0x78350f },
    DemoAuthor { name: "frostbyte", role_color: 0x3b82f6, avatar_color: 0x1e3a8a },
    DemoAuthor { name: "moss", role_color: 0x10b981, avatar_color: 0x064e3b },
    DemoAuthor { name: "nightjar", role_color: 0xcccbca, avatar_color: 0x1e1c1b },
    DemoAuthor { name: "quill", role_color: 0xa855f7, avatar_color: 0x581c87 },
];

const LINES: [&str; 12] = [
    "anyone up for voice later?",
    "pushed the fix, relays look happy now",
    "lol",
    "the new theme is so much better on my monitor",
    "can someone check if invites still work after the update",
    "brb",
    "I think the timeout was a rate limit from damus, not us. Backoff kicked in after the second try and everything went through on the third.",
    "same",
    "ok that worked",
    "who broke the build",
    "nice",
    "Long message incoming: the virtualized list only draws what's on screen, so ten thousand rows should scroll as smoothly as ten. If this paragraph wraps onto three or four lines at the default window width, the row heights vary, which is the case that usually trips up list virtualization.",
];

/// Deterministic xorshift so the history is identical every run.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

pub fn history(count: usize) -> Vec<DemoMessage> {
    let mut rng = Rng(0x1f2e3d4c5b6a7988);
    let mut at = 1_759_000_000;
    let mut author = 0;
    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        // Mostly short gaps (grouped bursts), sometimes long ones.
        at += if rng.below(5) == 0 { 300 + rng.below(3_000) as i64 } else { 5 + rng.below(90) as i64 };
        if rng.below(3) == 0 {
            author = rng.below(AUTHORS.len() as u64) as usize;
        }
        let system = rng.below(150) == 0;
        let reply_to = (i > 10 && rng.below(25) == 0).then(|| i - 1 - rng.below(8) as usize);
        let body = if system {
            format!("{} joined the server.", AUTHORS[author].name)
        } else {
            format!("{} (#{i})", LINES[rng.below(LINES.len() as u64) as usize])
        };
        out.push(DemoMessage { author, at, body, system, reply_to, edited: rng.below(40) == 0 });
    }
    out
}

/// The spec's grouping rule: same author, neither is a system message, the
/// later one isn't a reply, and under 300 seconds apart.
pub fn grouped(prev: Option<&DemoMessage>, cur: &DemoMessage) -> bool {
    match prev {
        Some(p) => {
            p.author == cur.author && !p.system && !cur.system && cur.reply_to.is_none() && cur.at - p.at < 300
        }
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn msg(author: usize, at: i64) -> DemoMessage {
        DemoMessage { author, at, body: String::new(), system: false, reply_to: None, edited: false }
    }

    #[test]
    fn grouping_rule() {
        let a = msg(0, 1_000);
        assert!(grouped(Some(&a), &msg(0, 1_299)));
        assert!(!grouped(Some(&a), &msg(0, 1_300)), "300s apart breaks the group");
        assert!(!grouped(Some(&a), &msg(1, 1_010)), "different author");
        assert!(!grouped(Some(&a), &DemoMessage { reply_to: Some(0), ..msg(0, 1_010) }), "replies start a group");
        assert!(!grouped(Some(&DemoMessage { system: true, ..a.clone() }), &msg(0, 1_010)));
        assert!(!grouped(None, &a));
    }

    #[test]
    fn history_is_deterministic_and_mixed() {
        let h = history(10_000);
        assert_eq!(h, history(10_000));
        let grouped_count = (1..h.len()).filter(|&i| grouped(Some(&h[i - 1]), &h[i])).count();
        assert!(grouped_count > 3_000 && grouped_count < 9_000, "{grouped_count}");
        assert!(h.iter().any(|m| m.system) && h.iter().any(|m| m.reply_to.is_some()));
    }
}
