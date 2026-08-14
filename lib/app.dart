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
      // No theme animation. InfernoColors lerps correctly and the tween is
      // wired properly, but it never renders: a swap blocks the UI thread for
      // 130-256ms against any reasonable animation length, so by the time a
      // frame runs the controller is already past its duration and jumps to
      // the end. Measured by printing the palette a widget received across one
      // swap — a single line, carrying the destination colour.
      //
      // So an animation here costs a controller and a debounce window and
      // shows nothing. Switching themes is snappier without it. Restore this
      // once a swap fits in a frame — see the P3 findings in
      // doc/remediation-plan.md.
      themeAnimationDuration: Duration.zero,
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
