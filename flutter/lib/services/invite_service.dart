import 'dart:math';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import '../crypto/bech32_nostr.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../database/database.dart';
import '../nostr/relay_pool.dart';
import '../nostr/nostr_filter.dart';
import 'server_sync_service.dart';

/// State of a resolved invite.
enum InviteState { valid, expired, revoked, maxedOut, notFound }

/// Result of resolving an invite code/URI.
class InviteResolution {
  final String code;
  final String nostrGroupId;
  final String? serverName;
  final String? description;
  final String? iconUrl;
  final String? naddr;
  final InviteState state;
  final int? maxUses;
  final int? usesCount;
  final DateTime? expiresAt;

  const InviteResolution({
    required this.code,
    required this.nostrGroupId,
    this.serverName,
    this.description,
    this.iconUrl,
    this.naddr,
    required this.state,
    this.maxUses,
    this.usesCount,
    this.expiresAt,
  });
}

// Regex patterns matching Rails Message model
final _njumpInviteRegex = RegExp(r'https?://njump\.me/(naddr1[a-z0-9]+)');
final _nostrInviteRegex = RegExp(r'nostr:(naddr1[a-z0-9]+)');
final _httpInviteRegex = RegExp(r'https?://[^/]+/inferno/invite/(?:(inferno-[a-zA-Z0-9-]+)/)?([a-zA-Z0-9]+)');

class InviteService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;

  InviteService(this._db, this._relayPool);

  // ── Code generation ──

  String _generateCode() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return List.generate(8, (_) => chars[random.nextInt(chars.length)]).join();
  }

  // ── Create ──

  Future<Invite> createInvite({
    required String privateKeyHex,
    required String publicKeyHex,
    required Server server,
    required int creatorId,
    int? maxUses,
    DateTime? expiresAt,
  }) async {
    final code = _generateCode();
    final now = DateTime.now();

    final id = await _db.into(_db.invites).insert(InvitesCompanion.insert(
      serverId: server.id,
      creatorId: creatorId,
      code: code,
      maxUses: Value(maxUses),
      expiresAt: Value(expiresAt),
      createdAt: now,
      updatedAt: now,
    ));

    // Publish Kind 31757 invite event (tags match Rails exactly)
    final gid = server.nostrGroupId ?? '';
    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 31757,
      tags: [
        ['d', 'inferno-invite-$gid-$code'],
        ['code', code],
        ['server', gid],
        ['max_uses', (maxUses ?? 0).toString()],
        ['expires_at', (expiresAt != null ? expiresAt.millisecondsSinceEpoch ~/ 1000 : 0).toString()],
        ['created_by', publicKeyHex],
        ['uses', '0'],
      ],
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    debugPrint('[InviteService] Publishing invite event:');
    debugPrint('[InviteService]   id: ${signed.id}');
    debugPrint('[InviteService]   pubkey: ${signed.pubkey}');
    debugPrint('[InviteService]   d-tag: inferno-invite-$gid-$code');
    debugPrint('[InviteService]   kind: 31757');
    final results = await _relayPool.publish(signed);
    debugPrint('[InviteService]   publish results: $results');

    // Log the generated link for debugging
    final relays = _relayPool.connectedRelayUrls;
    final naddr = Bech32Nostr.naddrEncode(
      identifier: 'inferno-invite-$gid-$code',
      kind: 31757,
      pubkey: publicKeyHex,
      relays: relays,
    );
    debugPrint('[InviteService]   njump link: https://njump.me/$naddr');
    debugPrint('[InviteService]   relay hints: $relays');

    return (_db.select(_db.invites)..where((i) => i.id.equals(id))).getSingle();
  }

  // ── Resolve ──

  /// Resolve an invite code to full resolution with state checking.
  Future<InviteResolution?> resolveInvite(String code, {String? nostrGroupId}) async {
    // Check local DB first
    final local = await (_db.select(_db.invites)
          ..where((i) => i.code.equals(code)))
        .getSingleOrNull();
    if (local != null) {
      final server = await (_db.select(_db.servers)
            ..where((s) => s.id.equals(local.serverId)))
          .getSingleOrNull();
      if (server != null) {
        return InviteResolution(
          code: code,
          nostrGroupId: server.nostrGroupId ?? '',
          serverName: server.name,
          description: server.description,
          iconUrl: server.iconUrl,
          state: _computeState(local),
          maxUses: local.maxUses,
          usesCount: local.usesCount,
          expiresAt: local.expiresAt,
        );
      }
    }

    // Search relays with correct d-tag format
    List<nostr.NostrEvent> events;
    if (nostrGroupId != null) {
      events = await _relayPool.fetch(
        NostrFilter(kinds: [31757], tags: {'#d': ['inferno-invite-$nostrGroupId-$code']}),
        timeout: const Duration(seconds: 8),
      );
    } else {
      // Without gid, try to find by iterating known servers
      final servers = await _db.select(_db.servers).get();
      events = [];
      for (final s in servers) {
        if (s.nostrGroupId == null) continue;
        final found = await _relayPool.fetch(
          NostrFilter(kinds: [31757], tags: {'#d': ['inferno-invite-${s.nostrGroupId}-$code']}),
          timeout: const Duration(seconds: 4),
        );
        if (found.isNotEmpty) { events = found; break; }
      }
      // Last resort: broad search
      if (events.isEmpty) {
        events = await _relayPool.fetch(
          NostrFilter(kinds: [31757]),
          timeout: const Duration(seconds: 6),
        );
        events = events.where((e) {
          final codeTag = e.tags.where((t) => t.isNotEmpty && t[0] == 'code').firstOrNull;
          return codeTag != null && codeTag.length > 1 && codeTag[1] == code;
        }).toList();
      }
    }

    if (events.isEmpty) return null;

    // Parse the best (most recent) event
    final event = events.reduce((a, b) => a.createdAt > b.createdAt ? a : b);
    return _parseEventToResolution(event, code);
  }

  /// Resolve an invite from any URI format (njump URL, nostr: URI, http URL, or raw code).
  Future<InviteResolution?> resolveInviteFromUri(String uri) async {
    final trimmed = uri.trim();

    // njump URL: https://njump.me/naddr1...
    var match = _njumpInviteRegex.firstMatch(trimmed);
    if (match != null) return _resolveFromNaddr(match.group(1)!);

    // nostr: URI: nostr:naddr1...
    match = _nostrInviteRegex.firstMatch(trimmed);
    if (match != null) return _resolveFromNaddr(match.group(1)!);

    // HTTP invite URL: /inferno/invite/{gid}/{code} or /inferno/invite/{code}
    match = _httpInviteRegex.firstMatch(trimmed);
    if (match != null) {
      final gid = match.group(1);
      final code = match.group(2)!;
      return resolveInvite(code, nostrGroupId: gid);
    }

    // Raw naddr string
    if (trimmed.startsWith('naddr1')) return _resolveFromNaddr(trimmed);

    // Raw invite code (8 alphanumeric chars)
    if (RegExp(r'^[a-z0-9]{8}$').hasMatch(trimmed)) {
      return resolveInvite(trimmed);
    }

    return null;
  }

  Future<InviteResolution?> _resolveFromNaddr(String naddr) async {
    try {
      final data = Bech32Nostr.naddrDecode(naddr);
      if (data.kind != 31757) return null;

      // Parse identifier: "inv-{publicId}-{code}" or "inferno-invite-{gid}-{code}"
      String? code;
      String? gid;
      final id = data.identifier;

      if (id.startsWith('inv-')) {
        // Compact format: inv-{serverPublicId}-{code}
        final parts = id.substring(4).split('-');
        if (parts.length >= 2) {
          code = parts.last;
          final serverPubId = parts.sublist(0, parts.length - 1).join('-');
          // Look up server by publicId to get nostrGroupId
          final server = await (_db.select(_db.servers)
                ..where((s) => s.publicId.equals(serverPubId)))
              .getSingleOrNull();
          gid = server?.nostrGroupId;
        }
      } else if (id.startsWith('inferno-invite-')) {
        // Legacy format: inferno-invite-{gid}-{code}
        final rest = id.substring('inferno-invite-'.length);
        final lastDash = rest.lastIndexOf('-');
        if (lastDash > 0) {
          gid = rest.substring(0, lastDash);
          code = rest.substring(lastDash + 1);
          // Ensure gid has inferno- prefix
          if (!gid.startsWith('inferno-')) gid = 'inferno-$gid';
        }
      }

      if (code == null) return null;

      final resolution = await resolveInvite(code, nostrGroupId: gid);
      if (resolution != null) return resolution;

      // If relay resolve failed, return a minimal resolution from the naddr itself
      return InviteResolution(
        code: code,
        nostrGroupId: gid ?? '',
        naddr: 'nostr:$naddr',
        state: InviteState.notFound,
      );
    } catch (e) {
      debugPrint('[InviteService] Failed to decode naddr: $e');
      return null;
    }
  }

  InviteResolution? _parseEventToResolution(nostr.NostrEvent event, String code) {
    String? getTag(String key) {
      final tag = event.tags.where((t) => t.isNotEmpty && t[0] == key).firstOrNull;
      return tag != null && tag.length > 1 ? tag[1] : null;
    }

    final serverGid = getTag('server');
    if (serverGid == null) return null;

    final revoked = getTag('revoked') == 'true';
    final maxUsesStr = getTag('max_uses');
    final usesStr = getTag('uses');
    final expiresStr = getTag('expires_at') ?? getTag('expires');

    final maxUses = maxUsesStr != null ? int.tryParse(maxUsesStr) : null;
    final usesCount = usesStr != null ? int.tryParse(usesStr) : null;
    final expiresUnix = expiresStr != null ? int.tryParse(expiresStr) : null;
    final expiresAt = (expiresUnix != null && expiresUnix > 0)
        ? DateTime.fromMillisecondsSinceEpoch(expiresUnix * 1000)
        : null;

    InviteState state;
    if (revoked) {
      state = InviteState.revoked;
    } else if (expiresAt != null && expiresAt.isBefore(DateTime.now())) {
      state = InviteState.expired;
    } else if (maxUses != null && maxUses > 0 && usesCount != null && usesCount >= maxUses) {
      state = InviteState.maxedOut;
    } else {
      state = InviteState.valid;
    }

    return InviteResolution(
      code: code,
      nostrGroupId: serverGid,
      state: state,
      maxUses: (maxUses != null && maxUses > 0) ? maxUses : null,
      usesCount: usesCount,
      expiresAt: expiresAt,
    );
  }

  InviteState _computeState(Invite invite) {
    if (!invite.active) return InviteState.revoked;
    if (invite.expiresAt != null && invite.expiresAt!.isBefore(DateTime.now())) return InviteState.expired;
    if (invite.maxUses != null && invite.usesCount >= invite.maxUses!) return InviteState.maxedOut;
    return InviteState.valid;
  }

  // ── Revoke ──

  Future<void> revokeInvite({
    required String privateKeyHex,
    required String publicKeyHex,
    required Invite invite,
    required Server server,
  }) async {
    // Deactivate locally
    await (_db.update(_db.invites)..where((i) => i.id.equals(invite.id)))
        .write(InvitesCompanion(active: const Value(false), updatedAt: Value(DateTime.now())));

    // Publish revocation event (matching Rails: only d, server, code, revoked)
    final gid = server.nostrGroupId ?? '';
    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 31757,
      tags: [
        ['d', 'inferno-invite-$gid-${invite.code}'],
        ['server', gid],
        ['code', invite.code],
        ['revoked', 'true'],
      ],
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    debugPrint('[InviteService] Revoking invite ${invite.code}, publishing to relays...');
    final results = await _relayPool.publish(signed);
    debugPrint('[InviteService] Revoke publish results: $results');
  }

  // ── Accept ──

  Future<Server?> acceptInvite({
    required String nostrGroupId,
    required int userId,
    required ServerSyncService syncService,
  }) async {
    final server = await syncService.syncServer(nostrGroupId);
    if (server == null) return null;

    final publicId = DateTime.now().millisecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
    try {
      await _db.into(_db.serverMemberships).insert(
        ServerMembershipsCompanion.insert(
          publicId: publicId,
          userId: userId,
          serverId: server.id,
          joinedAt: Value(DateTime.now()),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
    } catch (_) {
      // Membership may already exist
      debugPrint('[InviteService] Membership already exists');
    }

    return server;
  }

  // ── Inbound sync ──

  /// Process an inbound Kind 31757 event from relay subscription.
  Future<void> processInboundInvite(nostr.NostrEvent event, Server server) async {
    String? getTag(String key) {
      final tag = event.tags.where((t) => t.isNotEmpty && t[0] == key).firstOrNull;
      return tag != null && tag.length > 1 ? tag[1] : null;
    }

    final code = getTag('code');
    if (code == null || code.isEmpty) return;

    final revoked = getTag('revoked') == 'true';

    if (revoked) {
      // Deactivate local invite
      await (_db.update(_db.invites)..where((i) => i.code.equals(code)))
          .write(InvitesCompanion(active: const Value(false), updatedAt: Value(DateTime.now())));
      return;
    }

    final maxUsesStr = getTag('max_uses');
    final usesStr = getTag('uses');
    final expiresStr = getTag('expires_at') ?? getTag('expires');
    final createdBy = getTag('created_by');

    final maxUses = maxUsesStr != null ? int.tryParse(maxUsesStr) : null;
    final usesCount = usesStr != null ? int.tryParse(usesStr) : null;
    final expiresUnix = expiresStr != null ? int.tryParse(expiresStr) : null;
    final expiresAt = (expiresUnix != null && expiresUnix > 0)
        ? DateTime.fromMillisecondsSinceEpoch(expiresUnix * 1000)
        : null;

    // Resolve creator ID from pubkey
    int creatorId = 0;
    if (createdBy != null && createdBy.isNotEmpty) {
      final creator = await (_db.select(_db.users)
            ..where((u) => u.nostrPublicKey.equals(createdBy)))
          .getSingleOrNull();
      if (creator != null) creatorId = creator.id;
    }

    // Check-then-insert/update (avoid Drift upsert issues with non-PK unique constraints)
    final existing = await (_db.select(_db.invites)
          ..where((i) => i.code.equals(code)))
        .getSingleOrNull();
    final now = DateTime.now();

    if (existing != null) {
      await (_db.update(_db.invites)..where((i) => i.id.equals(existing.id))).write(InvitesCompanion(
        maxUses: Value((maxUses != null && maxUses > 0) ? maxUses : null),
        usesCount: Value(usesCount ?? existing.usesCount),
        expiresAt: Value(expiresAt),
        active: const Value(true),
        updatedAt: Value(now),
      ));
    } else {
      await _db.into(_db.invites).insert(InvitesCompanion.insert(
        serverId: server.id,
        creatorId: creatorId,
        code: code,
        maxUses: Value((maxUses != null && maxUses > 0) ? maxUses : null),
        expiresAt: Value(expiresAt),
        createdAt: now,
        updatedAt: now,
      ));
      // Update uses count after insert
      if (usesCount != null && usesCount > 0) {
        await (_db.update(_db.invites)..where((i) => i.code.equals(code)))
            .write(InvitesCompanion(usesCount: Value(usesCount)));
      }
    }
  }

  // ── Link generation ──

  /// Generate a single shareable njump link that works everywhere.
  /// Generate the shareable invite link.
  /// Returns `https://njump.me/naddr1...` for external sharing (Discord rich embeds via OG tags).
  /// The naddr identifier matches the event d-tag exactly so njump can find the event.
  String generateInviteLink({
    required Invite invite,
    required Server server,
    required String creatorPubkey,
  }) {
    final relays = _relayPool.connectedRelayUrls;
    final gid = server.nostrGroupId ?? '';
    final naddr = Bech32Nostr.naddrEncode(
      identifier: 'inferno-invite-$gid-${invite.code}',
      kind: 31757,
      pubkey: creatorPubkey,
      relays: relays,
    );
    return 'https://njump.me/$naddr';
  }

  // ── Streams ──

  /// Watch all invites for a server (live updates for settings panel).
  Stream<List<Invite>> watchInvites(int serverId) {
    return (_db.select(_db.invites)
          ..where((i) => i.serverId.equals(serverId))
          ..orderBy([(i) => OrderingTerm.desc(i.createdAt)]))
        .watch();
  }

  // ── Detection helpers ──

  /// Check if a string contains an invite link/URI. Returns the matched string or null.
  static String? detectInviteUri(String text) {
    var match = _njumpInviteRegex.firstMatch(text);
    if (match != null) return match.group(0);
    match = _nostrInviteRegex.firstMatch(text);
    if (match != null) return match.group(0);
    match = _httpInviteRegex.firstMatch(text);
    if (match != null) return match.group(0);
    return null;
  }
}
