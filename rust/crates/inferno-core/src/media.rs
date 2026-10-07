//! Files in messages. Rails appends each file's Blossom URL to the message
//! text; we do too, and also describe it in a NIP-92 `imeta` tag (type,
//! name, size, dimensions), since a Blossom URL often has no extension to
//! tell a video from an image.

use nostr::prelude::*;

#[derive(Debug, Clone, PartialEq, Default)]
pub struct FileMeta {
    pub url: String,
    /// MIME type, e.g. image/png; empty if unknown.
    pub mime: String,
    pub name: String,
    pub size: Option<u64>,
    pub dim: Option<(u32, u32)>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaKind {
    Image,
    Video,
    Audio,
    File,
}

impl FileMeta {
    pub fn kind(&self) -> MediaKind {
        kind_of(&self.url, &self.mime)
    }

    /// `["imeta", "url …", "m …", …]`
    pub fn tag(&self) -> Tag {
        let mut row = vec!["imeta".to_owned(), format!("url {}", self.url)];
        if !self.mime.is_empty() {
            row.push(format!("m {}", self.mime));
        }
        if !self.name.is_empty() {
            row.push(format!("alt {}", self.name));
        }
        if let Some(s) = self.size {
            row.push(format!("size {s}"));
        }
        if let Some((w, h)) = self.dim {
            row.push(format!("dim {w}x{h}"));
        }
        Tag::parse(row).expect("imeta tag")
    }
}

/// The `imeta` tags of an event (NIP-92).
pub fn files(event: &Event) -> Vec<FileMeta> {
    event
        .tags
        .iter()
        .map(|t| t.as_slice())
        .filter(|s| s.first().map(String::as_str) == Some("imeta"))
        .filter_map(|s| {
            let mut f = FileMeta::default();
            for part in &s[1..] {
                let (k, v) = part.split_once(' ')?;
                match k {
                    "url" => f.url = v.to_owned(),
                    "m" => f.mime = v.to_owned(),
                    "alt" | "name" if f.name.is_empty() => f.name = v.to_owned(),
                    "size" => f.size = v.parse().ok(),
                    "dim" => f.dim = v.split_once('x').and_then(|(w, h)| Some((w.parse().ok()?, h.parse().ok()?))),
                    _ => {}
                }
            }
            (!f.url.is_empty()).then_some(f)
        })
        .collect()
}

/// What a file is, from its MIME type or else its extension.
pub fn kind_of(url: &str, mime: &str) -> MediaKind {
    let major = mime.split('/').next().unwrap_or("");
    match major {
        "image" => return MediaKind::Image,
        "video" => return MediaKind::Video,
        "audio" => return MediaKind::Audio,
        "" => {}
        _ => return MediaKind::File,
    }
    let path = url.split(['?', '#']).next().unwrap_or(url).to_lowercase();
    let ext = path.rsplit('/').next().and_then(|f| f.rsplit_once('.')).map(|(_, e)| e).unwrap_or("");
    match ext {
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "avif" => MediaKind::Image,
        "mp4" | "webm" | "mov" | "mkv" | "m4v" | "ogv" => MediaKind::Video,
        "mp3" | "ogg" | "oga" | "wav" | "flac" | "m4a" | "opus" | "aac" => MediaKind::Audio,
        _ => MediaKind::File,
    }
}

/// The MIME type for a file name (what we tell others we're sending).
pub fn mime_for(name: &str) -> &'static str {
    let ext = name.rsplit_once('.').map(|(_, e)| e.to_lowercase()).unwrap_or_default();
    match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "bmp" => "image/bmp",
        "avif" => "image/avif",
        "mp4" | "m4v" => "video/mp4",
        "webm" => "video/webm",
        "mov" => "video/quicktime",
        "mkv" => "video/x-matroska",
        "mp3" => "audio/mpeg",
        "ogg" | "oga" | "opus" => "audio/ogg",
        "wav" => "audio/wav",
        "flac" => "audio/flac",
        "m4a" => "audio/mp4",
        "pdf" => "application/pdf",
        "txt" | "md" => "text/plain",
        "zip" => "application/zip",
        _ => "application/octet-stream",
    }
}

/// "2.4 MB", as Rails' number_to_human_size.
pub fn human_size(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["Bytes", "KB", "MB", "GB", "TB"];
    let mut v = bytes as f64;
    let mut u = 0;
    while v >= 1024.0 && u + 1 < UNITS.len() {
        v /= 1024.0;
        u += 1;
    }
    if u == 0 { format!("{bytes} Bytes") } else { format!("{:.1} {}", v, UNITS[u]).replace(".0 ", " ") }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn imeta_round_trip_and_kinds() {
        let f = FileMeta {
            url: "https://b.example/abc".into(),
            mime: "video/mp4".into(),
            name: "clip.mp4".into(),
            size: Some(2_500_000),
            dim: Some((1280, 720)),
        };
        let keys = Keys::generate();
        let e = EventBuilder::new(Kind::Custom(9), "x").tags([f.tag()]).finalize(&keys).unwrap();
        assert_eq!(files(&e), vec![f.clone()]);
        assert_eq!(f.kind(), MediaKind::Video);
        assert_eq!(kind_of("https://b.example/x.PNG?w=1", ""), MediaKind::Image);
        assert_eq!(kind_of("https://b.example/sha256", ""), MediaKind::File);
        assert_eq!(kind_of("https://b.example/a.zip", "application/zip"), MediaKind::File);
        assert_eq!(human_size(2_500_000), "2.4 MB");
        assert_eq!(human_size(512), "512 Bytes");
    }
}
