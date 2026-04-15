import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/app_update_service.dart';

/// Singleton desktop update service.
final appUpdateServiceProvider = Provider<AppUpdateService>((ref) {
  return AppUpdateService();
});

/// App version string from package_info_plus.
final appVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return info.version;
});

/// Checks for updates on startup, then re-checks every 30 minutes.
/// Desktop: GitHub releases. Mobile: handled separately via in_app_update / upgrader.
final updateCheckProvider = StreamProvider<AppUpdate?>((ref) async* {
  if (kIsWeb) { yield null; return; }
  if (Platform.isAndroid || Platform.isIOS) { yield null; return; }
  // Skip update checks in debug builds — avoids noise during local development
  // and prevents the auto-updater from prompting against the dev binary.
  if (kDebugMode) { yield null; return; }

  final svc = ref.read(appUpdateServiceProvider);

  // Check immediately on startup
  yield await svc.checkForUpdate();

  // Re-check every 30 minutes
  await for (final _ in Stream.periodic(const Duration(minutes: 30))) {
    yield await svc.checkForUpdate();
  }
});
