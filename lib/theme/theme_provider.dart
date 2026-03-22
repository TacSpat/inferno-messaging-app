import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'all_themes.dart';

final themeNameProvider = StateProvider<String>((ref) => 'inferno');

final themeDataProvider = Provider<ThemeData>((ref) {
  final name = ref.watch(themeNameProvider);
  return InfernoThemes.forName(name);
});
