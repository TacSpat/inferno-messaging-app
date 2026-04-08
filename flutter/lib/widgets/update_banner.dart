import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/theme_provider.dart';
import '../providers/app_update_provider.dart';
import '../screens/settings/update_screen.dart';

/// Shows a dismissible banner at the top of the app when a desktop update is available.
/// For mobile, updates are handled by the store — this widget is a no-op.
class UpdateBanner extends ConsumerStatefulWidget {
  const UpdateBanner({super.key});

  @override
  ConsumerState<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends ConsumerState<UpdateBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || _dismissed) return const SizedBox.shrink();
    if (Platform.isAndroid || Platform.isIOS) return const SizedBox.shrink();

    final updateAsync = ref.watch(updateCheckProvider);

    return updateAsync.when(
      data: (update) {
        if (update == null) return const SizedBox.shrink();
        final c = ref.watch(infernoColorsProvider);
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: c.accent.withValues(alpha: 0.15),
          child: Row(
            children: [
              Icon(Icons.system_update, size: 16, color: c.accent),
              const SizedBox(width: 8),
              Text('Version ${update.version} is available',
                  style: TextStyle(color: c.gray200, fontSize: 13)),
              const Spacer(),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: c.accent,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const UpdateScreen()));
                },
                child: const Text('Update', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () => setState(() => _dismissed = true),
                child: Icon(Icons.close, size: 16, color: c.gray400),
              ),
            ],
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}
