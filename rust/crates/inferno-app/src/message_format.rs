//! Message bodies as Rails renders them (`Message#render_content_html`):
//! Redcarpet markdown with hard line breaks, bare URLs autolinked, fenced
//! code and strikethrough, then mentions styled. The timeline draws with
//! Makepad's Markdown widget (CommonMark), so this rewrites the text into
//! the CommonMark that renders the same way.

/// Mentions become links to `mention:<name>`, drawn in the link colour.
pub const MENTION_SCHEME: &str = "mention:";

pub fn to_markdown(body: &str) -> String {
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
            out.push_str(&inline(line));
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
fn inline(line: &str) -> String {
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
                if len == 0 {
                    out.push_str(w);
                } else {
                    out.push_str(&format!("[@{}]({MENTION_SCHEME}{})", &name[..len], &name[..len]));
                    out.push_str(&name[len..]);
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
    use super::to_markdown;

    #[test]
    fn hard_wraps_but_not_inside_code() {
        assert_eq!(to_markdown("a\nb"), "a\\\nb");
        assert_eq!(to_markdown("a\n\nb"), "a\n\nb");
        assert_eq!(to_markdown("```\nx\ny\n```"), "```\nx\ny\n```");
    }

    #[test]
    fn autolinks_and_mentions() {
        assert_eq!(to_markdown("see https://a.b/c."), "see <https://a.b/c>.");
        assert_eq!(to_markdown("[x](https://a.b)"), "[x](https://a.b)");
        assert_eq!(to_markdown("hi @tac!"), "hi [@tac](mention:tac)!");
        assert_eq!(to_markdown("`@tac https://x.y`"), "`@tac https://x.y`");
        assert_eq!(to_markdown("mail me@host"), "mail me@host");
    }
}
