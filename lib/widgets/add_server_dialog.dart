import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../database/database.dart';
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import '../providers/servers_provider.dart';
import '../services/role_service.dart';
import '../services/invite_service.dart';
import '../nostr/nostr_filter.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../theme/all_themes.dart';
import '../theme/theme_provider.dart';

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
  // Invite resolution
  InviteResolution? _inviteResolution;
  bool _resolving = false;

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

      // Fetch ALL server event kinds at once (31750 metadata, 31751 structure, 31752 roles).
      // Use fetchFresh — opens a brand new WebSocket per relay so we always get
      // the latest replaceable events. The existing subscription may have already
      // received an older version and relays will not resend on the same sub.
      final allEvents = await pool.fetchFresh(
        NostrFilter(kinds: [31750, 31751, 31752], limit: 200),
        timeout: const Duration(seconds: 10),
      );

      // Separate by kind and keep only the latest version of each replaceable event.
      // Parameterized replaceable events are keyed by (kind, pubkey, d-tag) — if we
      // got multiple from different relays (or a stale one races a fresh one),
      // use the highest created_at.
      List<nostr.NostrEvent> latestByDTag(Iterable<nostr.NostrEvent> list) {
        final latest = <String, nostr.NostrEvent>{};
        for (final e in list) {
          final dTagRow = e.tags.firstWhere(
            (t) => t.isNotEmpty && t[0] == 'd',
            orElse: () => const [],
          );
          if (dTagRow.length < 2) continue;
          final dTag = dTagRow[1];
          final key = '${e.pubkey}:$dTag';
          final existing = latest[key];
          if (existing == null || e.createdAt > existing.createdAt) {
            latest[key] = e;
          }
        }
        return latest.values.toList();
      }

      final events = latestByDTag(allEvents.where((e) => e.kind == 31750));
      final structEvents = latestByDTag(allEvents.where((e) => e.kind == 31751));
      final roleEvents = latestByDTag(allEvents.where((e) => e.kind == 31752));
      debugPrint('[Discovery] Fetched ${events.length} metadata, ${structEvents.length} structure, ${roleEvents.length} role events (latest of each d-tag)');

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

      // Mark servers the user has already joined so the catalog can show
      // them as "Joined" without offering a re-join action. Normalize GIDs
      // to strip the double inferno- prefix that varies between sources.
      String normalizeGid(String gid) {
        var s = gid;
        while (s.startsWith('inferno-')) s = s.substring(8);
        return s; // raw ID without any prefix
      }

      final allServers = await db.select(db.servers).get();
      final joinedRawIds = allServers
          .where((s) => s.nostrGroupId != null)
          .map((s) => normalizeGid(s.nostrGroupId!))
          .toSet();

      final all = (_discoveryCache ?? []).map((s) {
        final gid = s['nostr_group_id'] as String;
        return {...s, 'joined': joinedRawIds.contains(normalizeGid(gid))};
      }).toList();

      // Sort: unjoined first, then joined
      all.sort((a, b) {
        final aj = a['joined'] == true ? 1 : 0;
        final bj = b['joined'] == true ? 1 : 0;
        return aj.compareTo(bj);
      });

      if (mounted) setState(() { _discoveredServers = all; _discovering = false; });
    } catch (_) {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _resolveInvite() async {
    final text = _inviteController.text.trim();
    if (text.isEmpty) return;
    setState(() { _resolving = true; _inviteResolution = null; _error = null; });

    try {
      final inviteService = ref.read(inviteServiceProvider);
      final resolution = await inviteService.resolveInviteFromUri(text);
      if (!mounted) return;
      if (resolution == null) {
        setState(() { _resolving = false; _error = 'Could not find invite'; });
      } else {
        // Try to fetch server name from metadata if not in resolution
        String? serverName = resolution.serverName;
        String? iconUrl = resolution.iconUrl;
        if (serverName == null && resolution.nostrGroupId.isNotEmpty) {
          final server = await (ref.read(databaseProvider).select(ref.read(databaseProvider).servers)
                ..where((s) => s.nostrGroupId.equals(resolution.nostrGroupId)))
              .getSingleOrNull();
          serverName = server?.name;
          iconUrl = server?.iconUrl;
        }
        setState(() {
          _resolving = false;
          _inviteResolution = InviteResolution(
            code: resolution.code,
            nostrGroupId: resolution.nostrGroupId,
            serverName: serverName ?? resolution.serverName,
            description: resolution.description,
            iconUrl: iconUrl ?? resolution.iconUrl,
            naddr: resolution.naddr,
            state: resolution.state,
            maxUses: resolution.maxUses,
            usesCount: resolution.usesCount,
            expiresAt: resolution.expiresAt,
          );
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _resolving = false; _error = 'Failed to resolve invite: $e'; });
    }
  }

  Future<void> _acceptResolvedInvite() async {
    final res = _inviteResolution;
    if (res == null || res.state != InviteState.valid) return;

    final nav = Navigator.of(context);
    final router = GoRouter.of(context);
    nav.pop(); // close dialog

    final publicId = await showDialog<String>(
      context: nav.context,
      barrierDismissible: false,
      builder: (_) => _ServerSyncOverlay(
        serverName: res.serverName ?? 'Server',
        serverData: {
          'name': res.serverName ?? 'Server',
          'description': res.description,
          'icon_url': res.iconUrl,
          'nostr_group_id': res.nostrGroupId,
        },
        gid: res.nostrGroupId,
      ),
    );

    if (publicId != null) {
      router.go('/servers/$publicId');
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
          final chRowId = await db.into(db.channels).insert(ChannelsCompanion.insert(
            publicId: chPubId, serverId: serverId, name: chName,
            channelType: isVoice ? 1 : 0,
            position: Value(chPos), categoryId: Value(categoryId),
            nostrGroupId: Value('$nostrGroupId-$chPubId'),
            createdAt: now, updatedAt: now,
          ));
          // Seed channel_reads so new channels don't appear as unread
          await db.into(db.channelReads).insert(ChannelReadsCompanion.insert(
            channelId: chRowId, userId: 0,
            lastReadAt: now, createdAt: now, updatedAt: now,
          ), onConflict: DoNothing());
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

  int _tab = 0; // 0 = Browse, 1 = Create

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);
    final inputDecor = InputDecoration(
      hintStyle: TextStyle(color: c.gray500),
      fillColor: c.gray900, filled: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent.withValues(alpha: 0.5))),
    );

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.85,
        constraints: BoxConstraints(
          maxWidth: 900,
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        decoration: BoxDecoration(
          color: c.gray800,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // ── Header + Tabs ──
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 0),
            child: Row(children: [
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
            ]),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(children: [
              _TabBtn(label: 'Browse', active: _tab == 0, colors: c, onTap: () => setState(() => _tab = 0)),
              const SizedBox(width: 8),
              _TabBtn(label: 'Create', active: _tab == 1, colors: c, onTap: () => setState(() => _tab = 1)),
            ]),
          ),
          const SizedBox(height: 12),
          Container(height: 1, color: c.gray700.withValues(alpha: 0.5)),

          // ── Tab Content ──
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: _tab == 0 ? _buildBrowseTab(c, inputDecor) : _buildCreateTab(c, inputDecor),
            ),
          ),
        ]),
      ),
    );
  }

  // ─── Browse Tab ──────────────────────────────────────────

  Widget _buildBrowseTab(InfernoColors c, InputDecoration inputDecor) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Invite link
      Text('Have an invite?', style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _inviteController,
            style: TextStyle(color: Colors.white, fontSize: 14),
            onSubmitted: (_) => _resolveInvite(),
            decoration: inputDecor.copyWith(hintText: 'Paste invite link or code...'),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 48,
          child: ElevatedButton(
            onPressed: _resolving ? null : _resolveInvite,
            style: ElevatedButton.styleFrom(
              backgroundColor: c.accent, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: _resolving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Join', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
      if (_inviteResolution != null) ...[
        const SizedBox(height: 12),
        _InvitePreviewCard(resolution: _inviteResolution!, colors: c, onJoin: _acceptResolvedInvite),
      ],
      const SizedBox(height: 20),

      // Discover catalog
      Row(children: [
        Icon(Icons.explore, size: 16, color: c.accent),
        const SizedBox(width: 6),
        Text('DISCOVER SERVERS', style: TextStyle(color: c.gray400, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
        const Spacer(),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: _discovering ? null : () { _discoveryCache = null; _discoverServers(); },
            child: Icon(Icons.refresh, size: 16, color: _discovering ? c.gray600 : c.gray400),
          ),
        ),
      ]),
      const SizedBox(height: 12),
      if (_discovering)
        const Padding(
          padding: EdgeInsets.all(48),
          child: Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2))),
        )
      else if (_discoveredServers.isEmpty)
        GestureDetector(
          onTap: _discoverServers,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Column(children: [
              Icon(Icons.dns_outlined, size: 48, color: c.gray600),
              const SizedBox(height: 12),
              Text('No servers found on your relays', style: TextStyle(color: c.gray500, fontSize: 15)),
              const SizedBox(height: 4),
              Text('Tap to retry', style: TextStyle(color: c.accent, fontSize: 13)),
            ]),
          ),
        )
      else
        LayoutBuilder(builder: (context, constraints) {
          final cols = constraints.maxWidth > 600 ? 3 : (constraints.maxWidth > 380 ? 2 : 1);
          final cards = _discoveredServers.map((s) =>
            _ServerCatalogCard(server: s, colors: c, onJoin: () => _joinDiscoveredServer(s)),
          ).toList();
          return Wrap(
            spacing: 12, runSpacing: 12,
            children: cards.map((card) => SizedBox(
              width: (constraints.maxWidth - (cols - 1) * 12) / cols,
              child: card,
            )).toList(),
          );
        }),
    ]);
  }

  // ─── Create Tab ──────────────────────────────────────────

  String? _selectedTemplate;

  static const _templates = [
    {'id': 'blank', 'name': 'Create My Own', 'desc': 'Start from scratch with an empty server', 'icon': Icons.add_circle_outline, 'color': 0xFF6E7681},
    {'id': 'community', 'name': 'Community', 'desc': 'General chat, announcements, voice channels', 'icon': Icons.people, 'color': 0xFFE85D3A},
    {'id': 'friends', 'name': 'Friends & Family', 'desc': 'Private hangout with voice and media', 'icon': Icons.home, 'color': 0xFF16A34A},
    {'id': 'gaming', 'name': 'Gaming', 'desc': 'LFG, strategy, voice chat for sessions', 'icon': Icons.sports_esports, 'color': 0xFF7C3AED},
    {'id': 'work', 'name': 'Work & Team', 'desc': 'Projects, standups, encrypted channels', 'icon': Icons.work, 'color': 0xFF2563EB},
  ];

  Widget _buildCreateTab(InfernoColors c, InputDecoration inputDecor) {
    // Step 1: Pick template. Step 2: Customize.
    if (_selectedTemplate == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('What kind of server?', style: TextStyle(color: c.gray200, fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('Pick a template or start from scratch. You can customize everything later.',
            style: TextStyle(color: c.gray500, fontSize: 13)),
        const SizedBox(height: 20),
        ...List.generate(_templates.length, (i) {
          final t = _templates[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _TemplateCard(
              name: t['name'] as String,
              desc: t['desc'] as String,
              icon: t['icon'] as IconData,
              color: Color(t['color'] as int),
              colors: c,
              onTap: () {
                final id = t['id'] as String;
                setState(() {
                  _selectedTemplate = id;
                  _serverType = id == 'blank' ? 'community' : id;
                });
              },
            ),
          );
        }),
      ]);
    }

    // Step 2: Customize
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Back to templates
      MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => setState(() => _selectedTemplate = null),
          child: Row(children: [
            Icon(Icons.arrow_back, size: 16, color: c.gray400),
            const SizedBox(width: 6),
            Text('Back to templates', style: TextStyle(color: c.gray400, fontSize: 13)),
          ]),
        ),
      ),
      const SizedBox(height: 16),
      Text('Customize your server', style: TextStyle(color: c.gray200, fontSize: 16, fontWeight: FontWeight.w600)),
      const SizedBox(height: 16),

      // Icon + Name + Description
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 56, height: 56,
          decoration: BoxDecoration(
            color: c.gray900, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.gray600),
          ),
          child: Icon(Icons.add_photo_alternate, size: 24, color: c.gray500),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(children: [
          TextField(
            controller: _nameController,
            style: TextStyle(color: Colors.white, fontSize: 14),
            decoration: inputDecor.copyWith(hintText: 'Server name'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _descController, maxLines: 2,
            style: TextStyle(color: Colors.white, fontSize: 14),
            decoration: inputDecor.copyWith(hintText: 'Description (optional)'),
          ),
        ])),
      ]),
      const SizedBox(height: 16),

      // Server type
      Text('SERVER TYPE', style: TextStyle(color: c.gray500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        _TypeCard('Community', 'community', Icons.people, c.accent, c),
        _TypeCard('Friends', 'friends_family', Icons.home, const Color(0xFF16A34A), c),
        _TypeCard('Gaming', 'gaming', Icons.sports_esports, const Color(0xFF7C3AED), c),
        _TypeCard('Work', 'work_team', Icons.work, const Color(0xFF2563EB), c),
        _TypeCard('18+', 'adult', Icons.warning_amber, c.accent, c),
      ]),

      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(color: c.accent, fontSize: 13)),
      ],
      const SizedBox(height: 20),

      SizedBox(
        height: 44,
        child: ElevatedButton(
          onPressed: _loading ? null : _createServer,
          style: ElevatedButton.styleFrom(
            backgroundColor: c.accent, foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: _loading
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Create Server', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
      ),
    ]);
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

/// Tab button for Browse/Create switcher.
class _TabBtn extends StatelessWidget {
  final String label;
  final bool active;
  final InfernoColors colors;
  final VoidCallback onTap;
  const _TabBtn({required this.label, required this.active, required this.colors, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: active ? colors.accent.withValues(alpha: 0.15) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: active ? colors.accent.withValues(alpha: 0.4) : colors.gray700),
          ),
          child: Text(label, style: TextStyle(
            color: active ? colors.accent : colors.gray400,
            fontSize: 13, fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          )),
        ),
      ),
    );
  }
}

/// Template card for the Create tab's first step.
class _TemplateCard extends StatefulWidget {
  final String name;
  final String desc;
  final IconData icon;
  final Color color;
  final InfernoColors colors;
  final VoidCallback onTap;
  const _TemplateCard({required this.name, required this.desc, required this.icon,
    required this.color, required this.colors, required this.onTap});
  @override
  State<_TemplateCard> createState() => _TemplateCardState();
}

class _TemplateCardState extends State<_TemplateCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: _hovering ? widget.color.withValues(alpha: 0.08) : c.gray900,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _hovering ? widget.color.withValues(alpha: 0.4) : c.gray700.withValues(alpha: 0.5)),
          ),
          child: Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(widget.icon, size: 22, color: widget.color),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.name, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
              Text(widget.desc, style: TextStyle(color: c.gray400, fontSize: 12)),
            ])),
            Icon(Icons.arrow_forward_ios, size: 14, color: _hovering ? widget.color : c.gray600),
          ]),
        ),
      ),
    );
  }
}

/// Server catalog card — banner image + icon overlay + name + description + tags.
/// Designed for a grid layout like a game store catalog.
class _ServerCatalogCard extends StatefulWidget {
  final Map<String, dynamic> server;
  final InfernoColors colors;
  final VoidCallback onJoin;
  const _ServerCatalogCard({required this.server, required this.colors, required this.onJoin});

  @override
  State<_ServerCatalogCard> createState() => _ServerCatalogCardState();
}

class _ServerCatalogCardState extends State<_ServerCatalogCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final s = widget.server;
    final name = s['name'] as String? ?? 'Unknown';
    final desc = s['description'] as String?;
    final iconUrl = s['icon_url'] as String?;
    final bannerUrl = s['banner_url'] as String?;
    final serverType = s['server_type'] as String?;
    final ageRestricted = s['age_restricted'] == true;
    final joined = s['joined'] == true;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: joined ? null : widget.onJoin,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: c.gray900,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: joined
                  ? c.online.withValues(alpha: 0.3)
                  : (_hovering ? c.accent.withValues(alpha: 0.4) : c.gray700.withValues(alpha: 0.4)),
              width: _hovering && !joined ? 1.5 : 1,
            ),
            boxShadow: _hovering && !joined ? [
              BoxShadow(color: c.accent.withValues(alpha: 0.08), blurRadius: 12),
            ] : null,
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Banner area
            Container(
              height: 100,
              decoration: BoxDecoration(
                color: c.gray700,
                image: bannerUrl != null
                    ? DecorationImage(image: NetworkImage(bannerUrl), fit: BoxFit.cover)
                    : (iconUrl != null
                        ? DecorationImage(image: NetworkImage(iconUrl), fit: BoxFit.cover,
                            colorFilter: ColorFilter.mode(Colors.black.withValues(alpha: 0.4), BlendMode.darken))
                        : null),
              ),
              child: Stack(children: [
                if (bannerUrl == null && iconUrl == null)
                  Center(child: Text(name[0].toUpperCase(),
                      style: TextStyle(color: c.gray400, fontSize: 36, fontWeight: FontWeight.bold))),
                if (joined)
                  Positioned(
                    top: 8, right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: c.online.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.check, size: 12, color: Colors.white),
                        SizedBox(width: 4),
                        Text('Joined', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  ),
              ]),
            ),
            // Info section
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  // Small server icon
                  Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(
                      color: c.gray700,
                      borderRadius: BorderRadius.circular(8),
                      image: iconUrl != null
                          ? DecorationImage(image: NetworkImage(iconUrl), fit: BoxFit.cover)
                          : null,
                    ),
                    child: iconUrl == null
                        ? Center(child: Text(name[0].toUpperCase(),
                            style: TextStyle(color: c.gray200, fontWeight: FontWeight.bold, fontSize: 14)))
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(name,
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ]),
                if (desc != null && desc.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(desc,
                      style: TextStyle(color: c.gray400, fontSize: 12, height: 1.3),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
                const SizedBox(height: 8),
                // Tags
                Wrap(spacing: 4, runSpacing: 4, children: [
                  if (serverType != null && serverType.isNotEmpty)
                    _tag(serverType.replaceAll('_', ' '), c.gray700, c.gray200),
                  if (ageRestricted)
                    _tag('18+', c.accent.withValues(alpha: 0.2), c.accent),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _tag(String label, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(label, style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.w600)),
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
        final newServer = await (db.select(db.servers)..where((s) => s.nostrGroupId.equals(cleanGid))).getSingleOrNull();
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
              ..where((s) => s.nostrGroupId.equals(cleanGid)))
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
    final c = ref.watch(infernoColorsProvider);

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

/// Preview card shown after resolving an invite link.
class _InvitePreviewCard extends StatelessWidget {
  final InviteResolution resolution;
  final InfernoColors colors;
  final VoidCallback onJoin;
  const _InvitePreviewCard({required this.resolution, required this.colors, required this.onJoin});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final name = resolution.serverName ?? 'Unknown Server';
    final isValid = resolution.state == InviteState.valid;

    String stateLabel;
    Color stateColor;
    switch (resolution.state) {
      case InviteState.valid:
        stateLabel = 'Valid Invite';
        stateColor = const Color(0xFF16A34A);
      case InviteState.expired:
        stateLabel = 'Invite Expired';
        stateColor = c.accent;
      case InviteState.revoked:
        stateLabel = 'Invite Revoked';
        stateColor = c.accent;
      case InviteState.maxedOut:
        stateLabel = 'Invite Reached Max Uses';
        stateColor = c.accent;
      case InviteState.notFound:
        stateLabel = 'Invite Not Found';
        stateColor = c.gray500;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.gray900,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          // Server icon
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: c.gray700,
              borderRadius: BorderRadius.circular(10),
              image: resolution.iconUrl != null
                  ? DecorationImage(image: NetworkImage(resolution.iconUrl!), fit: BoxFit.cover)
                  : null,
            ),
            child: resolution.iconUrl == null
                ? Center(child: Text(name[0].toUpperCase(), style: TextStyle(color: c.gray200, fontWeight: FontWeight.bold, fontSize: 18)))
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                if (resolution.description != null && resolution.description!.isNotEmpty)
                  Text(resolution.description!, style: TextStyle(color: c.gray400, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: stateColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(stateLabel, style: TextStyle(color: stateColor, fontSize: 11, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          if (isValid)
            ElevatedButton(
              onPressed: onJoin,
              style: ElevatedButton.styleFrom(
                backgroundColor: c.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Join', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ),
        ],
      ),
    );
  }
}
