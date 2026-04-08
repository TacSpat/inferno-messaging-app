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
    final themeName = ref.watch(themeNameProvider);
    final themeData = InfernoThemes.forName(themeName);
    final transitioning = ref.watch(themeTransitionProvider);

    return MaterialApp.router(
      title: 'Inferno',
      theme: themeData,
      themeAnimationDuration: Duration.zero,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        // On mobile, wrap with UpgradeAlert for App Store / Play Store prompts
        var content = child!;
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
            if (transitioning)
              Positioned.fill(
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
              ),
          ],
        );
      },
    );
  }
}
