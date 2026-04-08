import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

/// Perceptual image hashing using dHash (difference hash).
///
/// dHash works by:
/// 1. Resize image to 9x8 grayscale (9 wide so we get 8 horizontal diffs)
/// 2. Compare each pixel to its right neighbor
/// 3. Left > right = 1 bit, else 0 bit
/// 4. Result: 64-bit hash that survives resizing, compression, minor edits
class ImageHasher {
  static const _hashWidth = 9;
  static const _hashHeight = 8;

  /// Compute dHash for image bytes.
  /// Returns hex string (16 chars = 64 bits) or null on failure.
  static String? dhash(Uint8List imageBytes) {
    try {
      final decoded = img.decodeImage(imageBytes);
      if (decoded == null) return null;

      // Convert to 9x8 grayscale
      final resized = img.copyResize(decoded,
          width: _hashWidth, height: _hashHeight,
          interpolation: img.Interpolation.average);
      final gray = img.grayscale(resized);

      // Build hash: compare each pixel to its right neighbor
      final bits = <int>[];
      for (int y = 0; y < _hashHeight; y++) {
        for (int x = 0; x < _hashWidth - 1; x++) {
          final left = gray.getPixel(x, y).luminance;
          final right = gray.getPixel(x + 1, y).luminance;
          bits.add(left > right ? 1 : 0);
        }
      }

      // Convert 64 bits to hex
      final buf = StringBuffer();
      for (int i = 0; i < bits.length; i += 4) {
        final nibble = (bits[i] << 3) | (bits[i + 1] << 2) | (bits[i + 2] << 1) | bits[i + 3];
        buf.write(nibble.toRadixString(16));
      }
      return buf.toString();
    } catch (e) {
      debugPrint('[ImageHasher] Failed to hash image: $e');
      return null;
    }
  }

  /// Compute hamming distance between two hex hash strings.
  static int hammingDistance(String a, String b) {
    if (a.length != b.length) return 64; // max distance
    final intA = int.tryParse(a, radix: 16);
    final intB = int.tryParse(b, radix: 16);
    if (intA == null || intB == null) return 64;

    int xor = intA ^ intB;
    int count = 0;
    while (xor > 0) {
      count += xor & 1;
      xor >>= 1;
    }
    return count;
  }

  /// Check if two hashes are perceptually similar.
  static bool isSimilar(String a, String b, {int threshold = 10}) {
    return hammingDistance(a, b) <= threshold;
  }

  /// Hash all image attachments in a message's fileUrls JSON.
  /// Returns list of {hashValue, hashType, mediaType, originalFilename}.
  static Future<List<ImageHashResult>> hashMessageAttachments(String? fileUrlsJson) async {
    if (fileUrlsJson == null || fileUrlsJson.isEmpty) return [];

    final List<dynamic> urls;
    try {
      urls = jsonDecode(fileUrlsJson) as List<dynamic>;
    } catch (_) {
      return [];
    }

    final results = <ImageHashResult>[];
    for (final url in urls) {
      final urlStr = url.toString();
      // Only hash image URLs
      final lower = urlStr.toLowerCase();
      if (!lower.endsWith('.jpg') && !lower.endsWith('.jpeg') &&
          !lower.endsWith('.png') && !lower.endsWith('.gif') &&
          !lower.endsWith('.webp') && !lower.endsWith('.bmp') &&
          !lower.contains('image')) {
        continue;
      }

      try {
        final response = await http.get(Uri.parse(urlStr));
        if (response.statusCode == 200) {
          final hash = await compute(_computeDhash, response.bodyBytes);
          if (hash != null) {
            final filename = Uri.parse(urlStr).pathSegments.lastOrNull ?? urlStr;
            results.add(ImageHashResult(
              hashValue: hash,
              hashType: 'dhash',
              mediaType: 'image',
              originalFilename: filename,
            ));
          }
        }
      } catch (e) {
        debugPrint('[ImageHasher] Failed to fetch/hash $urlStr: $e');
      }
    }
    return results;
  }
}

/// Isolate-safe dHash computation.
String? _computeDhash(Uint8List bytes) => ImageHasher.dhash(bytes);

class ImageHashResult {
  final String hashValue;
  final String hashType;
  final String mediaType;
  final String originalFilename;

  const ImageHashResult({
    required this.hashValue,
    required this.hashType,
    required this.mediaType,
    required this.originalFilename,
  });
}
