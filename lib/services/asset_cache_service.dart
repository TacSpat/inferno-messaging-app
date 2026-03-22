import 'dart:io';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;

class AssetCacheService {
  static const int defaultMaxSizeMb = 500;
  static const int maxFileSizeBytes = 10 * 1024 * 1024; // 10MB
  static const double evictionTarget = 0.9;

  int _maxSizeMb;
  String? _cacheDir;

  AssetCacheService({int maxSizeMb = defaultMaxSizeMb}) : _maxSizeMb = maxSizeMb;

  set maxSizeMb(int value) => _maxSizeMb = value;

  Future<String> get _cachePath async {
    if (_cacheDir != null) return _cacheDir!;
    final appDir = await getApplicationSupportDirectory();
    _cacheDir = p.join(appDir.path, 'cached_assets');
    await Directory(_cacheDir!).create(recursive: true);
    return _cacheDir!;
  }

  /// Get a cached file, downloading if needed
  Future<File?> getOrDownload(String url) async {
    final cached = await getCached(url);
    if (cached != null) return cached;
    return _downloadAndCache(url);
  }

  /// Get cached file path for a URL (null if not cached)
  Future<File?> getCached(String url) async {
    final filePath = await _filePathForUrl(url);
    final file = File(filePath);
    if (await file.exists()) {
      // Touch access time for LRU
      await file.setLastAccessed(DateTime.now());
      return file;
    }
    return null;
  }

  /// Download and cache a remote file
  Future<File?> _downloadAndCache(String url) async {
    try {
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      if (response.bodyBytes.length > maxFileSizeBytes) return null;

      await _ensureCapacity(response.bodyBytes.length);

      final filePath = await _filePathForUrl(url);
      final file = File(filePath);
      await file.writeAsBytes(response.bodyBytes);
      return file;
    } catch (_) {
      return null;
    }
  }

  /// Get total cache size in bytes
  Future<int> getCacheSize() async {
    final dir = Directory(await _cachePath);
    if (!await dir.exists()) return 0;
    int total = 0;
    await for (final entity in dir.list()) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  /// Clear the entire cache
  Future<int> clearCache() async {
    final dir = Directory(await _cachePath);
    if (!await dir.exists()) return 0;
    int count = 0;
    await for (final entity in dir.list()) {
      if (entity is File) {
        await entity.delete();
        count++;
      }
    }
    return count;
  }

  /// Evict oldest files until cache is at target utilization
  Future<void> _ensureCapacity(int neededBytes) async {
    final maxBytes = _maxSizeMb * 1024 * 1024;
    final currentSize = await getCacheSize();
    if (currentSize + neededBytes <= maxBytes) return;

    final targetSize = (maxBytes * evictionTarget).toInt();
    final dir = Directory(await _cachePath);
    if (!await dir.exists()) return;

    // Sort by access time (oldest first)
    final files = <MapEntry<File, DateTime>>[];
    await for (final entity in dir.list()) {
      if (entity is File) {
        final stat = await entity.stat();
        files.add(MapEntry(entity, stat.accessed));
      }
    }
    files.sort((a, b) => a.value.compareTo(b.value));

    int freed = currentSize;
    for (final entry in files) {
      if (freed <= targetSize) break;
      final size = await entry.key.length();
      await entry.key.delete();
      freed -= size;
    }
  }

  Future<String> _filePathForUrl(String url) async {
    final hash = sha256.convert(utf8.encode(url)).toString();
    final ext = _extensionFromUrl(url);
    return p.join(await _cachePath, '$hash$ext');
  }

  String _extensionFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path;
      final dot = path.lastIndexOf('.');
      if (dot >= 0) {
        final ext = path.substring(dot).toLowerCase();
        if (ext.length <= 5) return ext;
      }
    } catch (_) {}
    return '';
  }
}
