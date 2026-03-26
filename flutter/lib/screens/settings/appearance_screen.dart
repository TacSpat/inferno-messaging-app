import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/theme_provider.dart';
import '../../theme/all_themes.dart';
import '../../theme/ui_effects.dart';

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTheme = ref.watch(themeNameProvider);
    final currentEffect = ref.watch(effectThemeNameProvider);
    final c = Theme.of(context).extension<InfernoColors>()!;

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
              onTap: () => ref.read(themeNameProvider.notifier).setTheme(name),
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
              onTap: () => ref.read(effectThemeNameProvider.notifier).setEffect(effect.name),
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
