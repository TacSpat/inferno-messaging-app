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
            out.push_str(&inline(line, resolve));
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
fn inline(line: &str, resolve: Resolve) -> String {
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
                out.push_str(w);
            }
            if words.peek().is_some() {
                out.push(' ');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::{plain, to_markdown as md};

    fn to_markdown(s: &str) -> String {
        md(s, &|w: &str| (w == "tac").then(|| "abc".to_owned()))
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
