import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/database.dart';
import '../../providers/database_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/servers_provider.dart';
import '../../providers/server_settings_provider.dart';
import '../../services/blossom_client.dart';
import '../../theme/all_themes.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';

/// Show the server settings overlay (matches user settings overlay pattern)
void showServerSettingsOverlay(BuildContext context, Server server) {
  Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      pageBuilder: (context, animation, secondaryAnimation) =>
          ServerSettingsOverlay(server: server),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(opacity: animation, child: child);
      },
      transitionDuration: const Duration(milliseconds: 150),
    ),
  );
}

class ServerSettingsOverlay extends ConsumerStatefulWidget {
  final Server server;
  const ServerSettingsOverlay({super.key, required this.server});

  @override
  ConsumerState<ServerSettingsOverlay> createState() => _ServerSettingsOverlayState();
}

class _ServerSettingsOverlayState extends ConsumerState<ServerSettingsOverlay> {
  String _selectedPage = 'overview';

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<InfernoColors>()!;

    return Scaffold(
      backgroundColor: c.gray950.withValues(alpha: 0.95),
      body: Row(
        children: [
          // Settings sidebar
          Container(
            width: 200,
            padding: const EdgeInsets.only(top: 60, left: 12, right: 4, bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionLabel(widget.server.name.toUpperCase(), c),
                _NavItem('Overview', 'overview', c),
                _NavItem('Channels', 'channels', c),
                _NavItem('Roles', 'roles', c),
                const SizedBox(height: 12),
                _SectionLabel('USER MANAGEMENT', c),
                _NavItem('Members', 'members', c),
                _NavItem('Invites', 'invites', c),
                _NavItem('Bans', 'bans', c),
                const SizedBox(height: 12),
                _SectionLabel('CUSTOMIZATION', c),
                _NavItem('Emojis', 'emojis', c),
                _NavItem('Stickers', 'stickers', c),
                const SizedBox(height: 12),
                _SectionLabel('VOICE & VIDEO', c),
                _NavItem('Voice', 'voice', c),
                const SizedBox(height: 12),
                _SectionLabel('CONNECTIONS', c),
                _NavItem('Relays', 'relays', c),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                  child: Container(height: 1, color: c.gray800),
                ),
                _NavItem('Delete Server', 'delete', c, color: c.accent),
              ],
            ),
          ),
          // Main content
          Expanded(
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 60, left: 20, right: 60, bottom: 16),
                  child: _buildContent(c),
                ),
                // Close button
                Positioned(
                  top: 16, right: 16,
                  child: GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                        color: c.gray800, shape: BoxShape.circle,
                        border: Border.all(color: c.gray700),
                      ),
                      child: Icon(Icons.close, color: c.gray400, size: 18),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(InfernoColors c) {
    switch (_selectedPage) {
      case 'overview':
        return _OverviewPanel(server: widget.server, colors: c);
      case 'channels':
        return _ChannelsPanel(server: widget.server, colors: c);
      case 'roles':
        return _RolesPanel(serverId: widget.server.id, colors: c);
      case 'members':
        return _MembersPanel(serverId: widget.server.id, colors: c);
      case 'invites':
        return _InvitesPanel(server: widget.server, colors: c);
      case 'bans':
        return _BansPanel(serverId: widget.server.id, colors: c);
      case 'emojis':
        return _EmojisPanel(server: widget.server, colors: c);
      case 'voice':
        return _VoicePanel(server: widget.server, colors: c);
      case 'delete':
        return _DeletePanel(server: widget.server, colors: c);
      default:
        return Center(child: Text('Coming soon', style: TextStyle(color: c.gray500)));
    }
  }

  Widget _NavItem(String label, String page, InfernoColors c, {Color? color}) {
    final isActive = _selectedPage == page;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => setState(() => _selectedPage = page),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isActive ? c.gray600 : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(label,
              style: TextStyle(
                color: color ?? (isActive ? Colors.white : c.gray400),
                fontSize: 14,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              )),
          ),
        ),
      ),
    );
  }

  Widget _SectionLabel(String text, InfernoColors c) {
    return Padding(
      padding: const EdgeInsets.only(left: 10, top: 8, bottom: 4),
      child: Text(text,
        style: TextStyle(color: c.gray500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
    );
  }
}

// ──────────────────────────────────────────────────────────
// Overview Panel
// ──────────────────────────────────────────────────────────
class _OverviewPanel extends ConsumerStatefulWidget {
  final Server server;
  final InfernoColors colors;
  const _OverviewPanel({required this.server, required this.colors});

  @override
  ConsumerState<_OverviewPanel> createState() => _OverviewPanelState();
}

class _OverviewPanelState extends ConsumerState<_OverviewPanel> {
  late TextEditingController _nameController;
  late TextEditingController _descController;
  bool _dirty = false;
  bool _saving = false;
  bool _discoverable = false;
  bool _ageRestricted = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.server.name);
    _descController = TextEditingController(text: widget.server.description ?? '');
    _discoverable = widget.server.discoverable;
    _ageRestricted = widget.server.ageRestricted;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final db = ref.read(databaseProvider);
    final auth = ref.read(authServiceProvider);
    final now = DateTime.now();

    await (db.update(db.servers)..where((s) => s.id.equals(widget.server.id)))
        .write(ServersCompanion(
      name: Value(_nameController.text.trim()),
      description: Value(_descController.text.trim()),
      discoverable: Value(_discoverable),
      ageRestricted: Value(_ageRestricted),
      updatedAt: Value(now),
    ));

    // Publish to relays
    if (auth.privateKeyHex != null) {
      final updatedServer = await (db.select(db.servers)..where((s) => s.id.equals(widget.server.id))).getSingle();
      final publishSvc = ref.read(serverPublishServiceProvider);
      await publishSvc.publishMetadata(
        privateKeyHex: auth.privateKeyHex!,
        publicKeyHex: auth.publicKeyHex!,
        server: updatedServer,
      );
    }

    if (mounted) setState(() { _dirty = false; _saving = false; });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left: Form
        Expanded(
          flex: 3,
          child: ListView(children: [
            Text('Server Overview', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Manage your server\'s identity and appearance.', style: TextStyle(color: c.gray400, fontSize: 14)),
            const SizedBox(height: 24),

            // Icon + Banner row
            Row(children: [
              // Icon
              Column(children: [
                Container(
                  width: 80, height: 80,
                  decoration: BoxDecoration(
                    color: c.gray700, borderRadius: BorderRadius.circular(16),
                    image: widget.server.iconUrl != null
                        ? DecorationImage(image: NetworkImage(widget.server.iconUrl!), fit: BoxFit.cover)
                        : null,
                  ),
                  child: widget.server.iconUrl == null
                      ? Center(child: Text(widget.server.name[0].toUpperCase(),
                          style: TextStyle(color: c.gray200, fontSize: 32, fontWeight: FontWeight.bold)))
                      : null,
                ),
                const SizedBox(height: 8),
                _SmallButton(label: 'Change Icon', colors: c, onTap: () => _uploadImage('icon')),
              ]),
              const SizedBox(width: 24),
              // Banner
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  height: 80,
                  decoration: BoxDecoration(
                    color: c.gray700, borderRadius: BorderRadius.circular(8),
                    image: widget.server.bannerUrl != null
                        ? DecorationImage(image: NetworkImage(widget.server.bannerUrl!), fit: BoxFit.cover)
                        : null,
                  ),
                  child: widget.server.bannerUrl == null
                      ? Center(child: Text('No banner', style: TextStyle(color: c.gray500, fontSize: 12)))
                      : null,
                ),
                const SizedBox(height: 8),
                Row(children: [
                  _SmallButton(label: 'Upload Banner', colors: c, onTap: () => _uploadImage('banner')),
                  const SizedBox(width: 8),
                  Text('960x540 recommended', style: TextStyle(color: c.gray500, fontSize: 11)),
                ]),
              ])),
            ]),

            const SizedBox(height: 24),
            Container(height: 1, color: c.gray700),
            const SizedBox(height: 24),

            // Name
            _label('SERVER NAME', c),
            const SizedBox(height: 8),
            TextField(controller: _nameController, onChanged: (_) => setState(() => _dirty = true),
              style: TextStyle(color: Colors.white, fontSize: 14), decoration: _inputDecor(c)),
            const SizedBox(height: 16),

            // Description
            _label('DESCRIPTION', c),
            const SizedBox(height: 8),
            TextField(controller: _descController, onChanged: (_) => setState(() => _dirty = true),
              maxLines: 3, style: TextStyle(color: Colors.white, fontSize: 14),
              decoration: _inputDecor(c).copyWith(hintText: "What's this server about?", hintStyle: TextStyle(color: c.gray500))),

            const SizedBox(height: 24),
            Container(height: 1, color: c.gray700),
            const SizedBox(height: 24),

            // Configuration toggles
            _label('SERVER CONFIGURATION', c),
            const SizedBox(height: 12),
            _CheckboxRow(label: 'Public server', description: 'Anyone can discover and join this server',
              value: _discoverable, colors: c,
              onChanged: (v) => setState(() { _discoverable = v; _dirty = true; })),
            const SizedBox(height: 8),
            _CheckboxRow(label: 'Age restricted (18+)', description: 'Members must confirm they are 18+',
              value: _ageRestricted, colors: c,
              onChanged: (v) => setState(() { _ageRestricted = v; _dirty = true; })),

            const SizedBox(height: 24),

            // Save bar
            if (_dirty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  Text('You have unsaved changes!', style: TextStyle(color: c.gray200, fontSize: 13)),
                  const Spacer(),
                  TextButton(onPressed: () {
                    _nameController.text = widget.server.name;
                    _descController.text = widget.server.description ?? '';
                    _discoverable = widget.server.discoverable;
                    _ageRestricted = widget.server.ageRestricted;
                    setState(() => _dirty = false);
                  }, child: Text('Reset', style: TextStyle(color: c.gray400))),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                    child: Text(_saving ? 'Saving...' : 'Save Changes', style: const TextStyle(color: Colors.white))),
                ]),
              ),
          ]),
        ),

        const SizedBox(width: 24),

        // Right: Live preview card (matches Rails)
        SizedBox(
          width: 260,
          child: Container(
            decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.gray700)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Banner preview
              Container(
                height: 80,
                decoration: BoxDecoration(
                  color: c.gray700,
                  borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
                  image: widget.server.bannerUrl != null
                      ? DecorationImage(image: NetworkImage(widget.server.bannerUrl!), fit: BoxFit.cover)
                      : null,
                ),
              ),
              // Icon overlapping
              Transform.translate(offset: const Offset(0, -20), child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      color: c.gray800, borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: c.gray900, width: 3),
                      image: widget.server.iconUrl != null
                          ? DecorationImage(image: NetworkImage(widget.server.iconUrl!), fit: BoxFit.cover)
                          : null,
                    ),
                    child: widget.server.iconUrl == null
                        ? Center(child: Text(widget.server.name[0].toUpperCase(), style: TextStyle(color: c.gray200, fontSize: 16, fontWeight: FontWeight.bold)))
                        : null,
                  ),
                ]),
              )),
              Padding(padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16), child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_nameController.text.isNotEmpty ? _nameController.text : 'Server Name',
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  if (_descController.text.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(_descController.text, style: TextStyle(color: c.gray400, fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                  const SizedBox(height: 8),
                  Row(children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: c.online, shape: BoxShape.circle)),
                    const SizedBox(width: 4),
                    Text('Online', style: TextStyle(color: c.gray500, fontSize: 11)),
                    const SizedBox(width: 12),
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: c.gray500, shape: BoxShape.circle)),
                    const SizedBox(width: 4),
                    Text('Members', style: TextStyle(color: c.gray500, fontSize: 11)),
                  ]),
                ],
              )),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _label(String text, InfernoColors c) => Text(text,
    style: TextStyle(color: c.gray400, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.5));

  InputDecoration _inputDecor(InfernoColors c) => InputDecoration(
    fillColor: c.gray900, filled: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.accent)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );

  Future<void> _uploadImage(String type) async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.first.path == null) return;
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null) return;

    final url = await BlossomClient.uploadFile(
      filePath: result.files.first.path!,
      privateKeyHex: auth.privateKeyHex!,
      publicKeyHex: auth.publicKeyHex!,
    );
    if (url != null) {
      final db = ref.read(databaseProvider);
      final companion = type == 'banner'
          ? ServersCompanion(bannerUrl: Value(url))
          : ServersCompanion(iconUrl: Value(url));
      await (db.update(db.servers)..where((s) => s.id.equals(widget.server.id))).write(companion);
      setState(() => _dirty = true);
    }
  }
}

class _CheckboxRow extends StatelessWidget {
  final String label;
  final String description;
  final bool value;
  final InfernoColors colors;
  final ValueChanged<bool> onChanged;
  const _CheckboxRow({required this.label, required this.description, required this.value, required this.colors, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Row(children: [
        Container(
          width: 18, height: 18,
          decoration: BoxDecoration(
            color: value ? c.accent : c.gray900,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: value ? c.accent : c.gray700),
          ),
          child: value ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(color: c.gray200, fontSize: 14)),
          Text(description, style: TextStyle(color: c.gray500, fontSize: 12)),
        ])),
      ]),
    );
  }
}

// ──────────────────────────────────────────────────────────
// Channels Panel
// ──────────────────────────────────────────────────────────
class _ChannelsPanel extends ConsumerWidget {
  final Server server;
  final InfernoColors colors;
  const _ChannelsPanel({required this.server, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    final c = colors;

    return StreamBuilder<List<Channel>>(
      stream: db.serversDao.watchServerChannels(server.id),
      builder: (context, snapshot) {
        final channels = snapshot.data ?? [];
        return ListView(
          children: [
            Row(
              children: [
                Expanded(child: Text('Channels', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold))),
                _SmallButton(label: '+ Create Channel', colors: c, onTap: () => _createChannel(context, ref)),
              ],
            ),
            const SizedBox(height: 16),
            for (final ch in channels)
              _ChannelRow(channel: ch, colors: c, onDelete: () => _deleteChannel(ref, ch)),
          ],
        );
      },
    );
  }

  Future<void> _createChannel(BuildContext context, WidgetRef ref) async {
    final c = colors;
    final nameCtrl = TextEditingController();
    final topicCtrl = TextEditingController();
    int channelType = 0;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            width: 440, padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: c.gray800, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.gray700.withValues(alpha: 0.5))),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Create Channel', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              // Type toggle
              Row(children: [
                _TypeChip(label: 'Text', icon: Icons.tag, selected: channelType == 0, colors: c,
                  onTap: () => setDialogState(() => channelType = 0)),
                const SizedBox(width: 8),
                _TypeChip(label: 'Voice', icon: Icons.volume_up, selected: channelType == 1, colors: c,
                  onTap: () => setDialogState(() => channelType = 1)),
              ]),
              const SizedBox(height: 16),
              Text('CHANNEL NAME', style: TextStyle(color: c.gray400, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              TextField(controller: nameCtrl, autofocus: true, style: TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(hintText: 'new-channel', hintStyle: TextStyle(color: c.gray500),
                  fillColor: c.gray900, filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.accent)))),
              const SizedBox(height: 12),
              Text('TOPIC (optional)', style: TextStyle(color: c.gray400, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              TextField(controller: topicCtrl, style: TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(hintText: 'What\'s this channel about?', hintStyle: TextStyle(color: c.gray500),
                  fillColor: c.gray900, filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.accent)))),
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: c.gray400))),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                  onPressed: () => Navigator.pop(ctx, {'name': nameCtrl.text.trim(), 'type': channelType, 'topic': topicCtrl.text.trim()}),
                  child: const Text('Create', style: TextStyle(color: Colors.white))),
              ]),
            ]),
          ),
        ),
      ),
    );

    nameCtrl.dispose();
    topicCtrl.dispose();
    if (result == null || (result['name'] as String).isEmpty) return;

    final db = ref.read(databaseProvider);
    final auth = ref.read(authServiceProvider);
    final now = DateTime.now();
    final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
    final gid = server.nostrGroupId;
    final channelGroupId = gid != null ? '$gid-$publicId' : null;

    final channels = await (db.select(db.channels)..where((ch) => ch.serverId.equals(server.id))).get();
    final maxPos = channels.fold<int>(0, (max, ch) => (ch.position ?? 0) > max ? (ch.position ?? 0) : max);

    await db.into(db.channels).insert(ChannelsCompanion.insert(
      publicId: publicId, serverId: server.id,
      name: (result['name'] as String).toLowerCase().replaceAll(' ', '-'),
      channelType: result['type'] as int,
      position: Value(maxPos + 1),
      topic: (result['topic'] as String).isNotEmpty ? Value(result['topic'] as String) : const Value.absent(),
      nostrGroupId: Value(channelGroupId),
      createdAt: now, updatedAt: now,
    ));

    if (auth.privateKeyHex != null) {
      final updatedServer = await (db.select(db.servers)..where((s) => s.id.equals(server.id))).getSingle();
      final publishSvc = ref.read(serverPublishServiceProvider);
      await publishSvc.publishStructure(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: updatedServer);
    }
  }

  Future<void> _deleteChannel(WidgetRef ref, Channel ch) async {
    final db = ref.read(databaseProvider);
    await (db.delete(db.messages)..where((m) => m.channelId.equals(ch.id))).go();
    await (db.delete(db.channels)..where((c) => c.id.equals(ch.id))).go();

    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex != null) {
      final updatedServer = await (db.select(db.servers)..where((s) => s.id.equals(server.id))).getSingle();
      final publishSvc = ref.read(serverPublishServiceProvider);
      await publishSvc.publishStructure(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: updatedServer);
    }
  }
}

class _ChannelRow extends StatefulWidget {
  final Channel channel;
  final InfernoColors colors;
  final VoidCallback onDelete;
  const _ChannelRow({required this.channel, required this.colors, required this.onDelete});
  @override
  State<_ChannelRow> createState() => _ChannelRowState();
}

class _ChannelRowState extends State<_ChannelRow> {
  bool _hovering = false;
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final ch = widget.channel;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(gradient: _hovering ? LinearGradient(colors: [c.accent.withValues(alpha: 0.08), Colors.transparent]) : null, borderRadius: BorderRadius.circular(4)),
        child: Row(children: [
          Icon(ch.channelType == 1 ? Icons.volume_up : Icons.tag, size: 18, color: c.gray500),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ch.name, style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w500)),
            if (ch.topic != null && ch.topic!.isNotEmpty)
              Text(ch.topic!, style: TextStyle(color: c.gray500, fontSize: 12), overflow: TextOverflow.ellipsis),
          ])),
          if (_hovering)
            GestureDetector(
              onTap: widget.onDelete,
              child: Icon(Icons.delete_outline, size: 16, color: c.accent),
            ),
        ]),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────
// Roles Panel
// ──────────────────────────────────────────────────────────
class _RolesPanel extends ConsumerWidget {
  final int serverId;
  final InfernoColors colors;
  const _RolesPanel({required this.serverId, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rolesAsync = ref.watch(serverRolesProvider(serverId));
    final c = colors;

    return rolesAsync.when(
      data: (roles) => ListView(children: [
        Text('Roles', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        for (final role in roles)
          _RoleRow(role: role, colors: c),
      ]),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e', style: TextStyle(color: c.accent))),
    );
  }
}

class _RoleRow extends StatefulWidget {
  final Role role;
  final InfernoColors colors;
  const _RoleRow({required this.role, required this.colors});
  @override
  State<_RoleRow> createState() => _RoleRowState();
}

class _RoleRowState extends State<_RoleRow> {
  bool _hovering = false;
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final role = widget.role;
    final color = _parseColor(role.color);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(gradient: _hovering ? LinearGradient(colors: [c.accent.withValues(alpha: 0.08), Colors.transparent]) : null, borderRadius: BorderRadius.circular(4)),
        child: Row(children: [
          Container(width: 14, height: 14, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(child: Text(role.name ?? 'Unnamed', style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w500))),
          Text('Position ${role.position ?? 0}', style: TextStyle(color: c.gray500, fontSize: 12)),
        ]),
      ),
    );
  }

  static Color _parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return const Color(0xFF8899A6);
    try {
      final cleaned = hex.replaceFirst('#', '');
      return Color(int.parse('FF$cleaned', radix: 16));
    } catch (_) {
      return const Color(0xFF8899A6);
    }
  }
}

// ──────────────────────────────────────────────────────────
// Members Panel
// ──────────────────────────────────────────────────────────
class _MembersPanel extends ConsumerWidget {
  final int serverId;
  final InfernoColors colors;
  const _MembersPanel({required this.serverId, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    final c = colors;

    return StreamBuilder<List<RemoteMember>>(
      stream: db.serversDao.watchRemoteMembers(serverId),
      builder: (context, snapshot) {
        final members = snapshot.data ?? [];
        return ListView(children: [
          Text('Members \u2014 ${members.length}', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          for (final m in members)
            _MemberRow(member: m, colors: c),
          if (members.isEmpty)
            Padding(padding: const EdgeInsets.all(32),
              child: Text('No members synced yet.', style: TextStyle(color: c.gray500, fontSize: 14))),
        ]);
      },
    );
  }
}

class _MemberRow extends StatefulWidget {
  final RemoteMember member;
  final InfernoColors colors;
  const _MemberRow({required this.member, required this.colors});
  @override
  State<_MemberRow> createState() => _MemberRowState();
}

class _MemberRowState extends State<_MemberRow> {
  bool _hovering = false;
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final m = widget.member;
    final name = m.displayName ?? m.username ?? '${m.pubkey.substring(0, 8)}...';
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(gradient: _hovering ? LinearGradient(colors: [c.accent.withValues(alpha: 0.08), Colors.transparent]) : null, borderRadius: BorderRadius.circular(4)),
        child: Row(children: [
          CircleAvatar(radius: 16, backgroundColor: c.gray600,
            backgroundImage: m.avatarUrl != null ? NetworkImage(m.avatarUrl!) : null,
            child: m.avatarUrl == null ? Text(name[0].toUpperCase(), style: TextStyle(color: c.gray200, fontSize: 13)) : null),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w500)),
            Text(m.pubkey.substring(0, 16), style: TextStyle(color: c.gray500, fontSize: 11, fontFamily: 'monospace')),
          ])),
          if (_hovering) ...[
            _SmallButton(label: 'Kick', colors: c, danger: true, onTap: () {}),
            const SizedBox(width: 4),
            _SmallButton(label: 'Ban', colors: c, danger: true, onTap: () {}),
          ],
        ]),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────
// Invites Panel
// ──────────────────────────────────────────────────────────
class _InvitesPanel extends ConsumerWidget {
  final Server server;
  final InfernoColors colors;
  const _InvitesPanel({required this.server, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    final c = colors;

    return StreamBuilder<List<Invite>>(
      stream: (db.select(db.invites)..where((i) => i.serverId.equals(server.id))).watch(),
      builder: (context, snapshot) {
        final invites = snapshot.data ?? [];
        return ListView(children: [
          Row(children: [
            Expanded(child: Text('Invites', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold))),
            _SmallButton(label: '+ Create Invite', colors: c, onTap: () => _createInvite(context, ref)),
          ]),
          const SizedBox(height: 16),
          for (final inv in invites)
            Container(
              padding: const EdgeInsets.all(12), margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SelectableText(inv.code, style: TextStyle(color: c.gray200, fontSize: 14, fontFamily: 'monospace')),
                  const SizedBox(height: 2),
                  Text('Uses: ${inv.usesCount ?? 0}${inv.maxUses != null ? '/${inv.maxUses}' : ''}',
                    style: TextStyle(color: c.gray500, fontSize: 12)),
                ])),
                GestureDetector(
                  onTap: () => Clipboard.setData(ClipboardData(text: 'inferno://invite/${server.nostrGroupId ?? server.publicId}/${inv.code}')),
                  child: Icon(Icons.copy, size: 16, color: c.gray400),
                ),
              ]),
            ),
          if (invites.isEmpty)
            Padding(padding: const EdgeInsets.all(32),
              child: Text('No invites yet. Create one to share.', style: TextStyle(color: c.gray500, fontSize: 14))),
        ]);
      },
    );
  }

  Future<void> _createInvite(BuildContext context, WidgetRef ref) async {
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null) return;
    final c = colors;

    // Show options dialog matching Rails (expire after + max uses)
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        String expiry = 'never';
        String maxUses = 'unlimited';
        return StatefulBuilder(builder: (ctx, setDialogState) => Dialog(
          backgroundColor: Colors.transparent,
          child: Container(width: 400, padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: c.gray800, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.gray700.withValues(alpha: 0.5))),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Generate Invite', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('EXPIRE AFTER', style: TextStyle(color: c.gray400, fontSize: 11, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: expiry, dropdownColor: c.gray900,
                    style: TextStyle(color: c.gray200, fontSize: 14),
                    decoration: InputDecoration(fillColor: c.gray900, filled: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700))),
                    items: const [
                      DropdownMenuItem(value: 'never', child: Text('Never')),
                      DropdownMenuItem(value: '30m', child: Text('30 minutes')),
                      DropdownMenuItem(value: '1h', child: Text('1 hour')),
                      DropdownMenuItem(value: '6h', child: Text('6 hours')),
                      DropdownMenuItem(value: '12h', child: Text('12 hours')),
                      DropdownMenuItem(value: '1d', child: Text('1 day')),
                      DropdownMenuItem(value: '7d', child: Text('7 days')),
                    ],
                    onChanged: (v) => setDialogState(() => expiry = v!),
                  ),
                ])),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('MAX USES', style: TextStyle(color: c.gray400, fontSize: 11, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: maxUses, dropdownColor: c.gray900,
                    style: TextStyle(color: c.gray200, fontSize: 14),
                    decoration: InputDecoration(fillColor: c.gray900, filled: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700))),
                    items: const [
                      DropdownMenuItem(value: 'unlimited', child: Text('Unlimited')),
                      DropdownMenuItem(value: '1', child: Text('1 use')),
                      DropdownMenuItem(value: '5', child: Text('5 uses')),
                      DropdownMenuItem(value: '10', child: Text('10 uses')),
                      DropdownMenuItem(value: '25', child: Text('25 uses')),
                      DropdownMenuItem(value: '50', child: Text('50 uses')),
                      DropdownMenuItem(value: '100', child: Text('100 uses')),
                    ],
                    onChanged: (v) => setDialogState(() => maxUses = v!),
                  ),
                ])),
              ]),
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                onPressed: () => Navigator.pop(ctx, {'expiry': expiry, 'maxUses': maxUses}),
                child: const Text('Generate Invite', style: TextStyle(color: Colors.white))),
            ])),
        ));
      },
    );
    if (result == null) return;

    final inviteService = ref.read(inviteServiceProvider);
    try {
      await inviteService.createInvite(
        privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!,
        server: server, creatorId: 1,
      );
    } catch (_) {}
  }
}

// ──────────────────────────────────────────────────────────
// Bans Panel
// ──────────────────────────────────────────────────────────
class _BansPanel extends ConsumerWidget {
  final int serverId;
  final InfernoColors colors;
  const _BansPanel({required this.serverId, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bansAsync = ref.watch(serverBansProvider(serverId));
    final c = colors;

    return bansAsync.when(
      data: (bans) => ListView(children: [
        Text('Bans \u2014 ${bans.length}', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        for (final ban in bans)
          Container(
            padding: const EdgeInsets.all(12), margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              Icon(Icons.block, size: 16, color: c.accent),
              const SizedBox(width: 10),
              Expanded(child: Text('User #${ban.userId}', style: TextStyle(color: c.gray200, fontSize: 14))),
              if (ban.reason != null)
                Text(ban.reason!, style: TextStyle(color: c.gray500, fontSize: 12)),
            ]),
          ),
        if (bans.isEmpty)
          Padding(padding: const EdgeInsets.all(32),
            child: Text('No bans.', style: TextStyle(color: c.gray500, fontSize: 14))),
      ]),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e', style: TextStyle(color: c.accent))),
    );
  }
}

// ──────────────────────────────────────────────────────────
// Emojis Panel
// ──────────────────────────────────────────────────────────
class _EmojisPanel extends ConsumerWidget {
  final Server server;
  final InfernoColors colors;
  const _EmojisPanel({required this.server, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    final c = colors;

    return StreamBuilder<List<ServerEmoji>>(
      stream: (db.select(db.serverEmojis)..where((e) => e.serverId.equals(server.id))).watch(),
      builder: (context, snapshot) {
        final emojis = snapshot.data ?? [];
        return ListView(children: [
          Row(children: [
            Expanded(child: Text('Emojis \u2014 ${emojis.length}', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold))),
            _SmallButton(label: '+ Upload Emoji', colors: c, onTap: () => _uploadEmoji(ref)),
          ]),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final emoji in emojis)
              Tooltip(
                message: ':${emoji.name}:',
                child: Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
                  child: emoji.url != null
                      ? Image.network(emoji.url!, fit: BoxFit.contain)
                      : Center(child: Text(emoji.name, style: TextStyle(color: c.gray400, fontSize: 10))),
                ),
              ),
          ]),
          if (emojis.isEmpty)
            Padding(padding: const EdgeInsets.all(32),
              child: Text('No custom emojis yet.', style: TextStyle(color: c.gray500, fontSize: 14))),
        ]);
      },
    );
  }

  Future<void> _uploadEmoji(WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.first.path == null) return;
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null) return;

    final fileName = result.files.first.name.split('.').first.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    final url = await BlossomClient.uploadFile(
      filePath: result.files.first.path!,
      privateKeyHex: auth.privateKeyHex!,
      publicKeyHex: auth.publicKeyHex!,
    );
    if (url == null) return;

    final db = ref.read(databaseProvider);
    final now = DateTime.now();
    final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
    await db.into(db.serverEmojis).insert(ServerEmojisCompanion.insert(
      publicId: publicId, serverId: server.id, name: fileName, creatorId: 0,
      url: Value(url), createdAt: now, updatedAt: now,
    ));
  }
}

// ──────────────────────────────────────────────────────────
// Voice Panel
// ──────────────────────────────────────────────────────────
class _VoicePanel extends StatelessWidget {
  final Server server;
  final InfernoColors colors;
  const _VoicePanel({required this.server, required this.colors});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return ListView(children: [
      Text('Voice & Video', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Voice Enabled', style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(server.voiceEnabled ? 'Yes' : 'No', style: TextStyle(color: c.gray400, fontSize: 14)),
        ]),
      ),
    ]);
  }
}

// ──────────────────────────────────────────────────────────
// Delete Panel
// ──────────────────────────────────────────────────────────
class _DeletePanel extends ConsumerWidget {
  final Server server;
  final InfernoColors colors;
  const _DeletePanel({required this.server, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = colors;
    return ListView(children: [
      Text('Delete Server', style: TextStyle(color: c.accent, fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text('Deleting a server is permanent and cannot be undone. All channels, messages, and data will be lost.',
        style: TextStyle(color: c.gray400, fontSize: 14)),
      const SizedBox(height: 24),
      SizedBox(
        width: 200,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: c.accent),
          onPressed: () => _confirmDelete(context, ref),
          child: const Text('Delete Server', style: TextStyle(color: Colors.white)),
        ),
      ),
    ]);
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final c = colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(width: 400, padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: c.gray800, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.gray700.withValues(alpha: 0.5))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Are you sure?', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text('This will permanently delete "${server.name}" and all its data.', style: TextStyle(color: c.gray400, fontSize: 14)),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: c.gray400))),
              const SizedBox(width: 8),
              ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete', style: TextStyle(color: Colors.white))),
            ]),
          ])),
      ),
    );

    if (confirmed == true && context.mounted) {
      final db = ref.read(databaseProvider);
      final channels = await (db.select(db.channels)..where((c) => c.serverId.equals(server.id))).get();
      for (final ch in channels) {
        await (db.delete(db.messages)..where((m) => m.channelId.equals(ch.id))).go();
      }
      await (db.delete(db.channels)..where((c) => c.serverId.equals(server.id))).go();
      await (db.delete(db.categories)..where((c) => c.serverId.equals(server.id))).go();
      await (db.delete(db.remoteMembers)..where((m) => m.serverId.equals(server.id))).go();
      await (db.delete(db.servers)..where((s) => s.id.equals(server.id))).go();

      if (context.mounted) {
        Navigator.pop(context); // close confirm
        Navigator.pop(context); // close overlay
      }
    }
  }
}

// ──────────────────────────────────────────────────────────
// Shared small widgets
// ──────────────────────────────────────────────────────────
class _SmallButton extends StatefulWidget {
  final String label;
  final InfernoColors colors;
  final VoidCallback onTap;
  final bool danger;
  const _SmallButton({required this.label, required this.colors, required this.onTap, this.danger = false});
  @override
  State<_SmallButton> createState() => _SmallButtonState();
}

class _SmallButtonState extends State<_SmallButton> {
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
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            gradient: _hovering ? LinearGradient(colors: [widget.danger ? c.accent.withValues(alpha: 0.15) : c.accent.withValues(alpha: 0.08), Colors.transparent]) : null,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: widget.danger ? c.accent : c.gray700),
          ),
          child: Text(widget.label,
            style: TextStyle(color: widget.danger ? c.accent : c.gray200, fontSize: 13, fontWeight: FontWeight.w500)),
        ),
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final InfernoColors colors;
  final VoidCallback onTap;
  const _TypeChip({required this.label, required this.icon, required this.selected, required this.colors, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? colors.accent.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: selected ? colors.accent : colors.gray700),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: selected ? colors.accent : colors.gray400),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: selected ? colors.accent : colors.gray400, fontSize: 14)),
        ]),
      ),
    );
  }
}
