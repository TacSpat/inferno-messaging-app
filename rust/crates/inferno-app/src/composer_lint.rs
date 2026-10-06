//! The composer's live formatting, ported from Rails'
//! `message_form_controller#updateHighlight`: links and mentions in
//! accent-light, `**bold**` and `*italic*` in white, `~~strike~~` in gray,
//! `` `code` `` in accent, and fenced code blocks with the same per-language
//! keyword colours. The markup stays in the text, as in Rails; only colours
//! change, so the caret never moves.

use std::ops::Range;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Link,
    Mention,
    Bold,
    Italic,
    /// `***both***`.
    BoldItalic,
    Strike,
    Code,
    Fence,
    Comment,
    Str,
    Number,
    Keyword,
}

impl Kind {
    /// Fixed colours from Rails (code blocks use One Dark's), or a theme
    /// token for the rest.
    pub fn color(self) -> Result<u32, &'static str> {
        match self {
            Kind::Link | Kind::Mention => Err("accent_light"),
            Kind::Code => Err("accent"),
            Kind::Bold | Kind::Italic | Kind::BoldItalic => Ok(0xffffff),
            Kind::Strike => Err("gray_400"),
            Kind::Fence => Ok(0x7c8899),
            Kind::Comment => Ok(0x6a737d),
            Kind::Str => Ok(0x98c379),
            Kind::Number => Ok(0xd19a66),
            Kind::Keyword => Ok(0xc678dd),
        }
    }
}

pub type Span = (Range<usize>, Kind);

/// Coloured ranges (byte offsets), in no particular order; they don't
/// overlap.
pub fn spans(text: &str) -> Vec<Span> {
    let mut out = Vec::new();
    let mut plain_from = 0;
    let mut i = 0;
    while let Some(off) = text[i..].find("```") {
        let start = i + off;
        inline(text, plain_from..start, &mut out);
        let after = start + 3;
        let close = text[after..].find("```").map(|c| after + c);
        let end = close.map_or(text.len(), |c| c + 3);
        code_block(text, start, close, end, &mut out);
        i = end;
        plain_from = end;
        if close.is_none() {
            break;
        }
    }
    inline(text, plain_from..text.len(), &mut out);
    out
}

fn is_word(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// Links, mentions, bold, italic, strike and inline code in `range`.
fn inline(text: &str, range: Range<usize>, out: &mut Vec<Span>) {
    let s = &text[range.clone()];
    let base = range.start;
    let mut taken: Vec<Range<usize>> = Vec::new();
    let free = |taken: &[Range<usize>], r: &Range<usize>| taken.iter().all(|t| t.end <= r.start || t.start >= r.end);
    let push = |out: &mut Vec<Span>, taken: &mut Vec<Range<usize>>, r: Range<usize>, k: Kind| {
        if free(taken, &r) {
            taken.push(r.clone());
            out.push((base + r.start..base + r.end, k));
        }
    };
    // Inline code first: nothing inside it is formatting.
    let mut i = 0;
    while let Some(o) = s[i..].find('`') {
        let a = i + o;
        match s[a + 1..].find('`') {
            Some(b) if b > 0 && !s[a + 1..a + 1 + b].contains('\n') => {
                push(out, &mut taken, a..a + 2 + b, Kind::Code);
                i = a + 2 + b;
            }
            _ => i = a + 1,
        }
    }
    // Links: http(s):// and nostr: URIs up to whitespace.
    for prefix in ["https://", "http://", "nostr:"] {
        let mut i = 0;
        while let Some(o) = s[i..].find(prefix) {
            let a = i + o;
            let end = s[a..].find(char::is_whitespace).map_or(s.len(), |e| a + e);
            if end > a + prefix.len() {
                push(out, &mut taken, a..end, Kind::Link);
            }
            i = end.max(a + 1);
        }
    }
    // @mentions at the start or after whitespace.
    for (a, _) in s.match_indices('@') {
        if a > 0 && !s[..a].ends_with(char::is_whitespace) {
            continue;
        }
        let len: usize = s[a + 1..].chars().take_while(|c| is_word(*c)).map(char::len_utf8).sum();
        if len > 0 {
            push(out, &mut taken, a..a + 1 + len, Kind::Mention);
        }
    }
    // Paired markers, on one line: ***both***, **bold**, ~~strike~~, then
    // *italic* (Rails' highlight shows bold and italic in their faces).
    for (marker, kind) in [("***", Kind::BoldItalic), ("**", Kind::Bold), ("~~", Kind::Strike), ("*", Kind::Italic)] {
        let mut i = 0;
        while let Some(o) = s[i..].find(marker) {
            let a = i + o;
            // A marker that is part of a longer run of stars belongs to it.
            let stars = marker.starts_with('*');
            if stars && (s[a + marker.len()..].starts_with('*') || s[..a].ends_with('*')) {
                i = a + 1;
                continue;
            }
            let inner = a + marker.len();
            let close = s[inner..]
                .match_indices(marker)
                .map(|(c, _)| inner + c)
                .find(|&c| !stars || !(s[c + marker.len()..].starts_with('*') || s[..c].ends_with('*')));
            match close {
                Some(c) if c > inner && !s[inner..c].contains('\n') => {
                    push(out, &mut taken, a..c + marker.len(), kind);
                    i = c + marker.len();
                }
                _ => i = inner,
            }
        }
    }
}

fn keywords(lang: &str) -> &'static [&'static str] {
    const JS: &[&str] = &[
        "const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "break",
        "continue", "new", "this", "class", "extends", "import", "export", "from", "default", "async", "await", "try",
        "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "yield", "delete", "void", "super", "static",
        "get", "set",
    ];
    const RB: &[&str] = &[
        "def", "end", "class", "module", "do", "if", "else", "elsif", "unless", "while", "until", "for", "in", "return",
        "yield", "begin", "rescue", "ensure", "raise", "require", "require_relative", "include", "extend", "attr_reader",
        "attr_writer", "attr_accessor", "self", "super", "then", "when", "case", "nil", "puts", "print", "lambda", "proc",
    ];
    const PY: &[&str] = &[
        "def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "try", "except", "finally",
        "raise", "with", "yield", "lambda", "pass", "break", "continue", "and", "or", "not", "in", "is", "global",
        "nonlocal", "assert", "del", "print", "self", "async", "await",
    ];
    const GO: &[&str] = &[
        "func", "return", "if", "else", "for", "range", "switch", "case", "break", "continue", "go", "defer", "select",
        "chan", "map", "struct", "interface", "type", "package", "import", "var", "const", "nil", "make", "len",
        "append", "cap", "copy", "delete", "new", "panic", "recover", "fallthrough",
    ];
    const RUST: &[&str] = &[
        "fn", "let", "mut", "if", "else", "for", "while", "loop", "match", "return", "struct", "enum", "impl", "trait",
        "pub", "use", "mod", "crate", "super", "self", "where", "type", "const", "static", "ref", "move", "async",
        "await", "unsafe", "extern", "dyn", "as", "in", "break", "continue", "Some", "None", "Ok", "Err",
    ];
    const SH: &[&str] = &[
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "return", "exit",
        "echo", "export", "source", "local", "readonly", "unset", "shift", "eval", "exec", "trap", "cd", "pwd", "test",
    ];
    match lang {
        "ruby" | "rb" => RB,
        "python" | "py" => PY,
        "go" | "golang" => GO,
        "rust" | "rs" => RUST,
        "sh" | "bash" | "shell" | "zsh" => SH,
        "html" | "erb" | "xml" | "json" => &[],
        _ => JS,
    }
}

fn hash_comments(lang: &str) -> bool {
    matches!(lang, "ruby" | "rb" | "python" | "py" | "sh" | "bash" | "shell" | "yml" | "yaml")
}

/// A fenced block from `start` (its opening ```) to `end`; `close` is the
/// closing fence, if typed yet.
fn code_block(text: &str, start: usize, close: Option<usize>, end: usize, out: &mut Vec<Span>) {
    let first_nl = text[start..end].find('\n').map(|n| start + n);
    let Some(nl) = first_nl else {
        out.push((start..end, Kind::Fence));
        return;
    };
    out.push((start..nl, Kind::Fence));
    let lang = text[start + 3..nl].trim().to_lowercase();
    let body_end = close.unwrap_or(end);
    if let Some(c) = close {
        out.push((c..end, Kind::Fence));
    }
    let body = &text[nl + 1..body_end];
    let base = nl + 1;
    let kws = keywords(&lang);
    let mut i = 0;
    while i < body.len() {
        let rest = &body[i..];
        let ch = rest.chars().next().unwrap_or(' ');
        // Only ASCII starts strings, comments and numbers; anything else is
        // a word character or skipped, a whole character at a time.
        let c = if ch.is_ascii() { ch as u8 } else { 0 };
        if rest.starts_with("//") || (c == b'#' && hash_comments(&lang)) {
            let e = rest.find('\n').map_or(body.len(), |n| i + n);
            out.push((base + i..base + e, Kind::Comment));
            i = e;
        } else if c == b'"' || c == b'\'' || c == b'`' {
            let e = body[i + 1..]
                .char_indices()
                .scan(false, |esc, (k, ch)| {
                    let hit = !*esc && ch as u32 == c as u32;
                    *esc = !*esc && ch == '\\';
                    Some((k, hit))
                })
                .find(|(_, hit)| *hit)
                .map_or(body.len(), |(k, _)| i + 1 + k + 1);
            out.push((base + i..base + e, Kind::Str));
            i = e;
        } else if c.is_ascii_digit() && (i == 0 || !is_word(body[..i].chars().last().unwrap_or(' '))) {
            let e = body[i..].find(|ch: char| !(ch.is_ascii_digit() || ch == '.')).map_or(body.len(), |n| i + n);
            out.push((base + i..base + e, Kind::Number));
            i = e;
        } else if is_word(ch) && (i == 0 || !is_word(body[..i].chars().last().unwrap_or(' '))) {
            let e = body[i..].find(|ch: char| !is_word(ch)).map_or(body.len(), |n| i + n);
            let word = &body[i..e];
            if kws.contains(&word) {
                out.push((base + i..base + e, Kind::Keyword));
            } else if matches!(word, "true" | "false" | "null" | "nil" | "undefined" | "NaN" | "None" | "True" | "False") {
                out.push((base + i..base + e, Kind::Number));
            }
            i = e;
        } else {
            i += ch.len_utf8();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(text: &str) -> Vec<(&str, Kind)> {
        let mut v: Vec<_> = spans(text).into_iter().map(|(r, k)| (&text[r], k)).collect();
        v.sort_by_key(|(s, _)| text.find(s).unwrap());
        v
    }

    #[test]
    fn inline_markdown() {
        assert_eq!(
            kinds("**hi** *there* ~~old~~ `x*y*` @tac https://a.b/c"),
            vec![
                ("**hi**", Kind::Bold),
                ("*there*", Kind::Italic),
                ("~~old~~", Kind::Strike),
                ("`x*y*`", Kind::Code),
                ("@tac", Kind::Mention),
                ("https://a.b/c", Kind::Link),
            ]
        );
        assert!(kinds("email@host.com").is_empty(), "not a mention mid-word");
        assert!(kinds("**unclosed").is_empty());
        assert_eq!(kinds("***both*** **b**"), vec![("***both***", Kind::BoldItalic), ("**b**", Kind::Bold)]);
    }

    #[test]
    fn code_blocks_are_not_markdown_and_get_syntax_colours() {
        let t = "see ```rust\nlet x = 42; // **no**\n``` done";
        let k = kinds(t);
        assert!(k.contains(&("```rust", Kind::Fence)));
        assert!(k.contains(&("let", Kind::Keyword)));
        assert!(k.contains(&("42", Kind::Number)));
        assert!(k.contains(&("// **no**", Kind::Comment)));
        assert!(!k.iter().any(|(_, kind)| matches!(kind, Kind::Bold | Kind::Italic)));
        // Unclosed blocks run to the end, as Rails shows them while typing.
        let k = kinds("```py\ns = 'hi'");
        assert!(k.contains(&("'hi'", Kind::Str)));
    }

    #[test]
    fn multibyte_text_is_safe() {
        let t = "🔥 **é** ```\n«ü» 1\n```";
        for (r, _) in spans(t) {
            assert!(t.is_char_boundary(r.start) && t.is_char_boundary(r.end));
        }
    }
}
