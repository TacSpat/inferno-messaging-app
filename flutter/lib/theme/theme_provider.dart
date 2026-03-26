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

  Future<void> setTheme(String name) async {
    if (InfernoThemes.themeNames.contains(name)) {
      state = name;
      await _storage.write(key: _key, value: name);
    }
  }
}

final themeDataProvider = Provider<ThemeData>((ref) {
  final name = ref.watch(themeNameProvider);
  return InfernoThemes.forName(name);
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

  Future<void> setEffect(String name) async {
    if (UiEffectTheme.names.contains(name)) {
      state = name;
      await _storage.write(key: _key, value: name);
    }
  }
}

final uiEffectThemeProvider = Provider<UiEffectTheme>((ref) {
  final name = ref.watch(effectThemeNameProvider);
  return UiEffectTheme.forName(name);
});
