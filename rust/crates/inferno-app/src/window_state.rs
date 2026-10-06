//! Remembers where the window was: size, position and maximized state are
//! saved whenever they change and restored at the next launch, so the app
//! comes back on whichever monitor it was left on. `INFERNO_WINDOW_POS=x,y`
//! overrides the position (handy for scripted runs).

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct WindowState {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub maximized: bool,
}

impl Default for WindowState {
    fn default() -> Self {
        Self { x: 100.0, y: 100.0, width: 1400.0, height: 860.0, maximized: false }
    }
}

fn path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(base.join("inferno").join("window.json"))
}

fn parse_pos(s: &str) -> Option<(f64, f64)> {
    let (x, y) = s.split_once(',')?;
    Some((x.trim().parse().ok()?, y.trim().parse().ok()?))
}

pub fn load() -> WindowState {
    let mut state: WindowState = path()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    if let Some((x, y)) = std::env::var("INFERNO_WINDOW_POS").ok().as_deref().and_then(parse_pos) {
        state.x = x;
        state.y = y;
    }
    state
}

pub fn save(state: &WindowState) {
    let Some(p) = path() else { return };
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(json) = serde_json::to_string(state) {
        let _ = std::fs::write(p, json);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_position_override() {
        assert_eq!(parse_pos("1900, 250"), Some((1900.0, 250.0)));
        assert_eq!(parse_pos("nope"), None);
    }

    #[test]
    fn round_trips_through_the_config_dir() {
        let dir = std::env::temp_dir().join(format!("inferno-ws-{}", std::process::id()));
        // SAFETY: test-only; no other thread in this test reads the env.
        unsafe { std::env::set_var("XDG_CONFIG_HOME", &dir) };
        let s = WindowState { x: 1900.0, y: 250.0, width: 1200.0, height: 800.0, maximized: true };
        save(&s);
        assert_eq!(load(), s);
        let _ = std::fs::remove_dir_all(dir);
    }
}
