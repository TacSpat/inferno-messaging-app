import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'blossom_client.dart';

class BlossomCacheService {
  static const int defaultMaxSizeGb = 5;
  static const int maxFileSizeBytes = 100 * 1024 * 1024; // 100MB
  static const double evictionTarget = 0.8;

  int _maxSizeGb;
  String? _cacheDir;

  BlossomCacheService({int maxSizeGb = defaultMaxSizeGb}) : _maxSizeGb = maxSizeGb;

  set maxSizeGb(int value) => _maxSizeGb = value;

  Future<String> get _cachePath async {
    if (_cacheDir != null) return _cacheDir!;
    final appDir = await getApplicationSupportDirectory();
    _cacheDir = p.join(appDir.path, 'blossom_cache');
    await Directory(_cacheDir!).create(recursive: true);
    return _cacheDir!;
  }

  /// Get a cached Blossom file, downloading if needed
  Future<File?> getOrDownload(String blossomUrl) async {
    final hash = BlossomClient.extractHash(blossomUrl);
    if (hash == null) return null;

    final cached = await getCached(hash);
    if (cached != null) return cached;

    return _downloadAndCache(blossomUrl, hash);
  }

  /// Get cached file by hash
  Future<File?> getCached(String hash) async {
    final filePath = p.join(await _cachePath, hash);
    final file = File(filePath);
    if (await file.exists()) {
      await file.setLastModified(DateTime.now());
      return file;
    }
    return null;
  }

  /// Download, verify hash, and cache
  Future<File?> _downloadAndCache(String url, String expectedHash) async {
    final bytes = await BlossomClient.download(url, timeout: const Duration(seconds: 60));
    if (bytes == null) return null;
    if (bytes.length > maxFileSizeBytes) return null;

    // Verify hash
    final actualHash = sha256.convert(bytes).toString();
    if (actualHash != expectedHash) return null;

    await _ensureCapacity(bytes.length);

    final filePath = p.join(await _cachePath, expectedHash);
    final file = File(filePath);
    await file.writeAsBytes(bytes);
    return file;
  }

  /// Get total cache size
  Future<int> getCacheSize() async {
    final dir = Directory(await _cachePath);
    if (!await dir.exists()) return 0;
    int total = 0;
    await for (final entity in dir.list()) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  /// Clear the entire cache
  Future<int> clearCache() async {
    final dir = Directory(await _cachePath);
    if (!await dir.exists()) return 0;
    int count = 0;
    await for (final entity in dir.list()) {
      if (entity is File) { await entity.delete(); count++; }
    }
    return count;
  }

  /// LRU eviction to 80% capacity
  Future<void> _ensureCapacity(int neededBytes) async {
    final maxBytes = _maxSizeGb * 1024 * 1024 * 1024;
    final currentSize = await getCacheSize();
    if (currentSize + neededBytes <= maxBytes) return;

    final targetSize = (maxBytes * evictionTarget).toInt();
    final dir = Directory(await _cachePath);
    if (!await dir.exists()) return;

    final files = <MapEntry<File, DateTime>>[];
    await for (final entity in dir.list()) {
      if (entity is File) {
        final stat = await entity.stat();
        files.add(MapEntry(entity, stat.modified));
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
}
