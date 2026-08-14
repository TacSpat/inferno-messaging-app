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
    // Only themeNameProvider is watched here. themeTransitionProvider used to
    // be watched at this level too, which meant raising and lowering the
    // spinner each rebuilt MaterialApp.router and everything under it — so a
    // theme switch cost three full-tree rebuilds (flag on, swap, flag off)
    // when only the middle one changes anything. The overlay now watches the
    // flag itself, so the two bookend rebuilds are confined to it.
    final themeName = ref.watch(themeNameProvider);
    final themeData = InfernoThemes.forName(themeName);

    return MaterialApp.router(
      title: 'Inferno',
      theme: themeData,
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
        return Stack(
          children: [
            content,
            const _ThemeTransitionOverlay(),
          ],
        );
      },
    );
  }
}

/// Covers the app while the theme swaps.
///
/// Deliberately its own ConsumerWidget: it is the only thing that watches
/// themeTransitionProvider, so raising and lowering the spinner rebuilds this
/// widget alone rather than MaterialApp.router and the entire page stack
/// beneath it.
class _ThemeTransitionOverlay extends ConsumerWidget {
  const _ThemeTransitionOverlay();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(themeTransitionProvider)) return const SizedBox.shrink();

    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}
