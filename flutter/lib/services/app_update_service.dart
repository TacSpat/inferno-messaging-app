import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

const _githubOwner = 'TacSpat';
const _githubRepo = 'inferno-messaging-app';

/// Represents an available update from GitHub releases.
class AppUpdate {
  final String version;
  final String? releaseNotes;
  final String? downloadUrl;
  final String htmlUrl;
  final DateTime publishedAt;

  const AppUpdate({
    required this.version,
    this.releaseNotes,
    this.downloadUrl,
    required this.htmlUrl,
    required this.publishedAt,
  });
}

/// Desktop auto-updater that checks GitHub Releases, downloads the new binary,
/// and spawns a helper script to replace the exe and relaunch.
///
/// Mobile platforms use in_app_update (Android) and upgrader (iOS) instead —
/// see app_update_provider.dart for the unified provider.
class AppUpdateService {
  AppUpdate? _latestUpdate;
  bool _checking = false;
  bool _downloading = false;
  double _downloadProgress = 0.0;

  AppUpdate? get latestUpdate => _latestUpdate;
  bool get checking => _checking;
  bool get downloading => _downloading;
  double get downloadProgress => _downloadProgress;

  /// Check GitHub releases for a newer version.
  /// Returns the update info if available, null if up-to-date.
  Future<AppUpdate?> checkForUpdate() async {
    if (_checking) return _latestUpdate;
    _checking = true;
    try {
      final info = await PackageInfo.fromPlatform();
      final currentVersion = info.version; // e.g. "0.1.0"

      final response = await http.get(
        Uri.parse('https://api.github.com/repos/$_githubOwner/$_githubRepo/releases/latest'),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      );

      if (response.statusCode == 404) {
        // No releases published yet — not an error
        return null;
      }
      if (response.statusCode != 200) {
        debugPrint('[Update] GitHub API returned ${response.statusCode}');
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final tagName = data['tag_name'] as String? ?? '';
      final remoteVersion = tagName.startsWith('v') ? tagName.substring(1) : tagName;

      if (!_isNewer(remoteVersion, currentVersion)) {
        debugPrint('[Update] Up to date ($currentVersion >= $remoteVersion)');
        _latestUpdate = null;
        return null;
      }

      // Find the asset for the current platform
      final assets = data['assets'] as List<dynamic>? ?? [];
      final downloadUrl = _findPlatformAsset(assets);

      _latestUpdate = AppUpdate(
        version: remoteVersion,
        releaseNotes: data['body'] as String?,
        downloadUrl: downloadUrl,
        htmlUrl: data['html_url'] as String? ?? '',
        publishedAt: DateTime.tryParse(data['published_at'] as String? ?? '') ?? DateTime.now(),
      );

      debugPrint('[Update] New version available: $remoteVersion (current: $currentVersion)');
      return _latestUpdate;
    } catch (e) {
      debugPrint('[Update] Check failed: $e');
      return null;
    } finally {
      _checking = false;
    }
  }

  /// Download the update binary and apply it.
  /// On desktop: downloads to temp, spawns a helper script that swaps the exe and relaunches.
  Future<bool> downloadAndApply() async {
    if (_downloading || _latestUpdate?.downloadUrl == null) return false;
    _downloading = true;
    _downloadProgress = 0.0;
    try {
      final url = _latestUpdate!.downloadUrl!;
      final tempDir = await getTemporaryDirectory();
      final updateDir = Directory(p.join(tempDir.path, 'inferno_update'));
      if (await updateDir.exists()) await updateDir.delete(recursive: true);
      await updateDir.create(recursive: true);

      // Download with progress
      final request = http.Request('GET', Uri.parse(url));
      final streamedResponse = await http.Client().send(request);
      final totalBytes = streamedResponse.contentLength ?? 0;
      var receivedBytes = 0;

      final fileName = Uri.parse(url).pathSegments.last;
      final filePath = p.join(updateDir.path, fileName);
      final sink = File(filePath).openWrite();

      await for (final chunk in streamedResponse.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          _downloadProgress = receivedBytes / totalBytes;
        }
      }
      await sink.close();

      debugPrint('[Update] Downloaded to $filePath');

      // Apply the update via platform-specific script
      await _applyUpdate(filePath, updateDir.path);
      return true;
    } catch (e) {
      debugPrint('[Update] Download failed: $e');
      return false;
    } finally {
      _downloading = false;
    }
  }

  /// Compare semver strings. Returns true if remote is newer than current.
  bool _isNewer(String remote, String current) {
    final r = remote.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final c = current.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    // Pad to 3 segments
    while (r.length < 3) { r.add(0); }
    while (c.length < 3) { c.add(0); }
    for (var i = 0; i < 3; i++) {
      if (r[i] > c[i]) return true;
      if (r[i] < c[i]) return false;
    }
    return false;
  }

  /// Find the download URL for the current platform from GitHub release assets.
  String? _findPlatformAsset(List<dynamic> assets) {
    final patterns = <String>[];
    if (Platform.isWindows) {
      patterns.addAll(['.exe', 'windows', 'win64', 'win-x64']);
    } else if (Platform.isMacOS) {
      patterns.addAll(['.dmg', '.zip', 'macos', 'darwin']);
    } else if (Platform.isLinux) {
      patterns.addAll(['.AppImage', '.tar.gz', 'linux', 'linux-x64']);
    }

    for (final asset in assets) {
      final name = (asset['name'] as String? ?? '').toLowerCase();
      for (final pattern in patterns) {
        if (name.contains(pattern.toLowerCase())) {
          return asset['browser_download_url'] as String?;
        }
      }
    }
    return null;
  }

  /// Platform-specific update application.
  Future<void> _applyUpdate(String downloadedFile, String updateDir) async {
    final currentExe = Platform.resolvedExecutable;

    if (Platform.isWindows) {
      // Write a batch script that waits for this process to exit,
      // replaces the exe, and relaunches.
      final script = p.join(updateDir, 'update.bat');
      await File(script).writeAsString('''
@echo off
echo Updating Inferno...
timeout /t 2 /nobreak >nul
copy /y "$downloadedFile" "$currentExe"
start "" "$currentExe"
del "%~f0"
''');
      await Process.start('cmd', ['/c', script],
          mode: ProcessStartMode.detached);
      exit(0);
    } else if (Platform.isLinux) {
      final script = p.join(updateDir, 'update.sh');
      await File(script).writeAsString('''
#!/bin/bash
sleep 2
cp "$downloadedFile" "$currentExe"
chmod +x "$currentExe"
"$currentExe" &
rm "\$0"
''');
      await Process.start('bash', [script],
          mode: ProcessStartMode.detached);
      exit(0);
    } else if (Platform.isMacOS) {
      // For .dmg, open it and let the user drag-install.
      // For .zip, extract and replace.
      if (downloadedFile.endsWith('.dmg')) {
        await Process.start('open', [downloadedFile],
            mode: ProcessStartMode.detached);
      } else {
        final script = p.join(updateDir, 'update.sh');
        final appBundle = '${currentExe.split('.app/').first}.app';
        await File(script).writeAsString('''
#!/bin/bash
sleep 2
if [[ "$downloadedFile" == *.zip ]]; then
  unzip -o "$downloadedFile" -d "$updateDir/extracted"
  extracted_app=\$(find "$updateDir/extracted" -name "*.app" -maxdepth 2 | head -1)
  if [ -n "\$extracted_app" ]; then
    rm -rf "$appBundle"
    mv "\$extracted_app" "$appBundle"
  fi
fi
open "$appBundle"
rm "\$0"
''');
        await Process.start('bash', [script],
            mode: ProcessStartMode.detached);
        exit(0);
      }
    }
  }
}
