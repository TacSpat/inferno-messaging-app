import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';

class BlossomClient {
  static const defaultServers = [
    'https://blossom.primal.net',
    'https://cdn.satellite.earth',
  ];

  /// Upload a file to a Blossom server
  /// Returns the URL of the uploaded file
  static Future<String?> upload({
    required Uint8List fileBytes,
    required String privateKeyHex,
    required String publicKeyHex,
    String? serverUrl,
    String? contentType,
  }) async {
    final server = serverUrl ?? defaultServers.first;
    final sha256Hash = sha256.convert(fileBytes).toString();

    // Build Kind 24242 auth event
    final expiration = nostr.NostrEvent.now() + 300; // 5 minutes
    final authEvent = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 24242,
      tags: [
        ['t', 'upload'],
        ['x', sha256Hash],
        ['expiration', expiration.toString()],
      ],
      content: '',
    );
    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(authEvent);
    final authHeader = base64.encode(utf8.encode(json.encode(signed.toJson())));

    // HTTP PUT upload
    try {
      final response = await http.put(
        Uri.parse('$server/upload'),
        headers: {
          'X-SHA-256': sha256Hash,
          'Authorization': 'Nostr $authHeader',
          if (contentType case final ct?) 'Content-Type': ct,
        },
        body: fileBytes,
      ).timeout(const Duration(seconds: 60));

      if (response.statusCode == 200 || response.statusCode == 201) {
        try {
          final body = json.decode(response.body) as Map<String, dynamic>;
          return body['url'] as String? ?? '$server/$sha256Hash';
        } catch (_) {
          return '$server/$sha256Hash';
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Upload a file from disk
  static Future<String?> uploadFile({
    required String filePath,
    required String privateKeyHex,
    required String publicKeyHex,
    String? serverUrl,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    final ext = filePath.split('.').last.toLowerCase();
    final contentType = _mimeType(ext);
    return upload(
      fileBytes: bytes,
      privateKeyHex: privateKeyHex,
      publicKeyHex: publicKeyHex,
      serverUrl: serverUrl,
      contentType: contentType,
    );
  }

  /// Download a file by URL
  static Future<Uint8List?> download(String url, {Duration timeout = const Duration(seconds: 30)}) async {
    try {
      final response = await http.get(Uri.parse(url)).timeout(timeout);
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Extract SHA-256 hash from a Blossom URL
  static String? extractHash(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final lastSegment = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
    // Remove extension if present
    final hash = lastSegment.split('.').first;
    if (RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) return hash;
    return null;
  }

  static String? _mimeType(String ext) {
    const types = {
      'png': 'image/png', 'jpg': 'image/jpeg', 'jpeg': 'image/jpeg',
      'gif': 'image/gif', 'webp': 'image/webp', 'svg': 'image/svg+xml',
      'avif': 'image/avif', 'mp4': 'video/mp4', 'webm': 'video/webm',
      'mov': 'video/quicktime', 'mp3': 'audio/mpeg', 'ogg': 'audio/ogg',
      'wav': 'audio/wav', 'm4a': 'audio/mp4',
    };
    return types[ext];
  }
}
