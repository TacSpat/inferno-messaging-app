//! The GIF / Stickers / Emoji panel's content, as Rails' unified picker
//! builds it: Frequently Used, then each server's custom emoji, then the
//! standard set; stickers per server. Rails had ~180 emoji in four groups;
//! this is the full Unicode set in its nine groups, searchable by name and
//! shortcode.

use std::collections::HashSet;

/// One pickable emoji.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Cell {
    Unicode(String),
    /// A server's custom emoji: `:name:` in text, drawn from `url`.
    Custom { name: String, url: String },
}

impl Cell {
    /// What it inserts into text.
    pub fn text(&self) -> String {
        match self {
            Cell::Unicode(s) => s.clone(),
            Cell::Custom { name, .. } => format!(":{name}:"),
        }
    }
}

/// Custom emoji and stickers of one server.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ServerSet {
    pub gid: String,
    pub name: String,
    pub emojis: Vec<(String, String)>,
    pub stickers: Vec<(String, String)>,
}

/// A tile on the GIF tab's home (Rails: 2 across).
#[derive(Debug, Clone, PartialEq)]
pub enum GifTile {
    Favorites(usize),
    Trending,
    Collection { id: String, name: String, count: usize },
    NewCollection,
}

/// Where the GIF tab is.
#[derive(Debug, Clone, PartialEq, Default)]
pub enum GifView {
    #[default]
    Home,
    Favorites,
    Collection(String),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Row {
    Tiles(Vec<GifTile>),
    /// Up to two GIFs, each with whether it's a favorite.
    Gifs(Vec<(inferno_core::gifs::Gif, bool)>),
    /// A collapsible section; `key` persists its state.
    Header { key: String, title: String, collapsed: bool },
    Cells(Vec<Cell>),
    /// Up to three stickers: (name, url).
    Stickers(Vec<(String, String)>),
    Empty(String),
}

pub const PER_ROW: usize = 9;
pub const STICKERS_PER_ROW: usize = 3;
/// Rails keeps 24.
pub const FREQUENT_MAX: usize = 24;

fn group_title(g: emojis::Group) -> &'static str {
    use emojis::Group::*;
    match g {
        SmileysAndEmotion => "Smileys & Emotion",
        PeopleAndBody => "People & Body",
        AnimalsAndNature => "Animals & Nature",
        FoodAndDrink => "Food & Drink",
        TravelAndPlaces => "Travel & Places",
        Activities => "Activities",
        Objects => "Objects",
        Symbols => "Symbols",
        Flags => "Flags",
    }
}

fn chunk<T: Clone>(items: &[T], n: usize) -> Vec<Vec<T>> {
    items.chunks(n).map(|c| c.to_vec()).collect()
}

fn matches_unicode(e: &emojis::Emoji, q: &str) -> bool {
    e.name().contains(q) || e.shortcodes().any(|s| s.contains(q))
}

/// The Emoji tab. `custom` is false when custom emoji aren't allowed here.
pub fn emoji_rows(search: &str, frequent: &[Cell], sets: &[ServerSet], custom: bool, collapsed: &HashSet<String>) -> Vec<Row> {
    let q = search.trim().trim_matches(':').to_lowercase();
    let mut rows = Vec::new();
    let section = |rows: &mut Vec<Row>, key: String, title: String, cells: Vec<Cell>| {
        if cells.is_empty() {
            return;
        }
        let shut = q.is_empty() && collapsed.contains(&key);
        rows.push(Row::Header { key, title, collapsed: shut });
        if !shut {
            rows.extend(chunk(&cells, PER_ROW).into_iter().map(Row::Cells));
        }
    };
    if q.is_empty() {
        let frequent: Vec<Cell> = frequent
            .iter()
            .filter(|c| custom || matches!(c, Cell::Unicode(_)))
            .take(FREQUENT_MAX)
            .cloned()
            .collect();
        section(&mut rows, "frequent".into(), "Frequently Used".into(), frequent);
    }
    if custom {
        for set in sets {
            let cells: Vec<Cell> = set
                .emojis
                .iter()
                .filter(|(n, _)| q.is_empty() || n.to_lowercase().contains(&q))
                .map(|(name, url)| Cell::Custom { name: name.clone(), url: url.clone() })
                .collect();
            section(&mut rows, format!("server:{}", set.gid), set.name.clone(), cells);
        }
    }
    for group in emojis::Group::iter() {
        let cells: Vec<Cell> = group
            .emojis()
            .filter(|e| e.skin_tone().is_none())
            .filter(|e| q.is_empty() || matches_unicode(e, &q))
            .map(|e| Cell::Unicode(e.as_str().to_owned()))
            .collect();
        section(&mut rows, format!("group:{}", group_title(group)), group_title(group).into(), cells);
    }
    if rows.is_empty() {
        rows.push(Row::Empty(format!("No emoji match \"{}\".", search.trim())));
    }
    rows
}

/// The Stickers tab.
pub fn sticker_rows(search: &str, sets: &[ServerSet], collapsed: &HashSet<String>) -> Vec<Row> {
    let q = search.trim().to_lowercase();
    let mut rows = Vec::new();
    for set in sets {
        let stickers: Vec<(String, String)> =
            set.stickers.iter().filter(|(n, _)| q.is_empty() || n.to_lowercase().contains(&q)).cloned().collect();
        if stickers.is_empty() {
            continue;
        }
        let key = format!("stickers:{}", set.gid);
        let shut = q.is_empty() && collapsed.contains(&key);
        rows.push(Row::Header { key, title: set.name.clone(), collapsed: shut });
        if !shut {
            rows.extend(chunk(&stickers, STICKERS_PER_ROW).into_iter().map(Row::Stickers));
        }
    }
    if rows.is_empty() {
        rows.push(Row::Empty(if q.is_empty() { "No stickers yet".into() } else { "No stickers available".into() }));
    }
    rows
}

/// The GIF tab. Search needs a GIF service (Tenor), which isn't set up, so
/// searching says so; favorites and collections work without one.
pub fn gif_rows(
    view: &GifView,
    search: &str,
    favorites: &[inferno_core::gifs::Gif],
    collections: &[inferno_core::gifs::Collection],
) -> Vec<Row> {
    let fav: HashSet<&str> = favorites.iter().map(|g| g.url.as_str()).collect();
    let grid = |gifs: &[inferno_core::gifs::Gif]| -> Vec<Row> {
        gifs.chunks(2)
            .map(|c| Row::Gifs(c.iter().map(|g| (g.clone(), fav.contains(g.url.as_str()))).collect()))
            .collect()
    };
    if !search.trim().is_empty() {
        return vec![Row::Empty("GIF search needs a Tenor API key, which isn't set up yet. Favorites and collections work without it.".into())];
    }
    match view {
        GifView::Home => {
            let mut tiles = vec![GifTile::Favorites(favorites.len()), GifTile::Trending];
            tiles.extend(collections.iter().map(|c| GifTile::Collection { id: c.id.clone(), name: c.name.clone(), count: c.gifs.len() }));
            tiles.push(GifTile::NewCollection);
            chunk(&tiles, 2).into_iter().map(Row::Tiles).collect()
        }
        GifView::Favorites if favorites.is_empty() => {
            vec![Row::Empty("No favorites yet. Paste a GIF link above, or press 🔥 on a GIF in chat.".into())]
        }
        GifView::Favorites => grid(favorites),
        GifView::Collection(id) => match collections.iter().find(|c| c.id == *id) {
            Some(c) if c.gifs.is_empty() => vec![Row::Empty("Nothing here yet. Right-click a GIF to add it to this collection.".into())],
            Some(c) => grid(&c.gifs),
            None => vec![Row::Empty("That collection is gone.".into())],
        },
    }
}

/// Moves `cell` to the front of the frequently used list (Rails' order).
pub fn record_use(frequent: &mut Vec<Cell>, cell: Cell) {
    frequent.retain(|c| *c != cell);
    frequent.insert(0, cell);
    frequent.truncate(FREQUENT_MAX);
}

// ─── Saved on this device, like Rails' localStorage ─────────────────────

fn file(name: &str) -> Option<std::path::PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(".config")))?;
    let profile = std::env::var("INFERNO_PROFILE").ok().filter(|p| !p.is_empty()).map(|p| format!("-{p}")).unwrap_or_default();
    Some(base.join("inferno").join(format!("{name}{profile}.json")))
}

#[derive(serde::Serialize, serde::Deserialize, Default)]
struct Saved {
    #[serde(default)]
    frequent: Vec<String>,
    #[serde(default)]
    collapsed: Vec<String>,
    #[serde(default)]
    last_tab: usize,
}

/// (frequently used, collapsed sections, last tab).
pub fn load() -> (Vec<Cell>, HashSet<String>, usize) {
    let saved: Saved = file("picker")
        .and_then(|p| std::fs::read(p).ok())
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default();
    let frequent = saved
        .frequent
        .into_iter()
        .map(|s| match s.split_once('\u{1f}') {
            Some((name, url)) => Cell::Custom { name: name.into(), url: url.into() },
            None => Cell::Unicode(s),
        })
        .collect();
    (frequent, saved.collapsed.into_iter().collect(), saved.last_tab)
}

pub fn save(frequent: &[Cell], collapsed: &HashSet<String>, last_tab: usize) {
    let saved = Saved {
        frequent: frequent
            .iter()
            .map(|c| match c {
                Cell::Unicode(s) => s.clone(),
                Cell::Custom { name, url } => format!("{name}\u{1f}{url}"),
            })
            .collect(),
        collapsed: collapsed.iter().cloned().collect(),
        last_tab,
    };
    if let (Some(p), Ok(json)) = (file("picker"), serde_json::to_vec(&saved)) {
        let _ = std::fs::create_dir_all(p.parent().unwrap_or(std::path::Path::new(".")));
        let _ = std::fs::write(p, json);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set() -> ServerSet {
        ServerSet {
            gid: "g".into(),
            name: "Spike".into(),
            emojis: vec![("blaze".into(), "https://x/b.png".into())],
            stickers: vec![("wave".into(), "https://x/w.png".into()), ("nod".into(), "https://x/n.png".into())],
        }
    }

    #[test]
    fn sections_in_rails_order() {
        let rows = emoji_rows("", &[Cell::Unicode("🔥".into())], &[set()], true, &HashSet::new());
        let titles: Vec<&str> = rows
            .iter()
            .filter_map(|r| if let Row::Header { title, .. } = r { Some(title.as_str()) } else { None })
            .collect();
        assert_eq!(&titles[..3], ["Frequently Used", "Spike", "Smileys & Emotion"]);
        assert_eq!(titles.len(), 2 + 9);
        assert!(rows.iter().all(|r| !matches!(r, Row::Cells(c) if c.len() > PER_ROW)));
    }

    #[test]
    fn search_finds_names_shortcodes_and_custom() {
        let rows = emoji_rows("fire", &[], &[set()], true, &HashSet::new());
        assert!(rows.iter().any(|r| matches!(r, Row::Cells(c) if c.contains(&Cell::Unicode("🔥".into())))));
        let rows = emoji_rows(":blaze:", &[], &[set()], true, &HashSet::new());
        assert!(rows.iter().any(|r| matches!(r, Row::Cells(c) if c.iter().any(|x| matches!(x, Cell::Custom { name, .. } if name == "blaze")))));
        let rows = emoji_rows("blaze", &[], &[set()], false, &HashSet::new());
        assert!(matches!(&rows[0], Row::Empty(_)), "custom emoji hidden without the permission");
    }

    #[test]
    fn gif_home_and_grids() {
        use inferno_core::gifs::{Collection, Gif};
        let g = |u: &str| Gif { url: u.into(), preview: u.into() };
        let favs = vec![g("a"), g("b"), g("c")];
        let cols = vec![Collection { id: "1".into(), name: "Lol".into(), gifs: vec![g("a")] }];
        let home = gif_rows(&GifView::Home, "", &favs, &cols);
        assert_eq!(home[0], Row::Tiles(vec![GifTile::Favorites(3), GifTile::Trending]));
        assert!(matches!(&home[1], Row::Tiles(t) if t.len() == 2 && t[1] == GifTile::NewCollection));
        let fav_rows = gif_rows(&GifView::Favorites, "", &favs, &cols);
        assert_eq!(fav_rows.len(), 2);
        assert!(matches!(&gif_rows(&GifView::Collection("1".into()), "", &favs, &cols)[0], Row::Gifs(v) if v[0].1));
        assert!(matches!(&gif_rows(&GifView::Home, "cats", &favs, &cols)[0], Row::Empty(_)));
    }

    #[test]
    fn collapsed_sections_and_frequent_order() {
        let collapsed: HashSet<String> = ["group:Flags".to_owned()].into();
        let rows = emoji_rows("", &[], &[], true, &collapsed);
        let last = rows.last().unwrap();
        assert!(matches!(last, Row::Header { collapsed: true, .. }));
        let mut f = vec![Cell::Unicode("a".into()), Cell::Unicode("b".into())];
        record_use(&mut f, Cell::Unicode("b".into()));
        assert_eq!(f[0], Cell::Unicode("b".into()));
        assert_eq!(sticker_rows("", &[set()], &HashSet::new()).len(), 2);
    }
}
