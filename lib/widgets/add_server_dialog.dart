import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import '../providers/servers_provider.dart';
import '../services/role_service.dart';
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

  @override
  void dispose() {
    _inviteController.dispose();
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
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

      // Publish to Nostr
      final serverPublish = ref.read(serverPublishServiceProvider);
      final auth = ref.read(authServiceProvider);
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
                ),
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
