import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import '../providers/servers_provider.dart';
import '../services/role_service.dart';
import '../nostr/nostr_filter.dart';
import '../theme/all_themes.dart';

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
      final filter = NostrFilter(kinds: [31750], limit: 50);
      final events = await pool.fetch(filter, timeout: const Duration(seconds: 6));

      // Get already-joined server group IDs
      final joinedServers = await db.select(db.servers).get();
      final joinedGids = joinedServers
          .where((s) => s.nostrGroupId != null)
          .map((s) => s.nostrGroupId!)
          .toSet();

      final servers = <Map<String, dynamic>>[];
      for (final event in events) {
        final tags = event.tags;
        String? getTag(String key) {
          final tag = tags.where((t) => t.isNotEmpty && t[0] == key).firstOrNull;
          return tag != null && tag.length > 1 ? tag[1] : null;
        }

        // Must be discoverable and not deleted
        if (getTag('discoverable') != 'true') continue;
        if (getTag('deleted') == 'true') continue;

        final dTag = getTag('d');
        if (dTag == null) continue;
        if (joinedGids.contains(dTag)) continue;

        servers.add({
          'nostr_group_id': dTag,
          'name': getTag('name') ?? 'Unknown Server',
          'description': getTag('about'),
          'icon_url': getTag('picture'),
          'server_type': getTag('server_type'),
          'age_restricted': getTag('age_restricted') == 'true',
          'pubkey': event.pubkey,
        });
      }

      // Dedup by group ID
      final seen = <String>{};
      final unique = servers.where((s) {
        final gid = s['nostr_group_id'] as String;
        if (seen.contains(gid)) return false;
        seen.add(gid);
        return true;
      }).toList();

      if (mounted) setState(() { _discoveredServers = unique; _discovering = false; });
    } catch (_) {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _joinDiscoveredServer(Map<String, dynamic> server) async {
    final db = ref.read(databaseProvider);
    final now = DateTime.now();
    final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
    final gid = server['nostr_group_id'] as String;

    final serverId = await db.into(db.servers).insert(ServersCompanion.insert(
      publicId: publicId, ownerId: 0, name: server['name'] as String,
      description: Value(server['description'] as String?),
      iconUrl: Value(server['icon_url'] as String?),
      nostrGroupId: Value(gid),
      serverType: Value(server['server_type'] as String? ?? 'community'),
      createdAt: now, updatedAt: now,
    ));

    await db.into(db.serverMemberships).insert(ServerMembershipsCompanion.insert(
      publicId: (now.microsecondsSinceEpoch + 1).toRadixString(36).padLeft(12, '0').substring(0, 12),
      userId: 1, serverId: serverId,
      joinedAt: Value(now), createdAt: now, updatedAt: now,
    ));

    // Sync structure from relays
    final syncService = ref.read(serverSyncServiceProvider);
    await syncService.syncServer(gid);

    if (mounted) Navigator.pop(context, publicId);
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

      // Default channels — use unique IDs based on microseconds
      final genId = (now.microsecondsSinceEpoch + 1).toRadixString(36).padLeft(12, '0').substring(0, 12);
      await db.into(db.channels).insert(ChannelsCompanion.insert(
        publicId: genId, serverId: serverId, name: 'general', channelType: 0,
        position: const Value(0), nostrGroupId: Value('$nostrGroupId-$genId'),
        createdAt: now, updatedAt: now,
      ));
      final voiId = (now.microsecondsSinceEpoch + 2).toRadixString(36).padLeft(12, '0').substring(0, 12);
      await db.into(db.channels).insert(ChannelsCompanion.insert(
        publicId: voiId, serverId: serverId, name: 'Voice', channelType: 1,
        position: const Value(1), nostrGroupId: Value('$nostrGroupId-$voiId'),
        createdAt: now, updatedAt: now,
      ));

      await RoleService(db).createDefaultRoles(serverId);
      final memId = now.microsecondsSinceEpoch.toRadixString(36).padRight(12, '0').substring(0, 12);
      await db.into(db.serverMemberships).insert(ServerMembershipsCompanion.insert(
        publicId: memId, userId: 1, serverId: serverId,
        joinedAt: Value(now), createdAt: now, updatedAt: now,
      ));

      // Add local user as a remote member so they appear in the member list
      final auth = ref.read(authServiceProvider);
      if (auth.publicKeyHex != null) {
        final rmId = (now.microsecondsSinceEpoch + 3).toRadixString(36).padLeft(12, '0').substring(0, 12);
        await db.into(db.remoteMembers).insert(RemoteMembersCompanion.insert(
          publicId: Value(rmId),
          serverId: serverId,
          pubkey: auth.publicKeyHex!,
          username: const Value('user'),
          onlineState: const Value(1), // online
          joinedAt: Value(now),
          createdAt: now,
          updatedAt: now,
        ));
      }

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
                  Container(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Icon(Icons.search, size: 40, color: c.gray500),
                        const SizedBox(height: 8),
                        Text('No servers found on your relays', style: TextStyle(color: c.gray400, fontSize: 14)),
                        Text('Servers will appear here as they\'re discovered on your relays',
                          style: TextStyle(color: c.gray500, fontSize: 12)),
                      ],
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
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onJoin,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          margin: const EdgeInsets.only(bottom: 4),
          decoration: BoxDecoration(
            color: _hovering ? c.gray700 : Colors.transparent,
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
