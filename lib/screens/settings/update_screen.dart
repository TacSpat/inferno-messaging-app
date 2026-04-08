import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../theme/all_themes.dart';
import '../../theme/theme_provider.dart';
import '../../providers/app_update_provider.dart';
import '../../services/app_update_service.dart';

class UpdateScreen extends ConsumerStatefulWidget {
  const UpdateScreen({super.key});

  @override
  ConsumerState<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends ConsumerState<UpdateScreen> {
  String _currentVersion = '';
  AppUpdate? _update;
  bool _checking = false;
  bool _downloading = false;
  double _progress = 0.0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _currentVersion = info.version);
  }

  Future<void> _checkForUpdate() async {
    setState(() { _checking = true; _error = null; });
    try {
      if (!kIsWeb && Platform.isAndroid) {
        // Android: use Google Play in-app update API
        final info = await InAppUpdate.checkForUpdate();
        if (info.updateAvailability == UpdateAvailability.updateAvailable) {
          if (info.immediateUpdateAllowed) {
            await InAppUpdate.performImmediateUpdate();
          } else if (info.flexibleUpdateAllowed) {
            await InAppUpdate.startFlexibleUpdate();
            await InAppUpdate.completeFlexibleUpdate();
          }
        }
        if (mounted) setState(() { _checking = false; });
        return;
      }

      // Desktop: check GitHub releases
      final svc = ref.read(appUpdateServiceProvider);
      final update = await svc.checkForUpdate();
      if (mounted) setState(() { _update = update; _checking = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _checking = false; });
    }
  }

  Future<void> _downloadUpdate() async {
    if (_update == null) return;
    setState(() { _downloading = true; _progress = 0.0; _error = null; });

    final svc = ref.read(appUpdateServiceProvider);

    // Poll progress
    final ticker = Stream.periodic(const Duration(milliseconds: 100));
    final sub = ticker.listen((_) {
      if (mounted && svc.downloading) {
        setState(() => _progress = svc.downloadProgress);
      }
    });

    try {
      final ok = await svc.downloadAndApply();
      if (mounted && !ok) {
        setState(() { _error = 'Download failed. Try downloading manually.'; _downloading = false; });
      }
      // If ok, the app will exit and relaunch — we won't reach here.
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _downloading = false; });
    } finally {
      sub.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);

    return Scaffold(
      backgroundColor: c.gray800,
      appBar: AppBar(
        backgroundColor: c.gray700,
        foregroundColor: c.gray50,
        title: const Text('App Updates'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Current version
            _InfoRow(label: 'Current Version', value: _currentVersion, colors: c),
            const SizedBox(height: 8),
            _InfoRow(label: 'Platform', value: _platformName(), colors: c),
            const SizedBox(height: 24),

            // Check button
            if (!_downloading)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: c.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: _checking ? null : _checkForUpdate,
                  icon: _checking
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.refresh, size: 18),
                  label: Text(_checking ? 'Checking...' : 'Check for Updates'),
                ),
              ),

            const SizedBox(height: 24),

            // Update result
            if (_update != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: c.gray700,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: c.accent.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.new_releases, color: c.accent, size: 20),
                        const SizedBox(width: 8),
                        Text('Version ${_update!.version} Available',
                            style: TextStyle(color: c.gray50, fontSize: 16, fontWeight: FontWeight.w600)),
                      ],
                    ),
                    if (_update!.releaseNotes != null && _update!.releaseNotes!.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 200),
                        child: SingleChildScrollView(
                          child: Text(_update!.releaseNotes!,
                              style: TextStyle(color: c.gray200, fontSize: 13, height: 1.5)),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),

                    // Download / progress
                    if (_downloading) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _progress > 0 ? _progress : null,
                          backgroundColor: c.gray600,
                          valueColor: AlwaysStoppedAnimation(c.accent),
                          minHeight: 6,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text('Downloading... ${(_progress * 100).toStringAsFixed(0)}%',
                          style: TextStyle(color: c.gray400, fontSize: 12)),
                    ] else ...[
                      Row(
                        children: [
                          if (_update!.downloadUrl != null && !kIsWeb && !Platform.isAndroid && !Platform.isIOS)
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: c.accent,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                                onPressed: _downloadUpdate,
                                icon: const Icon(Icons.download, size: 18),
                                label: const Text('Download & Install'),
                              ),
                            ),
                          if (_update!.downloadUrl != null && !kIsWeb && !Platform.isAndroid && !Platform.isIOS)
                            const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: c.gray200,
                                side: BorderSide(color: c.gray500),
                                padding: const EdgeInsets.symmetric(vertical: 10),
                              ),
                              onPressed: () => launchUrl(Uri.parse(_update!.htmlUrl)),
                              icon: const Icon(Icons.open_in_new, size: 18),
                              label: const Text('View on GitHub'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ] else if (!_checking && _error == null && _update == null && _currentVersion.isNotEmpty) ...[
              // Only show "up to date" after an explicit check
            ],

            // Error
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                ),
                child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
              ),
            ],

            const Spacer(),

            // Platform-specific note
            Text(
              _platformNote(),
              style: TextStyle(color: c.gray500, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  String _platformName() {
    if (kIsWeb) return 'Web';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    return 'Unknown';
  }

  String _platformNote() {
    if (kIsWeb) return '';
    if (Platform.isAndroid) return 'Android updates are handled via Google Play.';
    if (Platform.isIOS) return 'iOS updates are handled via the App Store.';
    return 'Updates are downloaded from GitHub Releases.';
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final InfernoColors colors;
  const _InfoRow({required this.label, required this.value, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('$label: ', style: TextStyle(color: colors.gray400, fontSize: 13)),
        Text(value, style: TextStyle(color: colors.gray200, fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
