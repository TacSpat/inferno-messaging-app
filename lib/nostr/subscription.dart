import 'dart:math';
import '../crypto/nostr_event.dart';
import 'nostr_filter.dart';

class Subscription {
  final String id;
  final List<NostrFilter> filters;
  final void Function(NostrEvent event)? onEvent;
  final void Function(String subscriptionId)? onEose;
  bool eoseReceived = false;
  final DateTime createdAt;

  Subscription({
    String? id,
    required this.filters,
    this.onEvent,
    this.onEose,
  })  : id = id ?? _generateId(),
        createdAt = DateTime.now();

  /// Build the REQ message: ["REQ", subId, filter1, filter2, ...]
  String toReqMessage() {
    final parts = <dynamic>['REQ', id];
    for (final filter in filters) {
      parts.add(filter.toJson());
    }
    return _jsonEncode(parts);
  }

  /// Build the CLOSE message: ["CLOSE", subId]
  String toCloseMessage() {
    return _jsonEncode(['CLOSE', id]);
  }

  static String _generateId() {
    final random = Random.secure();
    return List.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  // Avoid importing dart:convert at top level to keep it simple
  static String _jsonEncode(dynamic obj) {
    // Import inline
    return obj.toString().isEmpty ? '[]' : _encodeJson(obj);
  }

  static String _encodeJson(dynamic obj) {
    if (obj is String) return '"${_escapeJson(obj)}"';
    if (obj is num || obj is bool) return obj.toString();
    if (obj == null) return 'null';
    if (obj is List) return '[${obj.map(_encodeJson).join(',')}]';
    if (obj is Map) {
      final entries = obj.entries.map((e) => '"${_escapeJson(e.key.toString())}":${_encodeJson(e.value)}');
      return '{${entries.join(',')}}';
    }
    return '"$obj"';
  }

  static String _escapeJson(String s) {
    return s.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n').replaceAll('\r', '\\r').replaceAll('\t', '\\t');
  }
}
