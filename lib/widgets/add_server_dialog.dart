import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../database/database.dart';
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import '../providers/servers_provider.dart';
import '../services/role_service.dart';
import '../nostr/nostr_filter.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../theme/all_themes.dart';

// Session-level cache for discovered servers (relay only sends events once per connection)
List<Map<String, dynamic>>? _discoveryCache;

/// Channel templates per server type — keys are category names, values are channel names.
/// Prefix ~ means voice channel. '_root' means no category.
const _channelTemplates = <String, Map<String, List<String>>>{
  'community': {
    'Text Channels': ['general', 'off-topic', 'introductions'],
    'Voice Channels': ['~General', '~Chill'],
  },
  'gaming': {
    'General': ['general', 'looking-for-group', 'clips-and-highlights'],
    'Voice': ['~Lobby', '~Game 1', '~Game 2', '~AFK'],
  },
  'work_team': {
    'General': ['general', 'announcements', 'resources'],
    'Projects': ['project-a', 'project-b'],
    'Voice': ['~Meeting Room', '~Water Cooler'],
  },
  'friends_family': {
    '_root': ['general', 'photos', 'plans'],
    'Voice': ['~Hangout'],
  },
  'adult': {
    'General': ['general', 'introductions', 'nsfw'],
    'Voice': ['~Lounge'],
  },
};

class AddServerDialog extends ConsumerStatefulWidget {
  const AddServerDialog({super.key});

  @override
  ConsumerState<AddServerDialog> createState() => _AddServerDialogState();
}

class _AddServerDialogState extends ConsumerState<AddServerDialog> {
  final _inviteController = TextEditingController();
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  String _serverType = 'community';
  bool _loading = false;
  String? _error;
  List<Map<String, dynamic>> _discoveredServers = [];
  bool _discovering = false;
  // Pre-fetched events from discovery for use during join
  List<nostr.NostrEvent> _metadataEvents = [];
  List<nostr.NostrEvent> _structEvents = [];
  List<nostr.NostrEvent> _roleEvents = [];

  @override
  void initState() {
    super.initState();
    _discoverServers();
  }

  @override
  void dispose() {
    _inviteController.dispose();
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  /// Fetch Kind 31750 server metadata from relays, filter by discoverable=true.
  /// Matches Rails ServersController#discover
  Future<void> _discoverServers() async {
    setState(() => _discovering = true);
    try {
      final pool = ref.read(relayPoolProvider);
      final db = ref.read(databaseProvider);

      // Check relay connectivity
      final connectedCount = pool.connectedCount;
      debugPrint('[Discovery] Connected relays: $connectedCount');

      if (connectedCount == 0) {
        // Try to reconnect
        debugPrint('[Discovery] No relays connected, cannot discover servers');
        if (mounted) setState(() { _discoveredServers = []; _discovering = false; });
        return;
      }

      // Fetch ALL server event kinds at once (31750 metadata, 31751 structure, 31752 roles)
      // Do this upfront because relays won't re-send after first delivery
      final allEvents = await pool.fetch(
        NostrFilter(kinds: [31750, 31751, 31752], limit: 200),
        timeout: const Duration(seconds: 10),
      );

      // Separate by kind and cache for sync service
      final events = allEvents.where((e) => e.kind == 31750).toList();
      final structEvents = allEvents.where((e) => e.kind == 31751).toList();
      final roleEvents = allEvents.where((e) => e.kind == 31752).toList();
      debugPrint('[Discovery] Fetched ${events.length} metadata, ${structEvents.length} structure, ${roleEvents.length} role events');

      // Store for use during join (relay won't re-send these)
      _metadataEvents = events;
      _structEvents = structEvents;
      _roleEvents = roleEvents;

      // Parse events into server cards
      if (events.isNotEmpty) {
        final parsed = <Map<String, dynamic>>[];
        for (final event in events) {
          final tags = event.tags;
          String? getTag(String key) {
            final tag = tags.where((t) => t.isNotEmpty && t[0] == key).firstOrNull;
            return tag != null && tag.length > 1 ? tag[1] : null;
          }

          if (getTag('discoverable') != 'true') continue;
          if (getTag('deleted') == 'true') continue;

          final dTag = getTag('d');
          if (dTag == null) continue;

          parsed.add({
            'nostr_group_id': dTag,
            'name': getTag('name') ?? 'Unknown Server',
            'description': getTag('about'),
            'icon_url': getTag('picture'),
            'server_type': getTag('server_type'),
            'age_restricted': getTag('age_restricted') == 'true',
            'pubkey': event.pubkey,
          });
        }

        // Dedup and cache
        final seen = <String>{};
        _discoveryCache = parsed.where((s) {
          final gid = s['nostr_group_id'] as String;
          if (seen.contains(gid)) return false;
          seen.add(gid);
          return true;
        }).toList();
      }

      // Filter out servers where user has an active membership
      final memberships = await db.select(db.serverMemberships).get();
      final memberServerIds = memberships.map((m) => m.serverId).toSet();
      final allServers = await db.select(db.servers).get();
      final joinedGids = allServers
          .where((s) => s.nostrGroupId != null && memberServerIds.contains(s.id))
          .map((s) => s.nostrGroupId!)
          .toSet();

      final available = (_discoveryCache ?? [])
          .where((s) => !joinedGids.contains(s['nostr_group_id'] as String))
          .toList();

      if (mounted) setState(() { _discoveredServers = available; _discovering = false; });
    } catch (_) {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _joinDiscoveredServer(Map<String, dynamic> server) async {
    final serverName = server['name'] as String;
    final gid = (server['nostr_group_id'] as String).replaceAll(RegExp(r'^(inferno-)+'), 'inferno-');

    // Show the sync progress overlay (replaces the add server dialog)
    if (!mounted) return;
    final nav = Navigator.of(context);
    final router = GoRouter.of(context);

    // Replace current dialog with sync overlay
    nav.pop(); // close add server dialog
    final publicId = await showDialog<String>(
      context: nav.context,
      barrierDismissible: false,
      builder: (_) {
        // Filter pre-fetched events for this specific server
        var baseId = gid;
        while (baseId.startsWith('inferno-')) baseId = baseId.substring(8);
        final metadataForServer = _metadataEvents.where((e) {
          final dTag = e.tags.where((t) => t.isNotEmpty && t[0] == 'd').firstOrNull;
          return dTag != null && dTag.length > 1 && dTag[1].contains(baseId);
        }).toList();
        final structForServer = _structEvents.where((e) {
          final dTag = e.tags.where((t) => t.isNotEmpty && t[0] == 'd').firstOrNull;
          return dTag != null && dTag.length > 1 && dTag[1].contains(baseId);
        }).toList();
        final rolesForServer = _roleEvents.where((e) {
          final dTag = e.tags.where((t) => t.isNotEmpty && t[0] == 'd').firstOrNull;
          return dTag != null && dTag.length > 1 && dTag[1].contains(baseId);
        }).toList();
        debugPrint('[JoinSync] Passing ${metadataForServer.length} metadata, ${structForServer.length} structure, ${rolesForServer.length} role events for $baseId');
        return _ServerSyncOverlay(
          serverName: serverName,
          serverData: server,
          gid: gid,
          preloadedMetadata: metadataForServer,
          preloadedStructure: structForServer,
          preloadedRoles: rolesForServer,
        );
      },
    );

    if (publicId != null) {
      router.go('/servers/$publicId');
    }
  }

  Future<void> _createServer() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) { setState(() => _error = 'Server name is required'); return; }
    setState(() { _loading = true; _error = null; });

    try {
      final db = ref.read(databaseProvider);
      final now = DateTime.now();
      final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
      final nostrGroupId = 'inferno-$publicId';

      final serverId = await db.into(db.servers).insert(ServersCompanion.insert(
        publicId: publicId, ownerId: 1, name: name,
        description: Value(_descController.text.trim().isNotEmpty ? _descController.text.trim() : null),
        nostrGroupId: Value(nostrGroupId),
        serverType: Value(_serverType),
        createdAt: now, updatedAt: now,
      ));

      // Apply channel template based on server type (matches Rails Server.apply_server_template!)
      final template = _channelTemplates[_serverType] ?? _channelTemplates['community']!;
      int catPos = 0;
      for (final catEntry in template.entries) {
        final catName = catEntry.key;
        int? categoryId;
        // Create category (skip for uncategorized channels)
        if (catName != '_root') {
          final catPubId = (now.microsecondsSinceEpoch + catPos + 100).toRadixString(36).padLeft(12, '0').substring(0, 12);
          categoryId = await db.into(db.categories).insert(CategoriesCompanion.insert(
            publicId: catPubId, serverId: serverId, name: Value(catName),
            position: Value(catPos), createdAt: now, updatedAt: now,
          ));
          catPos++;
        }
        int chPos = 0;
        for (final ch in catEntry.value) {
          final chPubId = (now.microsecondsSinceEpoch + catPos * 10 + chPos + 1).toRadixString(36).padLeft(12, '0').substring(0, 12);
          final isVoice = ch.startsWith('~'); // prefix ~ = voice channel
          final chName = isVoice ? ch.substring(1) : ch;
          await db.into(db.channels).insert(ChannelsCompanion.insert(
            publicId: chPubId, serverId: serverId, name: chName,
            channelType: isVoice ? 1 : 0,
            position: Value(chPos), categoryId: Value(categoryId),
            nostrGroupId: Value('$nostrGroupId-$chPubId'),
            createdAt: now, updatedAt: now,
          ));
          chPos++;
        }
      }

      await RoleService(db).createDefaultRoles(serverId);
      final memId = now.microsecondsSinceEpoch.toRadixString(36).padRight(12, '0').substring(0, 12);
      await db.into(db.serverMemberships).insert(ServerMembershipsCompanion.insert(
        publicId: memId, userId: 1, serverId: serverId,
        joinedAt: Value(now), createdAt: now, updatedAt: now,
      ));

      // Publish our membership and profile to relays so we appear via normal sync
      // (no direct DB insert — let relay sync discover us like any other member)
      final auth = ref.read(authServiceProvider);

      // Publish to Nostr
      final serverPublish = ref.read(serverPublishServiceProvider);
      if (auth.privateKeyHex != null) {
        final newServer = await (db.select(db.servers)..where((s) => s.id.equals(serverId))).getSingle();
        await serverPublish.publishMetadata(
          privateKeyHex: auth.privateKeyHex!,
          publicKeyHex: auth.publicKeyHex!,
          server: newServer,
        );
        await serverPublish.publishStructure(
          privateKeyHex: auth.privateKeyHex!,
          publicKeyHex: auth.publicKeyHex!,
          server: newServer,
        );
      }

      if (mounted) Navigator.pop(context, publicId);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<InfernoColors>()!;

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 440,
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        decoration: BoxDecoration(
          color: c.gray800,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Row(
                  children: [
                    Text('Add a Server', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        width: 32, height: 32,
                        decoration: BoxDecoration(color: c.gray700, shape: BoxShape.circle),
                        child: Icon(Icons.close, size: 16, color: c.gray400),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // === JOIN ===
                Text('Enter an invite link or server ID to join', style: TextStyle(color: c.gray400, fontSize: 14)),
                const SizedBox(height: 12),
                TextField(
                  controller: _inviteController,
                  style: TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Paste invite link or server ID...',
                    hintStyle: TextStyle(color: c.gray500),
                    fillColor: c.gray900,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent.withValues(alpha: 0.5))),
                  ),
                ),
                const SizedBox(height: 20),

                // === DISCOVER ===
                _Divider('Discover', c),
                const SizedBox(height: 8),
                Text('SERVERS ON YOUR RELAYS', style: TextStyle(color: c.gray500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                const SizedBox(height: 8),
                if (_discovering)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: c.gray400))),
                  )
                else if (_discoveredServers.isEmpty)
                  GestureDetector(
                    onTap: _discoverServers,
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Icon(Icons.search, size: 40, color: c.gray500),
                          const SizedBox(height: 8),
                          Text('No servers found on your relays', style: TextStyle(color: c.gray400, fontSize: 14)),
                          Text('Tap to retry', style: TextStyle(color: c.accent, fontSize: 12)),
                        ],
                      ),
                    ),
                  )
                else
                  ...List.generate(_discoveredServers.length, (i) {
                    final server = _discoveredServers[i];
                    return _DiscoverServerItem(
                      server: server,
                      colors: c,
                      onJoin: () => _joinDiscoveredServer(server),
                    );
                  }),
                const SizedBox(height: 16),

                // === CREATE ===
                _Divider('Or create your own', c),
                const SizedBox(height: 12),

                // Icon + Name + Description
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Icon placeholder
                    Container(
                      width: 56, height: 56,
                      decoration: BoxDecoration(
                        color: c.gray900,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: c.gray600, style: BorderStyle.solid),
                      ),
                      child: Icon(Icons.add_photo_alternate, size: 24, color: c.gray500),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        children: [
                          TextField(
                            controller: _nameController,
                            style: TextStyle(color: Colors.white, fontSize: 14),
                            decoration: InputDecoration(
                              hintText: 'Server name',
                              hintStyle: TextStyle(color: c.gray500),
                              fillColor: c.gray900,
                              isDense: true,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent.withValues(alpha: 0.5))),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _descController,
                            maxLines: 2,
                            style: TextStyle(color: Colors.white, fontSize: 14),
                            decoration: InputDecoration(
                              hintText: 'Description (optional)',
                              hintStyle: TextStyle(color: c.gray500),
                              fillColor: c.gray900,
                              isDense: true,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent.withValues(alpha: 0.5))),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Server type
                Text('SERVER TYPE', style: TextStyle(color: c.gray500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6, runSpacing: 6,
                  children: [
                    _TypeCard('Community', 'community', Icons.people, c.accent, c),
                    _TypeCard('Friends', 'friends_family', Icons.home, const Color(0xFF16A34A), c),
                    _TypeCard('Gaming', 'gaming', Icons.sports_esports, const Color(0xFF7C3AED), c),
                    _TypeCard('Work', 'work_team', Icons.work, const Color(0xFF2563EB), c),
                    _TypeCard('18+', 'adult', Icons.warning_amber, c.accent, c),
                  ],
                ),

                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: c.accent, fontSize: 13)),
                ],
                const SizedBox(height: 16),

                SizedBox(
                  height: 44,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _createServer,
                    child: _loading
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Create Server', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _TypeCard(String label, String type, IconData icon, Color color, InfernoColors c) {
    final selected = _serverType == type;
    return GestureDetector(
      onTap: () => setState(() => _serverType = type),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? c.accent.withValues(alpha: 0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? c.accent.withValues(alpha: 0.6) : c.gray700.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(
              color: selected ? Colors.white : c.gray400,
              fontSize: 12, fontWeight: FontWeight.w500,
            )),
          ],
        ),
      ),
    );
  }

  Widget _Divider(String label, InfernoColors c) {
    return Row(
      children: [
        Expanded(child: Container(height: 1, color: c.gray700.withValues(alpha: 0.5))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(label.toUpperCase(), style: TextStyle(color: c.gray500, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
        ),
        Expanded(child: Container(height: 1, color: c.gray700.withValues(alpha: 0.5))),
      ],
    );
  }
}

class _DiscoverServerItem extends StatefulWidget {
  final Map<String, dynamic> server;
  final InfernoColors colors;
  final VoidCallback onJoin;
  const _DiscoverServerItem({required this.server, required this.colors, required this.onJoin});

  @override
  State<_DiscoverServerItem> createState() => _DiscoverServerItemState();
}

class _DiscoverServerItemState extends State<_DiscoverServerItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final s = widget.server;
    final name = s['name'] as String? ?? 'Unknown';
    final desc = s['description'] as String?;
    final iconUrl = s['icon_url'] as String?;
    final ageRestricted = s['age_restricted'] == true;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onJoin,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          margin: const EdgeInsets.only(bottom: 4),
          decoration: BoxDecoration(
            gradient: _hovering ? LinearGradient(colors: [c.accent.withValues(alpha: 0.08), Colors.transparent]) : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              // Server icon
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: c.gray600,
                  borderRadius: BorderRadius.circular(10),
                  image: iconUrl != null ? DecorationImage(image: NetworkImage(iconUrl), fit: BoxFit.cover) : null,
                ),
                child: iconUrl == null
                    ? Center(child: Text(name[0].toUpperCase(), style: TextStyle(color: c.gray200, fontWeight: FontWeight.bold, fontSize: 16)))
                    : null,
              ),
              const SizedBox(width: 12),
              // Server info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(name, style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                            overflow: TextOverflow.ellipsis),
                        ),
                        if (ageRestricted) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(color: c.accent.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(3)),
                            child: Text('18+', style: TextStyle(color: c.accent, fontSize: 10, fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ],
                    ),
                    if (desc != null && desc.isNotEmpty)
                      Text(desc, style: TextStyle(color: c.gray500, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              if (_hovering)
                Icon(Icons.arrow_forward_ios, size: 14, color: c.gray400),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-screen sync progress overlay shown while joining a server.
class _ServerSyncOverlay extends ConsumerStatefulWidget {
  final String serverName;
  final Map<String, dynamic> serverData;
  final String gid;
  final List<nostr.NostrEvent>? preloadedMetadata;
  final List<nostr.NostrEvent>? preloadedStructure;
  final List<nostr.NostrEvent>? preloadedRoles;

  const _ServerSyncOverlay({
    required this.serverName,
    required this.serverData,
    required this.gid,
    this.preloadedMetadata,
    this.preloadedStructure,
    this.preloadedRoles,
  });

  @override
  ConsumerState<_ServerSyncOverlay> createState() => _ServerSyncOverlayState();
}

class _ServerSyncOverlayState extends ConsumerState<_ServerSyncOverlay> {
  String _step = 'Connecting...';
  double _progress = 0.0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _runSync();
  }

  Future<void> _runSync() async {
    try {
      final db = ref.read(databaseProvider);
      final now = DateTime.now();
      var publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);

      _updateStep('Creating server record...', 0.05);
      final cleanGid = widget.gid.replaceAll(RegExp(r'^(inferno-)+'), 'inferno-');
      debugPrint('[JoinSync] gid=${widget.gid} cleanGid=$cleanGid');

      // Check if server already exists (cached from previous join)
      var existingServer = await (db.select(db.servers)
            ..where((s) => s.nostrGroupId.equals(cleanGid)))
          .getSingleOrNull();

      int serverId;
      if (existingServer != null) {
        serverId = existingServer.id;
        publicId = existingServer.publicId;
        debugPrint('[JoinSync] Reusing cached server id=$serverId');
      } else {
        serverId = await db.into(db.servers).insert(ServersCompanion.insert(
          publicId: publicId,
          ownerId: 0,
          name: widget.serverData['name'] as String,
          description: Value(widget.serverData['description'] as String?),
          iconUrl: Value(widget.serverData['icon_url'] as String?),
          nostrGroupId: Value(cleanGid),
          serverType: Value(widget.serverData['server_type'] as String? ?? 'community'),
          createdAt: now,
          updatedAt: now,
        ));
        debugPrint('[JoinSync] Created new server id=$serverId');
      }

      // Create membership (may already exist)
      try {
        await db.into(db.serverMemberships).insert(ServerMembershipsCompanion.insert(
          publicId: (now.microsecondsSinceEpoch + 1).toRadixString(36).padLeft(12, '0').substring(0, 12),
          userId: 1, serverId: serverId,
          joinedAt: Value(now), createdAt: now, updatedAt: now,
        ));
      } catch (_) {
        debugPrint('[JoinSync] Membership already exists');
      }

      // Step 1: Use the pre-fetched events from discovery (relay won't re-send)
      _updateStep('Preparing...', 0.05);

      // Step 2: Publish our membership so other clients see us
      final auth = ref.read(authServiceProvider);
      final serverPublish = ref.read(serverPublishServiceProvider);
      if (auth.privateKeyHex != null) {
        final newServer = await (db.select(db.servers)..where((s) => s.nostrGroupId.equals(widget.gid))).getSingleOrNull();
        if (newServer != null) {
          await serverPublish.publishMember(
            privateKeyHex: auth.privateKeyHex!,
            publicKeyHex: auth.publicKeyHex!,
            server: newServer,
          );
        }
      }

      // Pass pre-loaded events from discovery to sync service
      // This is critical: relays may not re-send events that were already delivered
      final syncService = ref.read(serverSyncServiceProvider);
      if (widget.preloadedMetadata != null && widget.preloadedMetadata!.isNotEmpty) {
        syncService.preloadedMetadata = widget.preloadedMetadata;
      }
      if (widget.preloadedStructure != null && widget.preloadedStructure!.isNotEmpty) {
        syncService.preloadedStructure = widget.preloadedStructure;
      }
      if (widget.preloadedRoles != null && widget.preloadedRoles!.isNotEmpty) {
        syncService.preloadedRoles = widget.preloadedRoles;
      }

      // Run sync with real progress callbacks
      final result = await syncService.syncServer(
        cleanGid,
        onProgress: (step, progress) {
          if (mounted) _updateStep(step, progress);
        },
      );

      // If sync couldn't fetch metadata (relay already sent events), that's OK —
      // the server record was already created with the discovery data.
      // Just load the server from DB.
      if (result == null) {
        // Server record exists from the insert above, try to load it
        final existingServer = await (db.select(db.servers)
              ..where((s) => s.nostrGroupId.equals(widget.gid)))
            .getSingleOrNull();
        if (existingServer == null) {
          if (mounted) setState(() { _error = 'Could not find server on relays'; _step = 'Failed'; });
          return;
        }
        // At minimum we have the server — sync what we can
        _updateStep('Done!', 1.0);
      }

      await Future.delayed(const Duration(milliseconds: 300));
      if (mounted) Navigator.pop(context, publicId);
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _step = 'Failed'; });
    }
  }

  void _updateStep(String step, double progress) {
    if (mounted) setState(() { _step = step; _progress = progress; });
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<InfernoColors>()!;

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: c.gray800,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                color: c.gray700,
                borderRadius: BorderRadius.circular(16),
                image: widget.serverData['icon_url'] != null
                    ? DecorationImage(image: NetworkImage(widget.serverData['icon_url'] as String), fit: BoxFit.cover)
                    : null,
              ),
              child: widget.serverData['icon_url'] == null
                  ? Center(child: Text(widget.serverName[0].toUpperCase(), style: TextStyle(color: c.gray200, fontSize: 28, fontWeight: FontWeight.bold)))
                  : null,
            ),
            const SizedBox(height: 16),
            Text('Joining ${widget.serverName}', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            if (_error != null) ...[
              Icon(Icons.error_outline, size: 32, color: c.accent),
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: c.accent, fontSize: 13), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Close', style: TextStyle(color: c.gray400)),
              ),
            ] else ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _progress,
                  backgroundColor: c.gray700,
                  valueColor: AlwaysStoppedAnimation<Color>(c.accent),
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 12),
              Text(_step, style: TextStyle(color: c.gray400, fontSize: 14)),
              const SizedBox(height: 4),
              Text('${(_progress * 100).toInt()}%', style: TextStyle(color: c.gray500, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}
