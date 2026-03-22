import 'dart:convert';
import 'package:http/http.dart' as http;

class GifService {
  // Tenor API key — in production this should come from app config
  static const _apiKey = 'LIVDSRZULELA'; // Tenor public test key
  static const _baseUrl = 'https://tenor.googleapis.com/v2';

  /// Search for GIFs
  Future<List<GifResult>> search(String query, {int limit = 20}) async {
    if (query.trim().isEmpty) return [];
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/search?q=${Uri.encodeComponent(query)}&key=$_apiKey&limit=$limit&media_filter=gif,tinygif'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return [];
      final data = json.decode(response.body) as Map<String, dynamic>;
      final results = data['results'] as List? ?? [];
      return results.map((r) => GifResult.fromTenor(r as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Get trending GIFs
  Future<List<GifResult>> trending({int limit = 20}) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/featured?key=$_apiKey&limit=$limit&media_filter=gif,tinygif'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return [];
      final data = json.decode(response.body) as Map<String, dynamic>;
      final results = data['results'] as List? ?? [];
      return results.map((r) => GifResult.fromTenor(r as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }
}

class GifResult {
  final String id;
  final String previewUrl;
  final String gifUrl;
  final String tenorUrl;
  final String? description;

  GifResult({
    required this.id,
    required this.previewUrl,
    required this.gifUrl,
    required this.tenorUrl,
    this.description,
  });

  factory GifResult.fromTenor(Map<String, dynamic> json) {
    final mediaFormats = json['media_formats'] as Map<String, dynamic>? ?? {};
    final gif = mediaFormats['gif'] as Map<String, dynamic>? ?? {};
    final tinygif = mediaFormats['tinygif'] as Map<String, dynamic>? ?? {};
    return GifResult(
      id: json['id']?.toString() ?? '',
      previewUrl: tinygif['url'] as String? ?? '',
      gifUrl: gif['url'] as String? ?? '',
      tenorUrl: json['itemurl'] as String? ?? '',
      description: json['content_description'] as String?,
    );
  }
}
