import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/theme_provider.dart';
import '../../theme/all_themes.dart';
import '../../theme/ui_effects.dart';

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  /// Show the overlay, swap, then hide once the rebuilt frame has actually
  /// been drawn.
  ///
  /// This used to sleep 50ms before the swap and 150ms after, guessing at how
  /// long the rebuild would take. That 200ms was pure dead time the user sat
  /// through on every theme change, and it was a guess in both directions —
  /// too long on a fast machine, potentially too short on a slow one.
  /// Awaiting endOfFrame waits for exactly the work that matters.
  Future<void> _withTransition(WidgetRef ref, void Function() swap) async {
    if (ref.read(themeTransitionProvider)) return;
    ref.read(themeTransitionProvider.notifier).state = true;

    // Let the overlay paint before the swap begins.
    await SchedulerBinding.instance.endOfFrame;

    swap();

    // The swap marked the tree dirty and scheduled a frame; wait for that
    // frame to finish rather than assuming a duration.
    await SchedulerBinding.instance.endOfFrame;

    ref.read(themeTransitionProvider.notifier).state = false;
  }

  Future<void> _switchTheme(WidgetRef ref, String name) =>
      _withTransition(ref, () => ref.read(themeNameProvider.notifier).setTheme(name));

  Future<void> _switchEffect(WidgetRef ref, String name) =>
      _withTransition(ref, () => ref.read(effectThemeNameProvider.notifier).setEffect(name));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTheme = ref.watch(themeNameProvider);
    final currentEffect = ref.watch(effectThemeNameProvider);
    final c = ref.watch(infernoColorsProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Appearance', style: TextStyle(color: c.gray50, fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 24),

        // Color theme
        Text('COLOR THEME', style: TextStyle(color: c.gray500, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1)),
        const SizedBox(height: 12),
        ...InfernoThemes.themeNames.map((name) {
          final isSelected = name == currentTheme;
          final color = InfernoThemes.primaryColorForName(name);
          return Card(
            color: c.gray900,
            margin: const EdgeInsets.only(bottom: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: isSelected ? BorderSide(color: color, width: 2) : BorderSide.none,
            ),
            child: ListTile(
              leading: Container(
                width: 40, height: 40,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
              ),
              title: Text(name[0].toUpperCase() + name.substring(1), style: TextStyle(color: c.gray200)),
              trailing: isSelected ? Icon(Icons.check_circle, color: color) : null,
              onTap: () => _switchTheme(ref, name),
            ),
          );
        }),

        const SizedBox(height: 24),

        // UI Effects theme
        Text('UI EFFECTS', style: TextStyle(color: c.gray500, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1)),
        const SizedBox(height: 4),
        Text('Visual effects applied on top of the color theme.', style: TextStyle(color: c.gray500, fontSize: 12)),
        const SizedBox(height: 12),
        ...UiEffectTheme.all.map((effect) {
          final isSelected = effect.name == currentEffect;
          return Card(
            color: c.gray900,
            margin: const EdgeInsets.only(bottom: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: isSelected ? BorderSide(color: c.accent, width: 2) : BorderSide.none,
            ),
            child: ListTile(
              leading: Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: c.gray800,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: isSelected ? c.accent : c.gray700),
                ),
                child: Icon(
                  effect.embers ? Icons.local_fire_department
                    : effect.glowPulse ? Icons.auto_awesome
                    : Icons.blur_off,
                  color: isSelected ? c.accent : c.gray500,
                  size: 20,
                ),
              ),
              title: Text(effect.label, style: TextStyle(color: c.gray200)),
              subtitle: Text(
                _effectDescription(effect),
                style: TextStyle(color: c.gray500, fontSize: 12),
              ),
              trailing: isSelected ? Icon(Icons.check_circle, color: c.accent) : null,
              onTap: () => _switchEffect(ref, effect.name),
            ),
          );
        }),
      ],
    );
  }

  String _effectDescription(UiEffectTheme effect) {
    if (effect.name == 'none') return 'Clean interface with no visual effects';
    final parts = <String>[];
    if (effect.embers) parts.add('ember particles');
    if (effect.glowPulse) parts.add('glow pulse');
    if (effect.hoverTint) parts.add('accent hover');
    if (effect.moltenShimmer) parts.add('molten shimmer');
    if (effect.avatarGlow) parts.add('avatar glow');
    return parts.join(' \u2022 ');
  }
}
