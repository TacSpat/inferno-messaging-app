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

  /// Resolve the actual app executable and bundle directory.
  /// In debug mode, Platform.resolvedExecutable points to the Flutter engine,
  /// not the app binary — detect this and find the real build output.
  (String exe, String bundleDir) _resolveAppPaths() {
    final currentExe = Platform.resolvedExecutable;
    final appDir = p.dirname(currentExe);

    if (Platform.isLinux) {
      // Release: /path/to/bundle/inferno → bundleDir = /path/to/bundle
      // Debug (flutter run): resolvedExecutable = flutter engine binary
      // Check if we're in a Flutter build output
      if (currentExe.contains('flutter') && currentExe.contains('cache')) {
        // Debug mode — find the build output
        final cwd = Directory.current.path;
        // Try build/linux/x64/debug/bundle or build/linux/x64/release/bundle
        for (final mode in ['debug', 'release']) {
          final bundlePath = p.join(cwd, 'build', 'linux', 'x64', mode, 'bundle');
          final exePath = p.join(bundlePath, 'inferno');
          if (File(exePath).existsSync()) {
            debugPrint('[Update] Debug mode: using build output at $bundlePath');
            return (exePath, bundlePath);
          }
        }
        // Fallback: look in flutter subdir
        final flutterCwd = p.join(cwd, 'flutter');
        for (final mode in ['debug', 'release']) {
          final bundlePath = p.join(flutterCwd, 'build', 'linux', 'x64', mode, 'bundle');
          final exePath = p.join(bundlePath, 'inferno');
          if (File(exePath).existsSync()) {
            debugPrint('[Update] Debug mode: using build output at $bundlePath');
            return (exePath, bundlePath);
          }
        }
      }
      return (currentExe, appDir);
    } else if (Platform.isWindows) {
      if (currentExe.contains('flutter') && currentExe.contains('cache')) {
        final cwd = Directory.current.path;
        for (final mode in ['Debug', 'Release']) {
          final runnerPath = p.join(cwd, 'build', 'windows', 'x64', 'runner', mode);
          final exePath = p.join(runnerPath, 'inferno.exe');
          if (File(exePath).existsSync()) return (exePath, runnerPath);
        }
      }
      return (currentExe, appDir);
    } else {
      return (currentExe, appDir);
    }
  }

  /// Platform-specific update application.
  /// Downloads are archives (.zip on Windows, .tar.gz on Linux, .dmg on macOS).
  /// We extract them and replace the entire app directory, then relaunch.
  Future<void> _applyUpdate(String downloadedFile, String updateDir) async {
    final (appExe, bundleDir) = _resolveAppPaths();
    debugPrint('[Update] App exe: $appExe');
    debugPrint('[Update] Bundle dir: $bundleDir');

    if (Platform.isWindows) {
      final extractDir = p.join(updateDir, 'extracted');
      final script = p.join(updateDir, 'update.bat');
      await File(script).writeAsString('''
@echo off
echo Updating Inferno...
timeout /t 3 /nobreak >nul
powershell -Command "Expand-Archive -Force '$downloadedFile' '$extractDir'"
xcopy /s /y /q "$extractDir\\*" "$bundleDir\\"
start "" "$appExe"
del "%~f0"
''');
      await Process.start('cmd', ['/c', script],
          mode: ProcessStartMode.detached);
      exit(0);
    } else if (Platform.isLinux) {
      final script = p.join(updateDir, 'update.sh');
      final logFile = p.join(updateDir, 'update.log');
      await File(script).writeAsString('''
#!/bin/bash
exec > "$logFile" 2>&1
echo "Update script started at \$(date)"
echo "Waiting for app to exit..."
sleep 3
EXTRACT_DIR="$updateDir/extracted"
mkdir -p "\$EXTRACT_DIR"
echo "Extracting $downloadedFile..."
tar xzf "$downloadedFile" -C "\$EXTRACT_DIR"
echo "Extract result: \$?"
ls -la "\$EXTRACT_DIR/"
# The tar.gz contains bundle/ directory
if [ -d "\$EXTRACT_DIR/bundle" ]; then
  echo "Copying bundle to $bundleDir..."
  cp -rf "\$EXTRACT_DIR/bundle/"* "$bundleDir/"
  echo "Copy result: \$?"
else
  echo "ERROR: No bundle/ directory found in archive"
  ls -laR "\$EXTRACT_DIR/"
fi
chmod +x "$appExe"
echo "Relaunching $appExe..."
nohup "$appExe" > /dev/null 2>&1 &
echo "Launched with PID \$!"
sleep 1
rm -rf "\$EXTRACT_DIR"
echo "Cleanup done"
''');
      await Process.run('chmod', ['+x', script]);
      debugPrint('[Update] Running update script: $script');
      debugPrint('[Update] Log file: $logFile');
      await Process.start('bash', [script],
          mode: ProcessStartMode.detached);
      exit(0);
    } else if (Platform.isMacOS) {
      if (downloadedFile.endsWith('.dmg')) {
        await Process.start('open', [downloadedFile],
            mode: ProcessStartMode.detached);
      } else {
        final appBundle = '${appExe.split('.app/').first}.app';
        final script = p.join(updateDir, 'update.sh');
        await File(script).writeAsString('''
#!/bin/bash
sleep 2
EXTRACT_DIR="$updateDir/extracted"
mkdir -p "\$EXTRACT_DIR"
if [[ "$downloadedFile" == *.zip ]]; then
  unzip -o "$downloadedFile" -d "\$EXTRACT_DIR"
fi
extracted_app=\$(find "\$EXTRACT_DIR" -name "*.app" -maxdepth 2 | head -1)
if [ -n "\$extracted_app" ]; then
  rm -rf "$appBundle"
  mv "\$extracted_app" "$appBundle"
fi
open "$appBundle"
rm -rf "\$EXTRACT_DIR"
rm "\$0"
''');
        await Process.run('chmod', ['+x', script]);
        await Process.start('bash', [script],
            mode: ProcessStartMode.detached);
        exit(0);
      }
    }
  }
}
