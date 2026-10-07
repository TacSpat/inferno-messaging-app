//! Message bodies as Rails renders them (`Message#render_content_html`):
//! Redcarpet markdown with hard line breaks, bare URLs autolinked, fenced
//! code and strikethrough, then mentions styled. The timeline draws with
//! Makepad's Markdown widget (CommonMark), so this rewrites the text into
//! the CommonMark that renders the same way.

/// Mentions become links to `mention:<target>`, drawn as Rails' pills:
/// `mention:<hex pubkey>`, `mention:everyone` (also @here) or
/// `mention:role:<rrggbb>`.
pub const MENTION_SCHEME: &str = "mention:";

/// Who `@word` refers to, if anyone (Rails only styles real members and
/// roles): the `mention:` target after the scheme.
pub type Resolve<'a> = &'a dyn Fn(&str) -> Option<String>;

/// The first Inferno invite link in `body`, as written (with its
/// `nostr:` prefix if it has one), so the card can stand in for it.
pub fn invite_link(body: &str) -> Option<String> {
    let mut rest = body;
    while let Some(i) = rest.find("naddr1") {
        let tail = &rest[i..];
        let len = tail.bytes().take_while(|b| b.is_ascii_lowercase() || b.is_ascii_digit()).count();
        let naddr = &tail[..len];
        if inferno_core::server::invite_link::parse(naddr).is_some() {
            let start = if rest[..i].ends_with("nostr:") { i - 6 } else { i };
            return Some(rest[start..i + len].to_owned());
        }
        rest = &tail[len.max(1)..];
    }
    None
}

#[cfg(test)]
pub fn plain(_: &str) -> Option<String> {
    None
}

/// Whether a link shows as the image itself (Rails' `unfurl_images`):
/// image file extensions, GIF hosts, and Blossom blobs (a 64-hex path).
pub fn is_media(url: &str) -> bool {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return false;
    }
    let path = url.split(['?', '#']).next().unwrap_or(url).to_lowercase();
    let file = path.rsplit('/').next().unwrap_or("");
    [".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".bmp"].iter().any(|e| file.ends_with(e))
        || inferno_core::gifs::looks_like_gif(url)
        || file.split('.').next().is_some_and(|stem| stem.len() == 64 && stem.chars().all(|c| c.is_ascii_hexdigit()))
}

pub fn to_markdown(body: &str, resolve: Resolve) -> String {
    to_markdown_with(body, resolve, &|_| None)
}

/// Custom emoji in messages: `:name:` with a known image becomes an
/// inline image link the renderer draws (Rails' 1.375em, or 3.5rem when
/// the message is only emoji).
pub const EMOJI_SCHEME: &str = "emoji:";
pub const BIG_EMOJI_SCHEME: &str = "emoji-big:";

/// Rails' `enlarge_emoji_only`: nothing but emoji (custom or Unicode),
/// at most ten of them.
pub fn emoji_only(body: &str, emoji: Resolve) -> bool {
    let mut count = 0;
    let mut rest = body.trim();
    if rest.is_empty() {
        return false;
    }
    while !rest.is_empty() {
        if let Some(after) = rest.strip_prefix(':') {
            if let Some(end) = after.find(':') {
                if emoji(&after[..end]).is_some() {
                    count += 1;
                    rest = after[end + 1..].trim_start();
                    continue;
                }
            }
            return false;
        }
        let c = rest.chars().next().unwrap_or(' ');
        if c.is_whitespace() || c == '\u{200d}' || ('\u{fe00}'..='\u{fe0f}').contains(&c) || ('\u{1f3fb}'..='\u{1f3ff}').contains(&c) {
            // Joiners, variation selectors and skin tones belong to the emoji before.
        } else if emojis::get(&c.to_string()).is_some() || is_pictographic(c) {
            count += 1;
        } else {
            return false;
        }
        rest = &rest[c.len_utf8()..];
    }
    (1..=10).contains(&count)
}

fn is_pictographic(c: char) -> bool {
    matches!(c as u32, 0x1F300..=0x1FAFF | 0x2600..=0x27BF | 0x1F1E6..=0x1F1FF | 0x2B00..=0x2BFF)
}

pub fn to_markdown_with(body: &str, resolve: Resolve, emoji: Resolve) -> String {
    let big = emoji_only(body, emoji);
    let mut out = String::with_capacity(body.len() + 16);
    let mut in_fence = false;
    let lines: Vec<&str> = body.split('\n').collect();
    for (i, line) in lines.iter().enumerate() {
        let fence = line.trim_start().starts_with("```");
        if fence {
            in_fence = !in_fence;
            out.push_str(line);
        } else if in_fence {
            out.push_str(line);
        } else {
            out.push_str(&inline(line, resolve, emoji, big));
        }
        if i + 1 < lines.len() {
            // Redcarpet's hard_wrap: a single newline is a line break.
            if !in_fence && !fence && !line.trim().is_empty() && !lines[i + 1].trim().is_empty() {
                out.push('\\');
            }
            out.push('\n');
        }
    }
    out
}

/// Autolinks and mentions, outside inline code spans.
fn inline(line: &str, resolve: Resolve, emoji: Resolve, big: bool) -> String {
    let mut out = String::with_capacity(line.len());
    for (k, part) in line.split('`').enumerate() {
        if k > 0 {
            out.push('`');
        }
        // Odd parts are inside `code`.
        if k % 2 == 1 {
            out.push_str(part);
            continue;
        }
        let mut words = part.split(' ').peekable();
        while let Some(w) = words.next() {
            if (w.starts_with("https://") || w.starts_with("http://")) && !w.contains("](") {
                // Trailing punctuation stays outside the link.
                let trimmed = w.trim_end_matches(['.', ',', ')', '!', '?', ';', ':']);
                out.push('<');
                out.push_str(trimmed);
                out.push('>');
                out.push_str(&w[trimmed.len()..]);
            } else if let Some(name) = w.strip_prefix('@').filter(|n| !n.is_empty()) {
                let len: usize = name.chars().take_while(|c| c.is_alphanumeric() || *c == '_').map(char::len_utf8).sum();
                let target = (len > 0).then(|| {
                    let word = &name[..len];
                    match word.to_lowercase().as_str() {
                        "everyone" | "here" => Some("everyone".to_owned()),
                        _ => resolve(word),
                    }
                });
                match target.flatten() {
                    Some(t) => {
                        out.push_str(&format!("[@{}]({MENTION_SCHEME}{t})", &name[..len]));
                        out.push_str(&name[len..]);
                    }
                    None => out.push_str(w),
                }
            } else {
                out.push_str(&emojify(w, emoji, big));
            }
            if words.peek().is_some() {
                out.push(' ');
            }
        }
    }
    out
}

/// `:name:` → an emoji link, for names with an image.
fn emojify(word: &str, emoji: Resolve, big: bool) -> String {
    let mut out = String::with_capacity(word.len());
    let mut rest = word;
    while let Some(start) = rest.find(':') {
        let after = &rest[start + 1..];
        let Some(end) = after.find(':') else { break };
        let name = &after[..end];
        match emoji(name).filter(|_| inferno_core::server::custom::valid_emoji_name(name)) {
            Some(url) => {
                out.push_str(&rest[..start]);
                let scheme = if big { BIG_EMOJI_SCHEME } else { EMOJI_SCHEME };
                out.push_str(&format!("[:{name}:]({scheme}{url})"));
                rest = &after[end + 1..];
            }
            None => {
                out.push_str(&rest[..start + 1]);
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::{plain, to_markdown as md};

    #[test]
    fn custom_emoji_inline_and_enlarged() {
        let known = |n: &str| (n == "fire_ball").then(|| "https://b.example/f.png".to_owned());
        let none = |_: &str| None;
        assert_eq!(super::to_markdown_with(":fire_ball: hot take", &none, &known), "[:fire_ball:](emoji:https://b.example/f.png) hot take");
        assert_eq!(super::to_markdown_with(":fire_ball: :fire_ball:", &none, &known), "[:fire_ball:](emoji-big:https://b.example/f.png) [:fire_ball:](emoji-big:https://b.example/f.png)");
        assert_eq!(super::to_markdown_with("a :nope: b `:fire_ball:`", &none, &known), "a :nope: b `:fire_ball:`");
        assert!(super::emoji_only("😀 🔥", &none));
        assert!(super::emoji_only("👍🏽", &none));
        assert!(!super::emoji_only("hi 😀", &none));
        assert!(!super::emoji_only("😀😀😀😀😀😀😀😀😀😀😀", &none), "more than ten");
    }

    fn to_markdown(s: &str) -> String {
        md(s, &|w: &str| (w == "tac").then(|| "abc".to_owned()))
    }

    #[test]
    fn finds_invite_links() {
        use inferno_core::nostr_sdk::prelude::Keys;
        let author = Keys::generate().public_key();
        let link = inferno_core::server::invite_link::encode("inferno-Ab3dE6gH9jK1", "XyZ9", &author, &[]).unwrap();
        let body = format!("join us! {link} see you");
        assert_eq!(super::invite_link(&body).as_deref(), Some(link.as_str()));
        let bare = link.strip_prefix("nostr:").unwrap();
        assert_eq!(super::invite_link(&format!("({bare})")).as_deref(), Some(bare));
        assert_eq!(super::invite_link("naddr1junk and nothing else"), None);
    }

    #[test]
    fn hard_wraps_but_not_inside_code() {
        assert_eq!(to_markdown("a\nb"), "a\\\nb");
        assert_eq!(to_markdown("a\n\nb"), "a\n\nb");
        assert_eq!(to_markdown("```\nx\ny\n```"), "```\nx\ny\n```");
    }

    #[test]
    fn media_links() {
        use super::is_media;
        assert!(is_media("https://x.example/cat.PNG?w=2"));
        assert!(is_media("https://media.tenor.com/abc/tenor.gif"));
        assert!(is_media(&format!("https://blossom.example/{}", "a".repeat(64))));
        assert!(!is_media("https://example.com/page"));
        assert!(!is_media("ftp://x/cat.png"));
    }

    #[test]
    fn autolinks_and_mentions() {
        assert_eq!(to_markdown("see https://a.b/c."), "see <https://a.b/c>.");
        assert_eq!(to_markdown("[x](https://a.b)"), "[x](https://a.b)");
        assert_eq!(to_markdown("hi @tac!"), "hi [@tac](mention:abc)!");
        assert_eq!(to_markdown("@nobody"), "@nobody", "only real members");
        assert_eq!(md("@here", &plain), "[@here](mention:everyone)");
        assert_eq!(to_markdown("`@tac https://x.y`"), "`@tac https://x.y`");
        assert_eq!(to_markdown("mail me@host"), "mail me@host");
    }
}
