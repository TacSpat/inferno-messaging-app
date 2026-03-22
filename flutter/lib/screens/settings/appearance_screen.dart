import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/theme_provider.dart';
import '../../theme/all_themes.dart';

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTheme = ref.watch(themeNameProvider);
    final c = Theme.of(context).extension<InfernoColors>()!;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Appearance', style: TextStyle(color: c.gray50, fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 24),
        Text('THEME', style: TextStyle(color: c.gray500, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1)),
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
              onTap: () => ref.read(themeNameProvider.notifier).state = name,
            ),
          );
        }),
      ],
    );
  }
}
