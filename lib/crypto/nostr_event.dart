import 'dart:convert';
import 'package:crypto/crypto.dart';

class NostrEvent {
  final String? id;
  final String pubkey;
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;
  final String? sig;

  NostrEvent({
    this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    this.sig,
  });

  /// Compute the event ID as SHA256 of the canonical serialization
  String computeId() {
    final serialized = json.encode([
      0,
      pubkey,
      createdAt,
      kind,
      tags,
      content,
    ]);
    final hash = sha256.convert(utf8.encode(serialized));
    return hash.toString();
  }

  /// Create a copy with the computed ID
  NostrEvent withComputedId() {
    return NostrEvent(
      id: computeId(),
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
      sig: sig,
    );
  }

  /// Create a copy with a signature
  NostrEvent withSignature(String signature) {
    return NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
      sig: signature,
    );
  }

  /// Serialize to JSON map (for relay transmission)
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'pubkey': pubkey,
      'created_at': createdAt,
      'kind': kind,
      'tags': tags,
      'content': content,
      'sig': sig,
    };
  }

  /// Parse from JSON map (from relay)
  factory NostrEvent.fromJson(Map<String, dynamic> json) {
    return NostrEvent(
      id: json['id'] as String?,
      pubkey: json['pubkey'] as String,
      createdAt: json['created_at'] as int,
      kind: json['kind'] as int,
      tags: (json['tags'] as List)
          .map((t) => (t as List).map((e) => e.toString()).toList())
          .toList(),
      content: json['content'] as String,
      sig: json['sig'] as String?,
    );
  }

  /// Build an EVENT message for relay transmission: ["EVENT", event]
  String toEventMessage() {
    return json.encode(['EVENT', toJson()]);
  }

  /// Get the current unix timestamp
  static int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
}
