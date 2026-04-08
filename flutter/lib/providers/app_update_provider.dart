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

/// Checks for updates on first read.
/// Desktop: GitHub releases. Mobile: handled separately via in_app_update / upgrader.
final updateCheckProvider = FutureProvider<AppUpdate?>((ref) async {
  if (kIsWeb) return null;
  if (Platform.isAndroid || Platform.isIOS) return null; // Mobile uses store APIs
  final svc = ref.read(appUpdateServiceProvider);
  return svc.checkForUpdate();
});
