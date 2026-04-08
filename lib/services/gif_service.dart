import 'dart:convert';
import 'package:http/http.dart' as http;

class GifService {
  static const _apiKey = 'LIVDSRZULELA';
  static const _clientKey = 'inferno_chat';
  static const _baseUrl = 'https://tenor.googleapis.com/v2';

  String _params({String? extra}) =>
      'key=$_apiKey&client_key=$_clientKey${extra ?? ''}';

  /// Search for GIFs with pagination support
  Future<GifSearchResult> search(String query, {int limit = 20, String? pos}) async {
    if (query.trim().isEmpty) return GifSearchResult.empty();
    try {
      final posParam = pos != null && pos.isNotEmpty ? '&pos=$pos' : '';
      final response = await http.get(
        Uri.parse('$_baseUrl/search?q=${Uri.encodeComponent(query)}&${_params()}&limit=$limit&media_filter=gif,tinygif$posParam'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return GifSearchResult.empty();
      return GifSearchResult.fromJson(json.decode(response.body) as Map<String, dynamic>);
    } catch (_) {
      return GifSearchResult.empty();
    }
  }

  /// Get trending GIFs with pagination
  Future<GifSearchResult> trending({int limit = 20, String? pos}) async {
    try {
      final posParam = pos != null && pos.isNotEmpty ? '&pos=$pos' : '';
      final response = await http.get(
        Uri.parse('$_baseUrl/featured?${_params()}&limit=$limit&media_filter=gif,tinygif$posParam'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return GifSearchResult.empty();
      return GifSearchResult.fromJson(json.decode(response.body) as Map<String, dynamic>);
    } catch (_) {
      return GifSearchResult.empty();
    }
  }

  /// Autocomplete search suggestions
  Future<List<String>> autocomplete(String query, {int limit = 5}) async {
    if (query.trim().isEmpty) return [];
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/autocomplete?q=${Uri.encodeComponent(query)}&${_params()}&limit=$limit'),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) return [];
      final data = json.decode(response.body) as Map<String, dynamic>;
      return (data['results'] as List?)?.cast<String>() ?? [];
    } catch (_) {
      return [];
    }
  }

  /// Trending search terms
  Future<List<String>> trendingTerms({int limit = 10}) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/trending_terms?${_params()}&limit=$limit'),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) return [];
      final data = json.decode(response.body) as Map<String, dynamic>;
      return (data['results'] as List?)?.cast<String>() ?? [];
    } catch (_) {
      return [];
    }
  }

  /// GIF categories (for home screen tiles)
  Future<List<GifCategory>> categories() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/categories?${_params()}&type=featured'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return [];
      final data = json.decode(response.body) as Map<String, dynamic>;
      final tags = data['tags'] as List? ?? [];
      return tags.map((t) => GifCategory.fromJson(t as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }
}

/// Paginated search result
class GifSearchResult {
  final List<GifResult> results;
  final String? nextPos; // pagination token

  GifSearchResult({required this.results, this.nextPos});

  factory GifSearchResult.empty() => GifSearchResult(results: []);

  factory GifSearchResult.fromJson(Map<String, dynamic> json) {
    final results = (json['results'] as List? ?? [])
        .map((r) => GifResult.fromTenor(r as Map<String, dynamic>))
        .toList();
    return GifSearchResult(
      results: results,
      nextPos: json['next'] as String?,
    );
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

/// Tenor GIF category (for home grid)
class GifCategory {
  final String searchTerm;
  final String name;
  final String imageUrl;

  GifCategory({required this.searchTerm, required this.name, required this.imageUrl});

  factory GifCategory.fromJson(Map<String, dynamic> json) {
    return GifCategory(
      searchTerm: json['searchterm'] as String? ?? '',
      name: json['name'] as String? ?? json['searchterm'] as String? ?? '',
      imageUrl: json['image'] as String? ?? '',
    );
  }
}
