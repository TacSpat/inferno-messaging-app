//! The seven Rails themes (`application.tailwind.css`), token for token.
//! Flutter reused these names with different values; these are the Rails
//! ones, which the spec says to follow.

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rgb(pub u32);

impl Rgb {
    /// Linear 0..1 RGBA for shaders.
    pub fn vec4(self, alpha: f32) -> [f32; 4] {
        let c = self.0;
        [((c >> 16) & 0xff) as f32 / 255.0, ((c >> 8) & 0xff) as f32 / 255.0, (c & 0xff) as f32 / 255.0, alpha]
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Theme {
    pub name: &'static str,
    pub gray_950: Rgb,
    pub gray_900: Rgb,
    pub gray_800: Rgb,
    pub gray_700: Rgb,
    pub gray_600: Rgb,
    pub gray_500: Rgb,
    pub gray_400: Rgb,
    pub gray_300: Rgb,
    pub gray_200: Rgb,
    pub gray_100: Rgb,
    pub accent: Rgb,
    pub accent_light: Rgb,
    pub accent_dark: Rgb,
    pub confirm: Rgb,
    pub danger: Rgb,
    /// Obsidian turns off pulse, flare and glow animations.
    pub animated_glow: bool,
}

/// Same in every theme.
pub const SUCCESS: Rgb = Rgb(0x16a34a);
pub const WARNING: Rgb = Rgb(0xeab308);
pub const WARNING_LIGHT: Rgb = Rgb(0xfacc15);
pub const ONLINE: Rgb = Rgb(0x22c55e);
pub const DND: Rgb = Rgb(0xef4444);
/// Avatar fill when a user has no image and no profile color.
pub const DEFAULT_PROFILE: Rgb = Rgb(0x1e1c1b);

macro_rules! theme {
    ($name:literal, [$g950:literal $g900:literal $g800:literal $g700:literal $g600:literal $g500:literal
      $g400:literal $g300:literal $g200:literal $g100:literal], $acc:literal $accl:literal $accd:literal
      $conf:literal $dang:literal, $anim:literal) => {
        Theme {
            name: $name,
            gray_950: Rgb($g950), gray_900: Rgb($g900), gray_800: Rgb($g800), gray_700: Rgb($g700),
            gray_600: Rgb($g600), gray_500: Rgb($g500), gray_400: Rgb($g400), gray_300: Rgb($g300),
            gray_200: Rgb($g200), gray_100: Rgb($g100),
            accent: Rgb($acc), accent_light: Rgb($accl), accent_dark: Rgb($accd),
            confirm: Rgb($conf), danger: Rgb($dang), animated_glow: $anim,
        }
    };
}

pub const THEMES: [Theme; 7] = [
    theme!("inferno", [0x0a0a09 0x141312 0x1e1c1b 0x2c2a29 0x403e3c 0x656361 0x878583 0xa8a7a5 0xcccbca 0xe1e0df],
        0xdc2626 0xf87171 0xb91c1c 0xea580c 0xdc2626, true),
    theme!("frostfire", [0x080f1a 0x0f1b2d 0x1a2a3a 0x243b53 0x3d5a80 0x627d98 0x829ab1 0x9fb3c8 0xbcccdc 0xd9e2ec],
        0x3b82f6 0x93c5fd 0x1d4ed8 0x2563eb 0xef4444, true),
    theme!("boron", [0x070f0a 0x0f1f15 0x1a261c 0x253328 0x3a5040 0x577057 0x748c74 0x93ad93 0xb8cfb8 0xd6e4d6],
        0x10b981 0x6ee7b7 0x059669 0x059669 0xef4444, true),
    theme!("brimstone", [0x0d0814 0x1a1025 0x241a38 0x352750 0x4d3a6a 0x705a8a 0x9078ab 0xad93c8 0xccb8e0 0xe4d9f0],
        0xa855f7 0xd8b4fe 0x7e22ce 0x7c3aed 0xef4444, true),
    theme!("plasma", [0x0e0710 0x1c0f1c 0x2b1828 0x3d2438 0x5c3a52 0x7d5570 0x9b7089 0xb8899e 0xdbb4d0 0xf0d4e8],
        0xec4899 0xf9a8d4 0xdb2777 0xdb2777 0xef4444, true),
    theme!("pulsar", [0x110c12 0x1e141e 0x2c1e2a 0x3e2a3c 0x5a3e54 0x806078 0xa07d94 0xc09cb2 0xe0c4d4 0xf2dfe9],
        0xf9a8d4 0xfccfe8 0xf472b6 0xf472b6 0xef4444, true),
    theme!("obsidian", [0x0a0f1a 0x111827 0x1a2332 0x1e293b 0x334155 0x475569 0x64748b 0x94a3b8 0xcbd5e1 0xe2e8f0],
        0x94a3b8 0xcbd5e1 0x64748b 0x3b82f6 0xef4444, false),
];

pub fn by_name(name: &str) -> Option<&'static Theme> {
    THEMES.iter().find(|t| t.name == name)
}

// ─── The theme in use ────────────────────────────────────────────────────

use std::sync::atomic::{AtomicUsize, Ordering};

static CURRENT: AtomicUsize = AtomicUsize::new(usize::MAX);

fn ui_file() -> Option<std::path::PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(".config")))?;
    let name = match std::env::var("INFERNO_PROFILE") {
        Ok(p) if !p.is_empty() => format!("theme-{p}"),
        _ => "theme".to_owned(),
    };
    Some(base.join("inferno").join(name))
}

/// The theme the UI is drawn with. Starts from the last one picked on this
/// device (so the first frame is right), then follows the synced setting.
pub fn current() -> &'static Theme {
    let mut i = CURRENT.load(Ordering::Relaxed);
    if i == usize::MAX {
        let saved = ui_file().and_then(|p| std::fs::read_to_string(p).ok()).unwrap_or_default();
        i = THEMES.iter().position(|t| t.name == saved.trim()).unwrap_or(0);
        CURRENT.store(i, Ordering::Relaxed);
    }
    &THEMES[i.min(THEMES.len() - 1)]
}

/// Picks a theme by name; false if unknown or unchanged. The caller then
/// requests a style reload so the DSL re-reads the tokens.
pub fn set_current(name: &str) -> bool {
    let Some(i) = THEMES.iter().position(|t| t.name == name) else { return false };
    if CURRENT.swap(i, Ordering::Relaxed) == i {
        return false;
    }
    if let Some(p) = ui_file() {
        let _ = std::fs::create_dir_all(p.parent().unwrap_or(std::path::Path::new(".")));
        let _ = std::fs::write(p, name);
    }
    true
}

impl Theme {
    pub fn token(&self, name: &str) -> Rgb {
        match name {
            "gray_950" => self.gray_950,
            "gray_900" => self.gray_900,
            "gray_800" => self.gray_800,
            "gray_700" => self.gray_700,
            "gray_600" => self.gray_600,
            "gray_500" => self.gray_500,
            "gray_400" => self.gray_400,
            "gray_300" => self.gray_300,
            "gray_200" => self.gray_200,
            "gray_100" => self.gray_100,
            "accent" => self.accent,
            "accent_light" => self.accent_light,
            "accent_dark" => self.accent_dark,
            "confirm" => self.confirm,
            "danger" => self.danger,
            other => panic!("unknown theme token {other}"),
        }
    }
}

/// A token of the current theme at `alpha`, for the DSL.
pub fn tok(name: &str, alpha: f32) -> makepad_widgets::Vec4 {
    let [r, g, b, a] = current().token(name).vec4(alpha);
    makepad_widgets::vec4(r, g, b, a)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spot_check_against_the_spec_table() {
        let inferno = by_name("inferno").unwrap();
        assert_eq!(inferno.gray_700, Rgb(0x2c2a29));
        assert_eq!(inferno.accent, Rgb(0xdc2626));
        assert_eq!(by_name("frostfire").unwrap().gray_600, Rgb(0x3d5a80));
        assert_eq!(by_name("pulsar").unwrap().accent, Rgb(0xf9a8d4));
        assert_eq!(by_name("obsidian").unwrap().confirm, Rgb(0x3b82f6));
        assert!(!by_name("obsidian").unwrap().animated_glow);
        assert_eq!(Rgb(0xff0080).vec4(1.0), [1.0, 0.0, 128.0 / 255.0, 1.0]);
    }
}
