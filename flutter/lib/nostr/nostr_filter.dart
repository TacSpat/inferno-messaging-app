import 'dart:convert';

class NostrFilter {
  final List<int>? kinds;
  final List<String>? authors;
  final List<String>? ids;
  final int? since;
  final int? until;
  final int? limit;
  // Tag filters: #e, #p, #h, #d, etc.
  final Map<String, List<String>> tags;

  NostrFilter({
    this.kinds,
    this.authors,
    this.ids,
    this.since,
    this.until,
    this.limit,
    Map<String, List<String>>? tags,
  }) : tags = tags ?? {};

  /// Convenience: filter by #p tag (recipient pubkey)
  factory NostrFilter.byRecipient(String pubkey, {List<int>? kinds, int? since, int? limit}) {
    return NostrFilter(kinds: kinds, since: since, limit: limit, tags: {'#p': [pubkey]});
  }

  /// Convenience: filter by #h tag (group/channel ID)
  factory NostrFilter.byGroup(String groupId, {List<int>? kinds, int? since, int? limit}) {
    return NostrFilter(kinds: kinds, since: since, limit: limit, tags: {'#h': [groupId]});
  }

  /// Convenience: filter by #d tag (replaceable event identifier)
  factory NostrFilter.byDTag(String dTag, {List<int>? kinds, int? since, int? limit}) {
    return NostrFilter(kinds: kinds, since: since, limit: limit, tags: {'#d': [dTag]});
  }

  /// Convenience: filter by authors
  factory NostrFilter.byAuthors(List<String> authors, {List<int>? kinds, int? since, int? limit}) {
    return NostrFilter(kinds: kinds, authors: authors, since: since, limit: limit);
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{};
    if (kinds != null && kinds!.isNotEmpty) map['kinds'] = kinds;
    if (authors != null && authors!.isNotEmpty) map['authors'] = authors;
    if (ids != null && ids!.isNotEmpty) map['ids'] = ids;
    if (since != null) map['since'] = since;
    if (until != null) map['until'] = until;
    if (limit != null) map['limit'] = limit;
    for (final entry in tags.entries) {
      map[entry.key] = entry.value;
    }
    return map;
  }

  @override
  String toString() => json.encode(toJson());
}
