import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:upgrader/upgrader.dart';
import 'router.dart';
import 'theme/all_themes.dart';
import 'theme/theme_provider.dart';

class InfernoApp extends ConsumerWidget {
  const InfernoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only themeNameProvider is watched here, so a theme switch costs exactly
    // one rebuild of this subtree. It previously also watched
    // themeTransitionProvider to drive a black spinner overlay, which meant
    // raising and lowering the spinner each rebuilt MaterialApp.router and
    // everything beneath it — three full-tree rebuilds where one suffices.
    final themeName = ref.watch(themeNameProvider);
    final themeData = InfernoThemes.forName(themeName);

    return MaterialApp.router(
      title: 'Inferno',
      theme: themeData,
      // Was Duration.zero, which disabled MaterialApp's built-in AnimatedTheme
      // entirely — the swap was instant and a black overlay hid the rebuild.
      // InfernoColors implements lerp for every colour (all_themes.dart:301),
      // so with a duration the whole ThemeData, extension included, tweens.
      themeAnimationDuration: kThemeSwapDuration,
      themeAnimationCurve: Curves.easeInOut,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        // Ensure Noto Color Emoji is used as fallback for consistent cross-platform emoji
        var content = DefaultTextStyle.merge(
          style: const TextStyle(fontFamilyFallback: ['NotoColorEmoji']),
          child: child!,
        );
        if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
          content = UpgradeAlert(
            showIgnore: false,
            showLater: true,
            child: content,
          );
        }
        return content;
      },
    );
  }
}
