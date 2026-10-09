//! The microphone while we're in voice, and how loud it is: Rails' speaking
//! indicator (voice_channel_controller's level loop). Capture runs only
//! while we're in a voice channel and not muted; muting stops it, so a
//! muted microphone is closed, not just ignored.
//!
//! Rails' numbers: each frame the RMS of the input, smoothed as
//! `prev * 0.35 + level * 0.65`; speaking above 0.03; the glow's strength
//! `sqrt(min((level - 0.03) / 0.20, 1))`.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use makepad_widgets::*;

/// Rails' automatic threshold.
pub const THRESHOLD: f32 = 0.03;

#[derive(Default)]
pub struct Mic {
    /// The latest buffer's RMS, as f32 bits (written on the audio thread).
    raw: Arc<AtomicU32>,
    on: bool,
    installed: bool,
    inputs: Vec<AudioDeviceId>,
    smoothed: f32,
    /// Every device: (id, name, is input, is the default).
    devices: Vec<(AudioDeviceId, String, bool, bool)>,
    /// The microphone chosen in settings, by name.
    chosen: Option<String>,
    /// The device list changed since the UI last looked.
    pub devices_changed: bool,
}

/// Root mean square of `data`.
pub fn rms(data: &[f32]) -> f32 {
    if data.is_empty() {
        return 0.0;
    }
    (data.iter().map(|s| s * s).sum::<f32>() / data.len() as f32).sqrt()
}

/// Rails' speaking test and glow strength: `None` below the threshold.
pub fn speaking(level: f32) -> Option<f32> {
    (level > THRESHOLD).then(|| ((level - THRESHOLD) / 0.20).min(1.0).sqrt())
}

/// `INFERNO_FAKE_MIC=1`: a made-up voice (bursts of talking and quiet)
/// instead of the microphone, so tests never open a real one.
pub(crate) fn fake_level() -> Option<f32> {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    if !*ON.get_or_init(|| std::env::var_os("INFERNO_FAKE_MIC").is_some()) {
        return None;
    }
    let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| (d.as_millis() % 1_000_000) as f32 / 1000.0).unwrap_or(0.0);
    let talking = (t * 0.5).sin() > -0.2;
    Some(if talking { 0.05 + 0.12 * (0.5 + 0.5 * (t * 7.0).sin()) } else { 0.005 })
}

impl Mic {
    pub fn handle_event(&mut self, cx: &mut Cx, event: &Event) {
        if let Event::AudioDevices(devices) = event {
            self.devices = devices
                .descs
                .iter()
                .filter(|d| !matches!(d.device_type, AudioDeviceType::Loopback))
                .map(|d| (d.device_id, d.name.clone(), matches!(d.device_type, AudioDeviceType::Input), d.is_default))
                .collect();
            self.devices_changed = true;
            self.pick(cx, devices.default_input());
        }
    }

    /// Opens or closes the microphone.
    pub fn set_on(&mut self, cx: &mut Cx, on: bool) {
        if on == self.on {
            return;
        }
        self.on = on;
        if fake_level().is_some() {
            return;
        }
        if on {
            if !self.installed {
                self.installed = true;
                let raw = self.raw.clone();
                cx.audio_input(0, move |_info, buffer| {
                    raw.store(rms(&buffer.data).to_bits(), Ordering::Relaxed);
                });
            }
            cx.use_audio_inputs(&self.inputs);
        } else {
            cx.use_audio_inputs(&[]);
            self.raw.store(0f32.to_bits(), Ordering::Relaxed);
        }
    }

    /// Names of the inputs (true) or outputs (false).
    pub fn names(&self, input: bool) -> Vec<String> {
        let mut names: Vec<String> = self.devices.iter().filter(|d| d.2 == input).map(|d| d.1.clone()).collect();
        names.dedup();
        names
    }

    /// Uses the microphone named `name` (`None`: the system default).
    pub fn choose(&mut self, cx: &mut Cx, name: Option<String>) {
        self.chosen = name;
        let defaults: Vec<AudioDeviceId> = self.devices.iter().filter(|d| d.2 && d.3).map(|d| d.0).take(1).collect();
        self.pick(cx, defaults);
    }

    fn pick(&mut self, cx: &mut Cx, defaults: Vec<AudioDeviceId>) {
        let chosen = self.chosen.as_ref().and_then(|n| self.devices.iter().find(|d| d.2 && &d.1 == n)).map(|d| vec![d.0]);
        self.inputs = chosen.unwrap_or(defaults);
        if self.on && fake_level().is_none() {
            cx.use_audio_inputs(&self.inputs);
        }
    }

    /// The smoothed level, read once per frame; decays to 0 when off.
    pub fn sample(&mut self) -> f32 {
        let raw = if !self.on {
            0.0
        } else if let Some(t) = fake_level() {
            t
        } else {
            f32::from_bits(self.raw.load(Ordering::Relaxed))
        };
        self.smoothed = self.smoothed * 0.35 + raw * 0.65;
        if self.smoothed < 1e-4 {
            self.smoothed = 0.0;
        }
        self.smoothed
    }
}

/// Rails' Voice & Video settings, kept on this device (Rails kept device
/// choices in the browser too).
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct VoicePrefs {
    /// Microphone by name; `None` = the system default.
    pub input: Option<String>,
    pub output: Option<String>,
    pub noise_suppression: bool,
    pub echo_cancellation: bool,
    pub auto_gain_control: bool,
    /// Rails' "Voice Activity" or "Push to Talk".
    pub push_to_talk: bool,
    /// Video on the GPU: decoding colour conversion, and H.264 encoding
    /// through VA-API (calls::GPU_VIDEO).
    pub gpu_video: bool,
    /// Per person (pubkey hex): volume in percent (Rails' 0..200) and
    /// whether we've muted them for ourselves. Remembered across calls.
    pub people: std::collections::HashMap<String, PersonAudio>,
    /// The last screen share settings (Rails' picker remembered them).
    pub share: crate::share::ShareSettings,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct PersonAudio {
    pub volume: u32,
    pub muted: bool,
    /// Their stream's sound, apart from their voice.
    pub stream_volume: u32,
    pub stream_muted: bool,
}

impl Default for PersonAudio {
    fn default() -> Self {
        Self { volume: 100, muted: false, stream_volume: 100, stream_muted: false }
    }
}

impl Default for VoicePrefs {
    fn default() -> Self {
        Self { input: None, output: None, noise_suppression: true, echo_cancellation: true, auto_gain_control: true, push_to_talk: false, gpu_video: true, people: Default::default(), share: Default::default() }
    }
}

impl VoicePrefs {
    pub fn load() -> Self {
        crate::picker::file("voice")
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) {
        if let (Some(p), Ok(json)) = (crate::picker::file("voice"), serde_json::to_vec_pretty(self)) {
            if let Some(dir) = p.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let _ = std::fs::write(p, json);
        }
    }

    /// For the call: by LiveKit identity (a pubkey's first 12 hex digits).
    pub fn call_people(&self) -> crate::calls::People {
        self.people
            .iter()
            .filter(|(_, p)| **p != PersonAudio::default())
            .map(|(pk, p)| {
                let hearing = crate::calls::Hearing { volume: p.volume as f32 / 100.0, muted: p.muted, stream_volume: p.stream_volume as f32 / 100.0, stream_muted: p.stream_muted };
                (pk.chars().take(12).collect(), hearing)
            })
            .collect()
    }

    pub fn person(&self, pubkey: &str) -> PersonAudio {
        self.people.get(pubkey).cloned().unwrap_or_default()
    }

    pub fn processing(&self) -> crate::calls::Processing {
        crate::calls::Processing {
            echo_cancellation: self.echo_cancellation,
            noise_suppression: self.noise_suppression,
            auto_gain_control: self.auto_gain_control,
            input: self.input.clone(),
            output: self.output.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rails_speaking_curve() {
        assert_eq!(speaking(0.02), None);
        assert_eq!(speaking(0.23), Some(1.0));
        let mid = speaking(0.08).unwrap();
        assert!((mid - 0.5).abs() < 1e-3, "{mid}");
        assert!((rms(&[0.5, -0.5]) - 0.5).abs() < 1e-6);
    }
}
