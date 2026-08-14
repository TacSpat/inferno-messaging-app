import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'all_themes.dart';
import 'ui_effects.dart';

/// Persisted theme name — loads from secure storage on startup, saves on change
final themeNameProvider = StateNotifierProvider<ThemeNameNotifier, String>((ref) {
  return ThemeNameNotifier();
});

class ThemeNameNotifier extends StateNotifier<String> {
  static const _key = 'inferno_theme';
  static const _storage = FlutterSecureStorage();

  ThemeNameNotifier() : super('inferno') {
    _load();
  }

  Future<void> _load() async {
    final saved = await _storage.read(key: _key);
    if (saved != null && InfernoThemes.themeNames.contains(saved)) {
      state = saved;
    }
  }

  void setTheme(String name) {
    if (!InfernoThemes.themeNames.contains(name) || name == state) return;
    state = name;
    _storage.write(key: _key, value: name);
  }
}

// The old themeTransitionProvider gated a full-window black spinner overlay,
// which made the app go black for the length of the rebuild and then pop into
// the new colours. MaterialApp's AnimatedTheme tweens the swap now instead —
// see app.dart.
//
// It also did one thing worth keeping: it debounced the switch, so a click
// during a swap was ignored. That is preserved below, minus the overlay.

/// How long a theme swap animates. Shared so the debounce window and
/// MaterialApp's themeAnimationDuration cannot drift apart.
const kThemeSwapDuration = Duration(milliseconds: 220);

/// True while a theme swap is animating.
///
/// Read with ref.read only — deliberately never watched by a widget. Watching
/// it high in the tree is what made the old overlay cost two extra full-tree
/// rebuilds per switch. Its only job is to drop clicks that arrive mid-swap:
/// each accepted click rebuilds the entire tree, including every channel
/// cached in MainShell's IndexedStack, so letting them stack spikes the CPU.
final themeSwapInFlightProvider = StateProvider<bool>((ref) => false);

/// Direct color provider — widgets watch THIS instead of Theme.of(context).
/// Changing theme only rebuilds widgets that ref.watch this, NOT the entire tree.
final infernoColorsProvider = Provider<InfernoColors>((ref) {
  final name = ref.watch(themeNameProvider);
  return InfernoThemes.colorsForName(name);
});

/// UI effects theme — separate from color theme
final effectThemeNameProvider = StateNotifierProvider<EffectThemeNotifier, String>((ref) {
  return EffectThemeNotifier();
});

class EffectThemeNotifier extends StateNotifier<String> {
  static const _key = 'inferno_effect_theme';
  static const _storage = FlutterSecureStorage();

  EffectThemeNotifier() : super('inferno') {
    _load();
  }

  Future<void> _load() async {
    final saved = await _storage.read(key: _key);
    if (saved != null && UiEffectTheme.names.contains(saved)) {
      state = saved;
    }
  }

  void setEffect(String name) {
    if (!UiEffectTheme.names.contains(name) || name == state) return;
    state = name;
    _storage.write(key: _key, value: name);
  }
}

final uiEffectThemeProvider = Provider<UiEffectTheme>((ref) {
  final name = ref.watch(effectThemeNameProvider);
  return UiEffectTheme.forName(name);
});
