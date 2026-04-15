import 'dart:convert';
import 'dart:io' show File;
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../database/database.dart';
import '../../models/permission.dart';
import '../../providers/database_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/servers_provider.dart';
import '../../providers/server_settings_provider.dart';
import '../../services/blossom_client.dart';
import '../../services/relay_config_service.dart';
import '../../theme/all_themes.dart';
import '../../theme/theme_provider.dart';
import 'package:file_picker/file_picker.dart';
import '../../utils/url_utils.dart';
import '../../widgets/message_content.dart';
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
  bool _canManageServer = false;
  bool _canManageRoles = false;
  bool _canManageEmojis = false;
  bool _canBan = false;
  bool _canKick = false;
  bool _canInvite = false;

  @override
  void initState() {
    super.initState();
    _loadPerms();
  }

  Future<void> _loadPerms() async {
    final auth = ref.read(authServiceProvider);
    if (auth.publicKeyHex == null) return;
    final p = ref.read(permissionServiceProvider);
    final sid = widget.server.id;
    final pk = auth.publicKeyHex!;
    final results = await Future.wait([
      p.hasPermission(sid, pk, Permission.manageServer),
      p.hasPermission(sid, pk, Permission.manageRoles),
      p.hasPermission(sid, pk, Permission.manageEmojis),
      p.hasPermission(sid, pk, Permission.banMembers),
      p.hasPermission(sid, pk, Permission.kickMembers),
      p.hasPermission(sid, pk, Permission.createInvite),
    ]);
    if (mounted) {
      setState(() {
        _canManageServer = results[0];
        _canManageRoles = results[1];
        _canManageEmojis = results[2];
        _canBan = results[3];
        _canKick = results[4];
        _canInvite = results[5];
        // Default to first accessible page
        if (!_canManageServer) {
          if (_canManageRoles || _canKick || _canBan) {
            _selectedPage = 'members';
          } else if (_canManageEmojis) {
            _selectedPage = 'emojis';
          } else if (_canInvite) {
            _selectedPage = 'invites';
          }
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);
    final db = ref.watch(databaseProvider);
    return StreamBuilder<Server>(
      stream: db.serversDao.watchServer(widget.server.id),
      initialData: widget.server,
      builder: (context, snap) {
        final server = snap.data ?? widget.server;
        return Scaffold(
      backgroundColor: c.gray950.withValues(alpha: 0.95),
      body: Row(children: [
        Container(
          width: 200,
          padding: const EdgeInsets.only(top: 60, left: 12, right: 4, bottom: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _SectionLabel(server.name.toUpperCase(), c),
            if (_canManageServer) _NavItem('Overview', 'overview', c),
            if (_canManageServer) _NavItem('Onboarding', 'onboarding', c),
            if (_canManageServer) ...[
              const SizedBox(height: 4),
              _NavItem('Voice', 'voice', c),
              _NavItem('Relays', 'relays', c),
            ],
            if (_canManageEmojis) ...[
              const SizedBox(height: 12),
              _SectionLabel('EXPRESSION', c),
              _NavItem('Emoji', 'emojis', c),
              _NavItem('Stickers', 'stickers', c),
            ],
            const SizedBox(height: 12),
            _SectionLabel('PEOPLE', c),
            if (_canKick || _canBan || _canManageRoles) _NavItem('Members', 'members', c),
            if (_canManageRoles) _NavItem('Roles', 'roles', c),
            if (_canInvite) _NavItem('Invites', 'invites', c),
            if (_canBan) ...[
              const SizedBox(height: 12),
              _SectionLabel('MODERATION', c),
              _NavItem('Audit Log', 'audit_log', c),
              _NavItem('Bans', 'bans', c),
            ],
            const Spacer(),
            if (_canManageServer) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                child: Container(height: 1, color: c.gray800),
              ),
              _NavItem('Delete Server', 'delete', c, color: c.accent),
            ],
          ]),
        ),
        Expanded(child: Stack(children: [
          Padding(
            padding: const EdgeInsets.only(top: 60, left: 20, right: 60, bottom: 16),
            child: _buildContent(c, server),
          ),
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
        ])),
      ]),
    );
      },
    );
  }
  Widget _buildContent(InfernoColors c, Server server) {
    switch (_selectedPage) {
      case 'overview': return _OverviewPanel(server: server, colors: c);
      case 'onboarding': return _OnboardingPanel(server: server, colors: c);
      case 'channels': return _ChannelsPanel(server: server, colors: c);
      case 'roles': return _RolesPanel(serverId: server.id, server: server, colors: c);
      case 'members': return _MembersPanel(serverId: server.id, server: server, colors: c);
      case 'invites': return _InvitesPanel(server: server, colors: c);
      case 'bans': return _BansPanel(serverId: server.id, colors: c);
      case 'emojis': return _EmojisPanel(server: server, colors: c);
      case 'stickers': return _StickersPanel(server: server, colors: c);
      case 'voice': return _VoicePanel(server: server, colors: c);
      case 'relays': return _RelaysPanel(server: server, colors: c);
      case 'audit_log': return _AuditLogPanel(server: server, colors: c);
      case 'delete': return _DeletePanel(server: server, colors: c);
      default: return Center(child: Text('Coming soon', style: TextStyle(color: c.gray500)));
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
            child: Text(label, style: TextStyle(
              color: color ?? (isActive ? Colors.white : c.gray400),
              fontSize: 14, fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
            )),
          ),
        ),
      ),
    );
  }
  Widget _SectionLabel(String text, InfernoColors c) {
    return Padding(
      padding: const EdgeInsets.only(left: 10, top: 8, bottom: 4),
      child: Text(text, style: TextStyle(color: c.gray500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
    );
  }
}
// ── Helpers ──────────────────────────────────────────────
InputDecoration _inputDecor(InfernoColors c, {String? hint}) => InputDecoration(
  fillColor: c.gray900, filled: true, hintText: hint, hintStyle: TextStyle(color: c.gray500),
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.accent)),
  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
);
Widget _label(String text, InfernoColors c) => Text(text,
  style: TextStyle(color: c.gray400, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.5));
Color _parseColor(String? hex) {
  if (hex == null || hex.isEmpty) return const Color(0xFF8899A6);
  try {
    final cleaned = hex.replaceFirst('#', '');
    return Color(int.parse('FF$cleaned', radix: 16));
  } catch (_) { return const Color(0xFF8899A6); }
}
String _timeAgo(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inDays > 365) return '${diff.inDays ~/ 365}y ago';
  if (diff.inDays > 30) return '${diff.inDays ~/ 30}mo ago';
  if (diff.inDays > 0) return '${diff.inDays}d ago';
  if (diff.inHours > 0) return '${diff.inHours}h ago';
  if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
  return 'just now';
}
String _timeUntil(DateTime dt) {
  final diff = dt.difference(DateTime.now());
  if (diff.inDays > 0) return '${diff.inDays}d';
  if (diff.inHours > 0) return '${diff.inHours}h';
  if (diff.inMinutes > 0) return '${diff.inMinutes}m';
  return '<1m';
}
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _formatDate(DateTime dt) => '${_months[dt.month - 1]} ${dt.day}, ${dt.year}';
Widget _saveBar(InfernoColors c, {required bool dirty, required bool saving, required VoidCallback onSave, required VoidCallback onReset}) => !dirty ? const SizedBox.shrink() : Container(
  padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
  child: Row(children: [
    Text('You have unsaved changes!', style: TextStyle(color: c.gray200, fontSize: 13)), const Spacer(),
    TextButton(onPressed: onReset, child: Text('Reset', style: TextStyle(color: c.gray400))), const SizedBox(width: 8),
    ElevatedButton(onPressed: saving ? null : onSave, style: ElevatedButton.styleFrom(backgroundColor: c.accent),
      child: Text(saving ? 'Saving...' : 'Save Changes', style: const TextStyle(color: Colors.white))),
  ]),
);
// ── Overview Panel ──────────────────────────────────────
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
  late TextEditingController _welcomeTemplateController;
  bool _dirty = false;
  bool _saving = false;
  bool _discoverable = false;
  bool _ageRestricted = false;
  bool _welcomeMessageEnabled = false;
  int? _welcomeChannelId;
  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.server.name);
    _descController = TextEditingController(text: widget.server.description ?? '');
    _welcomeTemplateController = TextEditingController(text: widget.server.welcomeMessageTemplate);
    _discoverable = widget.server.discoverable;
    _ageRestricted = widget.server.ageRestricted;
    _welcomeMessageEnabled = widget.server.welcomeMessageEnabled;
    _welcomeChannelId = widget.server.welcomeChannelId;
  }
  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _welcomeTemplateController.dispose();
    super.dispose();
  }
  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final db = ref.read(databaseProvider);
      final auth = ref.read(authServiceProvider);
      final now = DateTime.now();
      await (db.update(db.servers)..where((s) => s.id.equals(widget.server.id)))
          .write(ServersCompanion(
        name: Value(_nameController.text.trim()),
        description: Value(_descController.text.trim()),
        discoverable: Value(_discoverable),
        ageRestricted: Value(_ageRestricted),
        welcomeMessageEnabled: Value(_welcomeMessageEnabled),
        welcomeMessageTemplate: Value(_welcomeTemplateController.text.trim()),
        welcomeChannelId: Value(_welcomeChannelId),
        updatedAt: Value(now),
      ));
      if (auth.privateKeyHex != null) {
        final updatedServer = await (db.select(db.servers)..where((s) => s.id.equals(widget.server.id))).getSingle();
        final publishSvc = ref.read(serverPublishServiceProvider);
        await publishSvc.publishMetadata(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: updatedServer);
      }
      if (mounted) setState(() { _dirty = false; _saving = false; });
    } catch (e) {
      debugPrint('[ServerSettings] Save failed: $e');
      if (mounted) setState(() => _saving = false);
    }
  }
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final db = ref.watch(databaseProvider);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(flex: 3, child: ListView(children: [
        Text('Server Profile', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text('Customize how your server appears in invite links', style: TextStyle(color: c.gray400, fontSize: 14)),
        const SizedBox(height: 24),
        Row(children: [
          Column(children: [
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                color: c.gray700, borderRadius: BorderRadius.circular(16),
                image: widget.server.iconUrl != null ? DecorationImage(image: NetworkImage(widget.server.iconUrl!), fit: BoxFit.cover) : null,
              ),
              child: widget.server.iconUrl == null
                  ? Center(child: Text(widget.server.name[0].toUpperCase(), style: TextStyle(color: c.gray200, fontSize: 32, fontWeight: FontWeight.bold)))
                  : null,
            ),
            const SizedBox(height: 8),
            _SmallButton(label: 'Change Icon', colors: c, onTap: () => _uploadImage('icon')),
          ]),
          const SizedBox(width: 24),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              height: 80,
              decoration: BoxDecoration(
                color: c.gray700, borderRadius: BorderRadius.circular(8),
                image: widget.server.bannerUrl != null ? DecorationImage(image: NetworkImage(widget.server.bannerUrl!), fit: BoxFit.cover) : null,
              ),
              child: widget.server.bannerUrl == null ? Center(child: Text('No banner', style: TextStyle(color: c.gray500, fontSize: 12))) : null,
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
        _label('SERVER NAME', c),
        const SizedBox(height: 8),
        TextField(controller: _nameController, onChanged: (_) => setState(() => _dirty = true),
          style: TextStyle(color: Colors.white, fontSize: 14), decoration: _inputDecor(c)),
        const SizedBox(height: 16),
        _label('DESCRIPTION', c),
        const SizedBox(height: 8),
        TextField(controller: _descController, onChanged: (_) => setState(() => _dirty = true),
          maxLines: 3, style: TextStyle(color: Colors.white, fontSize: 14),
          decoration: _inputDecor(c, hint: "What's this server about?")),
        const SizedBox(height: 24),
        Container(height: 1, color: c.gray700),
        const SizedBox(height: 24),
        _label('SERVER CONFIGURATION', c),
        const SizedBox(height: 12),
        _CheckboxRow(label: 'Public server', description: 'Anyone can discover and join this server',
          value: _discoverable, colors: c, onChanged: (v) => setState(() { _discoverable = v; _dirty = true; })),
        const SizedBox(height: 8),
        _CheckboxRow(label: 'Age restricted (18+)', description: 'Members must confirm they are 18+',
          value: _ageRestricted, colors: c, onChanged: (v) => setState(() { _ageRestricted = v; _dirty = true; })),
        const SizedBox(height: 24),
        Container(height: 1, color: c.gray700),
        const SizedBox(height: 24),
        _label('WELCOME MESSAGE', c),
        const SizedBox(height: 12),
        _CheckboxRow(label: 'Send a welcome message when someone joins', description: 'Automatically greet new members',
          value: _welcomeMessageEnabled, colors: c, onChanged: (v) => setState(() { _welcomeMessageEnabled = v; _dirty = true; })),
        if (_welcomeMessageEnabled) ...[
          const SizedBox(height: 16),
          _label('WELCOME CHANNEL', c),
          const SizedBox(height: 8),
          StreamBuilder<List<Channel>>(
            stream: db.serversDao.watchServerChannels(widget.server.id),
            builder: (context, snap) {
              final textChannels = (snap.data ?? []).where((ch) => ch.channelType == 0).toList();
              return DropdownButtonFormField<int?>(
                value: _welcomeChannelId,
                dropdownColor: c.gray900,
                style: TextStyle(color: c.gray200, fontSize: 14),
                decoration: _inputDecor(c),
                items: [
                  DropdownMenuItem<int?>(value: null, child: Text('Select a channel', style: TextStyle(color: c.gray500))),
                  ...textChannels.map((ch) => DropdownMenuItem<int?>(value: ch.id, child: Text('# ${ch.name}'))),
                ],
                onChanged: (v) => setState(() { _welcomeChannelId = v; _dirty = true; }),
              );
            },
          ),
          const SizedBox(height: 16),
          _label('MESSAGE TEMPLATE', c),
          const SizedBox(height: 8),
          TextField(controller: _welcomeTemplateController, onChanged: (_) => setState(() => _dirty = true),
            maxLines: 2, style: TextStyle(color: Colors.white, fontSize: 14),
            decoration: _inputDecor(c, hint: 'Welcome to the server, {user}!')),
          const SizedBox(height: 6),
          Text('Use {user} for display name, {tag} for username, {server} for server name',
            style: TextStyle(color: c.gray500, fontSize: 12)),
        ],
        const SizedBox(height: 24),
        _saveBar(c, dirty: _dirty, saving: _saving, onSave: _save, onReset: () {
          _nameController.text = widget.server.name;
          _descController.text = widget.server.description ?? '';
          _welcomeTemplateController.text = widget.server.welcomeMessageTemplate;
          _discoverable = widget.server.discoverable;
          _ageRestricted = widget.server.ageRestricted;
          _welcomeMessageEnabled = widget.server.welcomeMessageEnabled;
          _welcomeChannelId = widget.server.welcomeChannelId;
          setState(() => _dirty = false);
        }),
      ])),
      const SizedBox(width: 24),
      SizedBox(width: 260, child: Container(
        decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.gray700)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            height: 80,
            decoration: BoxDecoration(
              color: c.gray700,
              borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
              image: widget.server.bannerUrl != null ? DecorationImage(image: NetworkImage(widget.server.bannerUrl!), fit: BoxFit.cover) : null,
            ),
          ),
          Transform.translate(offset: const Offset(0, -20), child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: c.gray800, borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: c.gray900, width: 3),
                  image: widget.server.iconUrl != null ? DecorationImage(image: NetworkImage(widget.server.iconUrl!), fit: BoxFit.cover) : null,
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
              const SizedBox(height: 4),
              Text('Est. ${_formatMonthYear(widget.server.createdAt)}', style: TextStyle(color: c.gray500, fontSize: 11)),
            ],
          )),
        ]),
      )),
    ]);
  }
  String _formatMonthYear(DateTime dt) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[dt.month - 1]} ${dt.year}';
  }
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
      final companion = type == 'banner' ? ServersCompanion(bannerUrl: Value(url)) : ServersCompanion(iconUrl: Value(url));
      await (db.update(db.servers)..where((s) => s.id.equals(widget.server.id))).write(companion);
      setState(() => _dirty = true);
    }
  }
}
// ── Onboarding Panel ────────────────────────────────────
class _OnboardingPanel extends ConsumerStatefulWidget {
  final Server server;
  final InfernoColors colors;
  const _OnboardingPanel({required this.server, required this.colors});
  @override
  ConsumerState<_OnboardingPanel> createState() => _OnboardingPanelState();
}
class _OnboardingPanelState extends ConsumerState<_OnboardingPanel> {
  bool _dirty = false;
  bool _saving = false;
  bool _onboardingEnabled = false;
  late TextEditingController _rulesController;
  Set<int> _selectedRoleIds = {};
  Set<int> _selectedChannelIds = {};
  @override
  void initState() {
    super.initState();
    _onboardingEnabled = widget.server.onboardingEnabled;
    _rulesController = TextEditingController(text: widget.server.onboardingRules ?? '');
    _selectedRoleIds = _parseIdSet(widget.server.onboardingSelfAssignableRoleIds);
    _selectedChannelIds = _parseIdSet(widget.server.onboardingDefaultChannelIds);
  }
  Set<int> _parseIdSet(String csv) {
    if (csv.isEmpty) return {};
    return csv.split(',').where((s) => s.trim().isNotEmpty).map((s) => int.tryParse(s.trim()) ?? 0).where((i) => i > 0).toSet();
  }
  @override
  void dispose() { _rulesController.dispose(); super.dispose(); }
  Future<void> _save() async {
    setState(() => _saving = true);
    final db = ref.read(databaseProvider);
    final auth = ref.read(authServiceProvider);
    await (db.update(db.servers)..where((s) => s.id.equals(widget.server.id)))
        .write(ServersCompanion(
      onboardingEnabled: Value(_onboardingEnabled),
      onboardingRules: Value(_rulesController.text.trim()),
      onboardingSelfAssignableRoleIds: Value(_selectedRoleIds.join(',')),
      onboardingDefaultChannelIds: Value(_selectedChannelIds.join(',')),
      updatedAt: Value(DateTime.now()),
    ));
    if (auth.privateKeyHex != null) {
      final updatedServer = await (db.select(db.servers)..where((s) => s.id.equals(widget.server.id))).getSingle();
      final publishSvc = ref.read(serverPublishServiceProvider);
      await publishSvc.publishMetadata(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: updatedServer);
    }
    if (mounted) setState(() { _dirty = false; _saving = false; });
  }
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final db = ref.watch(databaseProvider);
    final rolesAsync = ref.watch(serverRolesProvider(widget.server.id));
    return ListView(children: [
      Text('Onboarding', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Text('Configure the experience for new members joining your server.', style: TextStyle(color: c.gray400, fontSize: 14)),
      const SizedBox(height: 24),
      _CheckboxRow(label: 'Enable onboarding wizard', description: 'Show a guided setup when new members join',
        value: _onboardingEnabled, colors: c, onChanged: (v) => setState(() { _onboardingEnabled = v; _dirty = true; })),
      const SizedBox(height: 24),
      Container(height: 1, color: c.gray700),
      const SizedBox(height: 24),
      _label('SERVER RULES', c),
      const SizedBox(height: 8),
      TextField(controller: _rulesController, onChanged: (_) => setState(() => _dirty = true),
        maxLines: 6, style: TextStyle(color: Colors.white, fontSize: 14),
        decoration: _inputDecor(c, hint: 'One rule per line')),
      const SizedBox(height: 6),
      Text('One rule per line', style: TextStyle(color: c.gray500, fontSize: 12)),
      const SizedBox(height: 24),
      _label('SELF-ASSIGNABLE ROLES', c),
      const SizedBox(height: 8),
      rolesAsync.when(
        data: (roles) => Column(children: [
          for (final role in roles)
            Padding(padding: const EdgeInsets.only(bottom: 4), child: GestureDetector(
              onTap: () => setState(() {
                if (_selectedRoleIds.contains(role.id)) { _selectedRoleIds.remove(role.id); }
                else { _selectedRoleIds.add(role.id); }
                _dirty = true;
              }),
              child: Row(children: [
                _Checkbox(value: _selectedRoleIds.contains(role.id), colors: c),
                const SizedBox(width: 8),
                Container(width: 10, height: 10, decoration: BoxDecoration(color: _parseColor(role.color), shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Text(role.name ?? 'Unnamed', style: TextStyle(color: c.gray200, fontSize: 14)),
              ]),
            )),
        ]),
        loading: () => const SizedBox(height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        error: (_, __) => Text('Failed to load roles', style: TextStyle(color: c.accent, fontSize: 13)),
      ),
      const SizedBox(height: 24),
      _label('HIGHLIGHTED CHANNELS', c),
      const SizedBox(height: 8),
      StreamBuilder<List<Channel>>(
        stream: db.serversDao.watchServerChannels(widget.server.id),
        builder: (context, snap) {
          final channels = snap.data ?? [];
          return Column(children: [
            for (final ch in channels)
              Padding(padding: const EdgeInsets.only(bottom: 4), child: GestureDetector(
                onTap: () => setState(() {
                  if (_selectedChannelIds.contains(ch.id)) { _selectedChannelIds.remove(ch.id); }
                  else { _selectedChannelIds.add(ch.id); }
                  _dirty = true;
                }),
                child: Row(children: [
                  _Checkbox(value: _selectedChannelIds.contains(ch.id), colors: c),
                  const SizedBox(width: 8),
                  Icon(ch.channelType == 1 ? Icons.volume_up : Icons.tag, size: 16, color: c.gray500),
                  const SizedBox(width: 6),
                  Text(ch.name, style: TextStyle(color: c.gray200, fontSize: 14)),
                ]),
              )),
          ]);
        },
      ),
      const SizedBox(height: 24),
      _saveBar(c, dirty: _dirty, saving: _saving, onSave: _save, onReset: () {
        _onboardingEnabled = widget.server.onboardingEnabled;
        _rulesController.text = widget.server.onboardingRules ?? '';
        _selectedRoleIds = _parseIdSet(widget.server.onboardingSelfAssignableRoleIds);
        _selectedChannelIds = _parseIdSet(widget.server.onboardingDefaultChannelIds);
        setState(() => _dirty = false);
      }),
    ]);
  }
}
// ── Voice Panel ─────────────────────────────────────────
class _VoicePanel extends ConsumerStatefulWidget {
  final Server server;
  final InfernoColors colors;
  const _VoicePanel({required this.server, required this.colors});
  @override
  ConsumerState<_VoicePanel> createState() => _VoicePanelState();
}
class _VoicePanelState extends ConsumerState<_VoicePanel> {
  bool _dirty = false;
  bool _saving = false;
  late bool _voiceEnabled;
  late int? _afkChannelId;
  late int _afkTimeout;
  late String _afkAction;
  @override
  void initState() {
    super.initState();
    _voiceEnabled = widget.server.voiceEnabled;
    _afkChannelId = widget.server.afkChannelId;
    _afkTimeout = widget.server.afkTimeout;
    _afkAction = widget.server.afkAction;
  }
  Future<void> _save() async {
    setState(() => _saving = true);
    final db = ref.read(databaseProvider);
    final auth = ref.read(authServiceProvider);
    await (db.update(db.servers)..where((s) => s.id.equals(widget.server.id)))
        .write(ServersCompanion(
      voiceEnabled: Value(_voiceEnabled),
      afkChannelId: Value(_afkChannelId),
      afkTimeout: Value(_afkTimeout),
      afkAction: Value(_afkAction),
      updatedAt: Value(DateTime.now()),
    ));
    if (auth.privateKeyHex != null) {
      final updatedServer = await (db.select(db.servers)..where((s) => s.id.equals(widget.server.id))).getSingle();
      final publishSvc = ref.read(serverPublishServiceProvider);
      await publishSvc.publishMetadata(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: updatedServer);
    }
    if (mounted) setState(() { _dirty = false; _saving = false; });
  }
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final db = ref.watch(databaseProvider);
    return ListView(children: [
      Text('Voice', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 24),
      _CheckboxRow(label: 'Enable Voice Channels', description: 'Allow members to use voice chat in this server',
        value: _voiceEnabled, colors: c, onChanged: (v) => setState(() { _voiceEnabled = v; _dirty = true; })),
      const SizedBox(height: 24),
      Container(height: 1, color: c.gray700),
      const SizedBox(height: 24),
      _label('VOICE PROVIDERS', c),
      const SizedBox(height: 12),
      StreamBuilder<List<ServerVoiceProvider>>(
        stream: (db.select(db.serverVoiceProviders)..where((p) => p.serverId.equals(widget.server.id))).watch(),
        builder: (context, snap) {
          final providers = snap.data ?? [];
          if (providers.isEmpty) {
            return Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('No voice providers', style: TextStyle(color: c.gray400, fontSize: 14)),
                const SizedBox(height: 8),
                _SmallButton(label: 'Volunteer as Provider', colors: c, onTap: () async {
                  final auth = ref.read(authServiceProvider);
                  if (auth.publicKeyHex == null || auth.privateKeyHex == null) return;
                  final now = DateTime.now();
                  try {
                    await db.into(db.serverVoiceProviders).insert(ServerVoiceProvidersCompanion.insert(
                      serverId: widget.server.id,
                      providerPubkey: Value(auth.publicKeyHex!),
                      active: const Value(true),
                      createdAt: now, updatedAt: now,
                    ));
                  } catch (_) {
                    // Already exists — activate it
                    await (db.update(db.serverVoiceProviders)
                      ..where((p) => p.serverId.equals(widget.server.id) & p.providerPubkey.equals(auth.publicKeyHex!)))
                      .write(ServerVoiceProvidersCompanion(active: const Value(true), updatedAt: Value(now)));
                  }
                  // Republish server metadata so other clients discover this provider
                  final updatedServer = await (db.select(db.servers)..where((s) => s.id.equals(widget.server.id))).getSingle();
                  final publishSvc = ref.read(serverPublishServiceProvider);
                  await publishSvc.publishMetadata(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: updatedServer);
                  if (mounted) setState(() {});
                }),
              ]),
            );
          }
          return Column(children: [
            for (final p in providers)
              FutureBuilder<String>(
                future: _resolveProviderName(db, p.providerPubkey),
                builder: (context, nameSnap) {
                  final name = nameSnap.data ?? p.providerPubkey?.substring(0, 12) ?? 'Provider';
                  return Container(
                    padding: const EdgeInsets.all(12), margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
                    child: Row(children: [
                      Icon(Icons.dns, size: 18, color: c.gray400),
                      const SizedBox(width: 10),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(name, style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w500)),
                        const SizedBox(height: 4),
                        Row(children: [
                          if (p.active) _badge('Active', c.online) else _badge('Inactive', c.gray500),
                          const SizedBox(width: 6),
                          _badge('Voice Provider', c.accent),
                        ]),
                      ])),
                      _SmallButton(label: 'Stop Providing Voice', colors: c, danger: true, onTap: () async {
                        final auth = ref.read(authServiceProvider);
                        if (auth.privateKeyHex == null) return;
                        await (db.update(db.serverVoiceProviders)
                          ..where((vp) => vp.id.equals(p.id)))
                          .write(ServerVoiceProvidersCompanion(active: const Value(false), updatedAt: Value(DateTime.now())));
                        // Republish metadata without this provider
                        final updatedServer = await (db.select(db.servers)..where((s) => s.id.equals(widget.server.id))).getSingle();
                        final publishSvc = ref.read(serverPublishServiceProvider);
                        await publishSvc.publishMetadata(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: updatedServer);
                        if (mounted) setState(() {});
                      }),
                    ]),
                  );
                },
              ),
          ]);
        },
      ),
      const SizedBox(height: 24),
      Container(height: 1, color: c.gray700),
      const SizedBox(height: 24),
      _label('AFK SETTINGS', c),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('AFK Channel', style: TextStyle(color: c.gray400, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          StreamBuilder<List<Channel>>(
            stream: db.serversDao.watchServerChannels(widget.server.id),
            builder: (context, snap) {
              final voiceChannels = (snap.data ?? []).where((ch) => ch.channelType == 1).toList();
              final validIds = voiceChannels.map((ch) => ch.id).toSet();
              final effectiveValue = (_afkChannelId != null && validIds.contains(_afkChannelId)) ? _afkChannelId : null;
              return DropdownButtonFormField<int?>(
                value: effectiveValue,
                dropdownColor: c.gray900,
                style: TextStyle(color: c.gray200, fontSize: 14),
                decoration: _inputDecor(c),
                items: [
                  DropdownMenuItem<int?>(value: null, child: Text('None', style: TextStyle(color: c.gray500))),
                  ...voiceChannels.map((ch) => DropdownMenuItem<int?>(value: ch.id, child: Text(ch.name))),
                ],
                onChanged: (v) => setState(() { _afkChannelId = v; _dirty = true; }),
              );
            },
          ),
        ])),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('AFK Timeout', style: TextStyle(color: c.gray400, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          DropdownButtonFormField<int>(
            value: const [1, 5, 10, 15, 30].contains(_afkTimeout) ? _afkTimeout : 5,
            dropdownColor: c.gray900,
            style: TextStyle(color: c.gray200, fontSize: 14),
            decoration: _inputDecor(c),
            items: [1, 5, 10, 15, 30].map((m) => DropdownMenuItem(value: m, child: Text('$m min'))).toList(),
            onChanged: (v) => setState(() { _afkTimeout = v ?? 5; _dirty = true; }),
          ),
        ])),
      ]),
      const SizedBox(height: 16),
      Text('AFK Action', style: TextStyle(color: c.gray400, fontSize: 12, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Row(children: [
        _RadioOption(label: 'Move to AFK', value: 'move', groupValue: _afkAction, colors: c,
          onChanged: (v) => setState(() { _afkAction = v; _dirty = true; })),
        const SizedBox(width: 16),
        _RadioOption(label: 'Disconnect', value: 'disconnect', groupValue: _afkAction, colors: c,
          onChanged: (v) => setState(() { _afkAction = v; _dirty = true; })),
      ]),
      const SizedBox(height: 24),
      Container(height: 1, color: c.gray700),
      const SizedBox(height: 24),
      _label('CHANNEL SETTINGS', c),
      const SizedBox(height: 12),
      StreamBuilder<List<Channel>>(
        stream: db.serversDao.watchServerChannels(widget.server.id),
        builder: (context, snap) {
          final voiceChannels = (snap.data ?? []).where((ch) => ch.channelType == 1).toList();
          if (voiceChannels.isEmpty) return Text('No voice channels', style: TextStyle(color: c.gray500, fontSize: 14));
          return Column(children: [
            for (final ch in voiceChannels)
              _voiceChannelCard(ch, c),
          ]);
        },
      ),
      const SizedBox(height: 24),
      _saveBar(c, dirty: _dirty, saving: _saving, onSave: _save, onReset: () {
        _voiceEnabled = widget.server.voiceEnabled;
        _afkChannelId = widget.server.afkChannelId;
        _afkTimeout = widget.server.afkTimeout;
        _afkAction = widget.server.afkAction;
        setState(() => _dirty = false);
      }),
    ]);
  }

  Future<String> _resolveProviderName(InfernoDatabase db, String? pubkey) async {
    if (pubkey == null) return 'Unknown';
    // Try contacts first
    final contact = await (db.select(db.contacts)..where((c) => c.pubkey.equals(pubkey))).getSingleOrNull();
    if (contact?.displayName != null) return contact!.displayName!;
    if (contact?.username != null) return contact!.username!;
    // Try remote members
    final member = await (db.select(db.remoteMembers)
      ..where((m) => m.pubkey.equals(pubkey) & m.serverId.equals(widget.server.id))).getSingleOrNull();
    if (member?.displayName != null) return member!.displayName!;
    if (member?.username != null) return member!.username!;
    return pubkey.substring(0, 12);
  }
}
Widget _voiceChannelCard(Channel ch, InfernoColors c) {
  return Container(
    padding: const EdgeInsets.all(12), margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.volume_up, size: 16, color: c.gray400),
        const SizedBox(width: 8),
        Text(ch.name, style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Text('Bitrate: ${ch.voiceBitrate} kbps', style: TextStyle(color: c.gray400, fontSize: 12)),
        const SizedBox(width: 16),
        Text('Limit: ${ch.voiceUserLimit == 0 ? "None" : ch.voiceUserLimit.toString()}', style: TextStyle(color: c.gray400, fontSize: 12)),
        const SizedBox(width: 16),
        Text('Video: ${ch.videoEnabled ? "On" : "Off"}', style: TextStyle(color: c.gray400, fontSize: 12)),
      ]),
    ]),
  );
}
// ── Relays Panel ────────────────────────────────────────
class _RelaysPanel extends ConsumerStatefulWidget {
  final Server server;
  final InfernoColors colors;
  const _RelaysPanel({required this.server, required this.colors});
  @override
  ConsumerState<_RelaysPanel> createState() => _RelaysPanelState();
}
class _RelaysPanelState extends ConsumerState<_RelaysPanel> {
  final _urlController = TextEditingController();
  static const _knownRelays = [
    'wss://relay.damus.io', 'wss://nos.lol', 'wss://relay.snort.social',
    'wss://relay.nostr.band', 'wss://relay.primal.net', 'wss://purplepag.es',
    'wss://nostr.wine', 'wss://relay.nostr.info',
  ];
  @override
  void dispose() { _urlController.dispose(); super.dispose(); }
  Future<void> _addRelay(String url) async {
    if (url.isEmpty) return;
    final db = ref.read(databaseProvider);
    final svc = RelayConfigService(db);
    await svc.addRelay(url);
    _urlController.clear();
  }
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final db = ref.watch(databaseProvider);
    final svc = RelayConfigService(db);
    return ListView(children: [
      Text('Relays', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Text('Manage relay connections for this server.', style: TextStyle(color: c.gray400, fontSize: 14)),
      const SizedBox(height: 24),
      Row(children: [
        Expanded(child: TextField(controller: _urlController,
          style: TextStyle(color: Colors.white, fontSize: 14),
          decoration: _inputDecor(c, hint: 'wss://relay.example.com'))),
        const SizedBox(width: 8),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: c.accent, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
          onPressed: () => _addRelay(_urlController.text.trim()),
          child: const Text('Add Relay', style: TextStyle(color: Colors.white))),
      ]),
      const SizedBox(height: 24),
      _label('GLOBAL RELAYS (inherited)', c),
      const SizedBox(height: 12),
      StreamBuilder<List<RelayConnection>>(
        stream: svc.watchAllRelays(),
        builder: (context, snap) {
          final relays = snap.data ?? [];
          if (relays.isEmpty) return Text('No relays configured', style: TextStyle(color: c.gray500, fontSize: 14));
          return Column(children: [
            for (final relay in relays)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), margin: const EdgeInsets.only(bottom: 4),
                decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  Icon(Icons.wifi, size: 16, color: c.online),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(relay.url, style: TextStyle(color: c.gray200, fontSize: 14, fontFamily: 'monospace')),
                    Text('Global relay \u00b7 Managed in user settings', style: TextStyle(color: c.gray500, fontSize: 12)),
                  ])),
                  GestureDetector(
                    onTap: () async { await svc.removeRelay(relay.url); },
                    child: Icon(Icons.close, size: 16, color: c.gray500),
                  ),
                ]),
              ),
          ]);
        },
      ),
      const SizedBox(height: 24),
      _label('ADD FROM KNOWN RELAYS', c),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final url in _knownRelays)
          GestureDetector(
            onTap: () => _addRelay(url),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(20), border: Border.all(color: c.gray700)),
              child: Text('+ $url', style: TextStyle(color: c.gray400, fontSize: 13)),
            ),
          ),
      ]),
    ]);
  }
}
// ── Channels Panel ──────────────────────────────────────
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
      builder: (context, channelSnap) {
        final channels = channelSnap.data ?? [];
        return StreamBuilder<List<Category>>(
          stream: db.serversDao.watchServerCategories(server.id),
          builder: (context, categorySnap) {
            final categories = categorySnap.data ?? [];
            return ListView(children: [
              // ── Channels ──
              Row(children: [
                Expanded(child: Text('Channels', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold))),
                _SmallButton(label: '+ Create Channel', colors: c, onTap: () => _showChannelDialog(context, ref)),
              ]),
              const SizedBox(height: 16),
              for (final ch in channels)
                _ChannelRow(channel: ch, colors: c,
                  onEdit: () => _showChannelDialog(context, ref, editing: ch),
                  onDelete: () => _confirmDeleteChannel(context, ref, ch)),

              // ── Categories ──
              const SizedBox(height: 24),
              Row(children: [
                Expanded(child: Text('Categories', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold))),
                _SmallButton(label: '+ Create Category', colors: c, onTap: () => _showCategoryDialog(context, ref)),
              ]),
              const SizedBox(height: 16),
              for (final cat in categories)
                _CategoryRow(category: cat, colors: c,
                  onEdit: () => _showCategoryDialog(context, ref, editing: cat),
                  onDelete: () => _confirmDeleteCategory(context, ref, cat)),
            ]);
          },
        );
      },
    );
  }

  Future<void> _showChannelDialog(BuildContext context, WidgetRef ref, {Channel? editing}) =>
      showChannelDialog(context, ref, server: server, colors: colors, editing: editing);

  Future<void> _confirmDeleteChannel(BuildContext context, WidgetRef ref, Channel ch) =>
      confirmDeleteChannel(context, ref, server: server, colors: colors, channel: ch);

  Future<void> _showCategoryDialog(BuildContext context, WidgetRef ref, {Category? editing}) async {
    final c = colors;
    final nameCtrl = TextEditingController(text: editing?.name ?? '');
    final isEditing = editing != null;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 400, padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: c.gray800, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.gray700.withValues(alpha: 0.5))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(isEditing ? 'Edit Category' : 'Create Category',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            _dialogLabel(c, 'CATEGORY NAME'),
            TextField(
              controller: nameCtrl,
              style: TextStyle(color: c.gray200, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Category name',
                hintStyle: TextStyle(color: c.gray500),
                fillColor: c.gray900, filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent)),
              ),
            ),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: c.gray400))),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  if (name.isNotEmpty) Navigator.pop(ctx, name);
                },
                child: Text(isEditing ? 'Save' : 'Create', style: const TextStyle(color: Colors.white))),
            ]),
          ]),
        ),
      ),
    );
    if (result == null || result.isEmpty) return;
    final db = ref.read(databaseProvider);
    if (isEditing) {
      await (db.update(db.categories)..where((c) => c.id.equals(editing.id)))
          .write(CategoriesCompanion(name: Value(result), updatedAt: Value(DateTime.now())));
    } else {
      final maxPos = await (db.selectOnly(db.categories)
            ..addColumns([db.categories.position.max()])
            ..where(db.categories.serverId.equals(server.id)))
          .map((row) => row.read(db.categories.position.max()))
          .getSingleOrNull();
      await db.into(db.categories).insert(CategoriesCompanion.insert(
        publicId: DateTime.now().millisecondsSinceEpoch.toRadixString(36),
        serverId: server.id,
        name: Value(result),
        position: Value((maxPos ?? 0) + 1),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
    }
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex != null) {
      final updatedServer = await (db.select(db.servers)..where((s) => s.id.equals(server.id))).getSingle();
      final publishSvc = ref.read(serverPublishServiceProvider);
      await publishSvc.publishStructure(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: updatedServer);
    }
  }

  Future<void> _confirmDeleteCategory(BuildContext context, WidgetRef ref, Category cat) async {
    final c = colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 400, padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: c.gray800, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.gray700.withValues(alpha: 0.5))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Delete "${cat.name}"?', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text('Channels in this category will be moved to Uncategorized. This cannot be undone.',
                style: TextStyle(color: c.gray400, fontSize: 14)),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: c.gray400))),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete', style: TextStyle(color: Colors.white))),
            ]),
          ]),
        ),
      ),
    );
    if (confirmed != true) return;
    final db = ref.read(databaseProvider);
    // Move channels in this category to uncategorized (null)
    await (db.update(db.channels)..where((ch) => ch.categoryId.equals(cat.id)))
        .write(ChannelsCompanion(categoryId: Value(null)));
    // Delete the category
    await (db.delete(db.categories)..where((c) => c.id.equals(cat.id))).go();
    // Republish structure
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex != null) {
      final updatedServer = await (db.select(db.servers)..where((s) => s.id.equals(server.id))).getSingle();
      final publishSvc = ref.read(serverPublishServiceProvider);
      await publishSvc.publishStructure(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: updatedServer);
    }
  }
}

// ── Top-level channel dialog functions ──────────────────────
Future<void> showChannelDialog(BuildContext context, WidgetRef ref, {required Server server, required InfernoColors colors, Channel? editing}) async {
  final c = colors;
  final db = ref.read(databaseProvider);
  final nameCtrl = TextEditingController(text: editing?.name ?? '');
  final topicCtrl = TextEditingController(text: editing?.topic ?? '');
  int channelType = editing?.channelType ?? 0;
  bool nsfw = editing?.nsfw ?? false;
  bool encrypted = editing?.encrypted ?? false;
  int voiceBitrate = editing?.voiceBitrate ?? 64000;
  int voiceUserLimit = editing?.voiceUserLimit ?? 0;
  bool videoEnabled = editing?.videoEnabled ?? false;
  int? parentChannelId = editing?.parentChannelId;
  final userLimitCtrl = TextEditingController(text: voiceUserLimit.toString());
  Set<String> allowedRoleIds = {};
  if (editing?.permissionsOverrides != null) {
    try {
      final parsed = json.decode(editing!.permissionsOverrides!) as Map;
      final ids = parsed['allowed_role_ids'] as List?;
      if (ids != null) allowedRoleIds = ids.map((e) => e.toString()).toSet();
    } catch (_) {}
  }

  // Load roles and voice channels for dropdowns
  final roles = await (db.select(db.roles)
        ..where((r) => r.serverId.equals(server.id))
        ..orderBy([(r) => OrderingTerm.desc(r.position)]))
      .get();
  final voiceChannels = await (db.select(db.channels)
        ..where((ch) => ch.serverId.equals(server.id) & ch.channelType.equals(1))
        ..orderBy([(ch) => OrderingTerm.asc(ch.position)]))
      .get();
  final filteredRoles = roles.where((r) => r.name != '@everyone').toList();

  final isEditing = editing != null;

  final result = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, ss) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 480,
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          decoration: BoxDecoration(color: c.gray800, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.gray700.withValues(alpha: 0.5))),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(isEditing ? 'Edit Channel' : 'Create Channel',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              if (isEditing) Text('#${editing.name} in ${server.name}', style: TextStyle(color: c.gray500, fontSize: 13)),
              const SizedBox(height: 16),

              // ── Type (create only) ──
              if (!isEditing) ...[
                Row(children: [
                  _TypeChip(label: 'Text', icon: Icons.tag, selected: channelType == 0, colors: c,
                    onTap: () => ss(() => channelType = 0)),
                  const SizedBox(width: 8),
                  _TypeChip(label: 'Voice', icon: Icons.volume_up, selected: channelType == 1, colors: c,
                    onTap: () => ss(() => channelType = 1)),
                ]),
                const SizedBox(height: 16),
              ],

              // ── General ──
              _dialogSection(c, 'General', Icons.tag, [
                _dialogLabel(c, 'CHANNEL NAME'),
                TextField(controller: nameCtrl, autofocus: !isEditing, style: TextStyle(color: Colors.white, fontSize: 14),
                  decoration: _inputDecor(c, hint: 'new-channel')),
                const SizedBox(height: 12),
                _dialogLabel(c, 'TOPIC', optional: true),
                TextField(controller: topicCtrl, style: TextStyle(color: Colors.white, fontSize: 14),
                  decoration: _inputDecor(c, hint: "What's this channel about?")),
              ]),

              // ── Voice Settings (voice only) ──
              if (channelType == 1) ...[
                const SizedBox(height: 12),
                _dialogSection(c, 'Voice Settings', Icons.volume_up, [
                  Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _dialogLabel(c, 'BITRATE'),
                      DropdownButtonFormField<int>(
                        value: voiceBitrate,
                        dropdownColor: c.gray900,
                        style: TextStyle(color: Colors.white, fontSize: 14),
                        decoration: _inputDecor(c),
                        items: const [
                          DropdownMenuItem(value: 32000, child: Text('32 kbps')),
                          DropdownMenuItem(value: 64000, child: Text('64 kbps')),
                          DropdownMenuItem(value: 96000, child: Text('96 kbps')),
                          DropdownMenuItem(value: 128000, child: Text('128 kbps')),
                          DropdownMenuItem(value: 256000, child: Text('256 kbps')),
                        ],
                        onChanged: (v) => ss(() => voiceBitrate = v ?? 64000),
                      ),
                    ])),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _dialogLabel(c, 'USER LIMIT'),
                      TextField(controller: userLimitCtrl, style: TextStyle(color: Colors.white, fontSize: 14),
                        keyboardType: TextInputType.number,
                        decoration: _inputDecor(c, hint: '0 = unlimited'),
                        onChanged: (v) => voiceUserLimit = int.tryParse(v) ?? 0),
                    ])),
                  ]),
                  const SizedBox(height: 12),
                  _dialogLabel(c, 'HEARTH'),
                  DropdownButtonFormField<int?>(
                    value: parentChannelId,
                    dropdownColor: c.gray900,
                    style: TextStyle(color: Colors.white, fontSize: 14),
                    decoration: _inputDecor(c),
                    items: [
                      DropdownMenuItem<int?>(value: null, child: Text('None (standalone)', style: TextStyle(color: c.gray400))),
                      ...voiceChannels.where((vc) => editing == null || vc.id != editing.id).map((vc) =>
                        DropdownMenuItem<int?>(value: vc.id, child: Text(vc.name))),
                    ],
                    onChanged: (v) => ss(() => parentChannelId = v),
                  ),
                  Text('Audio from the hearth radiates down to all its embers', style: TextStyle(color: c.gray600, fontSize: 11)),
                  const SizedBox(height: 8),
                  _dialogCheckbox(c, 'Enable video', videoEnabled, (v) => ss(() => videoEnabled = v)),
                ]),
              ],

              // ── Security ──
              const SizedBox(height: 12),
              _dialogSection(c, 'Security', Icons.shield_outlined, [
                _dialogCheckbox(c, 'Age-Restricted Channel (NSFW)', nsfw, (v) => ss(() => nsfw = v)),
                Text('Members must confirm they are 18+ to view.', style: TextStyle(color: c.gray500, fontSize: 11)),
                const SizedBox(height: 12),
                _dialogCheckbox(c, 'End-to-End Encryption', encrypted, (v) => ss(() => encrypted = v)),
                Text('Messages are encrypted on relays. Only allowed roles can access.', style: TextStyle(color: c.gray500, fontSize: 11)),
                if (isEditing && editing.encrypted && !encrypted) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.withValues(alpha: 0.3))),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(Icons.warning_amber, size: 16, color: Colors.red.shade300),
                      const SizedBox(width: 8),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Irreversible action', style: TextStyle(color: Colors.red.shade300, fontSize: 12, fontWeight: FontWeight.w600)),
                        Text('Turning off encryption will permanently delete all messages in this channel.',
                            style: TextStyle(color: Colors.red.shade300.withValues(alpha: 0.8), fontSize: 11)),
                      ])),
                    ]),
                  ),
                ],
                if (encrypted && filteredRoles.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _dialogLabel(c, 'ALLOWED ROLES'),
                  Text('Owners and admins always have access.', style: TextStyle(color: c.gray600, fontSize: 11)),
                  const SizedBox(height: 6),
                  for (final role in filteredRoles)
                    _dialogCheckbox(c, role.name ?? '', allowedRoleIds.contains(role.publicId), (v) {
                      ss(() { if (v) allowedRoleIds.add(role.publicId); else allowedRoleIds.remove(role.publicId); });
                    }, leading: Container(width: 10, height: 10, decoration: BoxDecoration(
                      color: _parseColor(role.color), shape: BoxShape.circle))),
                ],
              ]),

              // ── Cross-Server Sync (edit only, read-only) ──
              if (isEditing && editing.nostrGroupId != null) ...[
                const SizedBox(height: 12),
                _dialogSection(c, 'Cross-Server Sync', Icons.public, [
                  _dialogLabel(c, 'CHANNEL ID'),
                  SelectableText(editing.nostrGroupId!, style: TextStyle(color: c.gray200, fontSize: 12, fontFamily: 'monospace')),
                  if (editing.encrypted && editing.channelPublicKey != null) ...[
                    const SizedBox(height: 8),
                    _dialogLabel(c, 'ENCRYPTION KEY'),
                    SelectableText(editing.channelPublicKey!, style: TextStyle(color: c.gray200, fontSize: 11, fontFamily: 'monospace')),
                  ],
                ]),
              ],

              // ── Danger Zone (edit only) ──
              if (isEditing) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.withValues(alpha: 0.2))),
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Delete Channel', style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w600)),
                      Text('Permanently removes the channel and all messages.', style: TextStyle(color: c.gray500, fontSize: 12)),
                    ])),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, {'action': 'delete'}),
                      child: Text('Delete', style: TextStyle(color: Colors.red.shade300, fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                  ]),
                ),
              ],

              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: c.gray400))),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                  onPressed: () => Navigator.pop(ctx, {
                    'action': isEditing ? 'save' : 'create',
                    'name': nameCtrl.text.trim(),
                    'type': channelType,
                    'topic': topicCtrl.text.trim(),
                    'nsfw': nsfw,
                    'encrypted': encrypted,
                    'voiceBitrate': voiceBitrate,
                    'voiceUserLimit': voiceUserLimit,
                    'videoEnabled': videoEnabled,
                    'parentChannelId': parentChannelId,
                    'allowedRoleIds': allowedRoleIds.toList(),
                  }),
                  child: Text(isEditing ? 'Save Changes' : 'Create', style: const TextStyle(color: Colors.white))),
              ]),
            ]),
          ),
        ),
      ),
    ),
  );
  nameCtrl.dispose();
  topicCtrl.dispose();
  userLimitCtrl.dispose();
  if (result == null || (result['name'] as String? ?? '').isEmpty && result['action'] != 'delete') return;

  final auth = ref.read(authServiceProvider);

  if (result['action'] == 'delete' && editing != null) {
    confirmDeleteChannel(context, ref, server: server, colors: colors, channel: editing);
    return;
  }

  final name = (result['name'] as String).toLowerCase().replaceAll(' ', '-');
  final topic = result['topic'] as String;
  final permOverrides = (result['encrypted'] as bool) && (result['allowedRoleIds'] as List).isNotEmpty
      ? json.encode({'allowed_role_ids': result['allowedRoleIds']})
      : null;

  if (isEditing) {
    // Purge messages if encryption is being disabled
    if (editing!.encrypted && !(result['encrypted'] as bool)) {
      await (db.delete(db.messages)..where((m) => m.channelId.equals(editing.id))).go();
    }
    await (db.update(db.channels)..where((ch) => ch.id.equals(editing.id))).write(ChannelsCompanion(
      name: Value(name),
      topic: Value(topic.isNotEmpty ? topic : null),
      nsfw: Value(result['nsfw'] as bool),
      encrypted: Value(result['encrypted'] as bool),
      permissionsOverrides: Value(permOverrides),
      voiceBitrate: Value(result['voiceBitrate'] as int),
      voiceUserLimit: Value(result['voiceUserLimit'] as int),
      videoEnabled: Value(result['videoEnabled'] as bool),
      parentChannelId: Value(result['parentChannelId'] as int?),
      updatedAt: Value(DateTime.now()),
    ));
  } else {
    final now = DateTime.now();
    final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
    final gid = server.nostrGroupId;
    final channelGroupId = gid != null ? '$gid-$publicId' : null;
    final channels = await (db.select(db.channels)..where((ch) => ch.serverId.equals(server.id))).get();
    final maxPos = channels.fold<int>(0, (max, ch) => (ch.position ?? 0) > max ? (ch.position ?? 0) : max);
    final chRowId = await db.into(db.channels).insert(ChannelsCompanion.insert(
      publicId: publicId, serverId: server.id,
      name: name, channelType: result['type'] as int,
      position: Value(maxPos + 1),
      topic: topic.isNotEmpty ? Value(topic) : const Value.absent(),
      nsfw: Value(result['nsfw'] as bool),
      encrypted: Value(result['encrypted'] as bool),
      permissionsOverrides: Value(permOverrides),
      voiceBitrate: Value(result['voiceBitrate'] as int),
      voiceUserLimit: Value(result['voiceUserLimit'] as int),
      videoEnabled: Value(result['videoEnabled'] as bool),
      parentChannelId: Value(result['parentChannelId'] as int?),
      nostrGroupId: Value(channelGroupId),
      createdAt: now, updatedAt: now,
    ));
    // Seed channel_reads so new channel doesn't appear as unread
    await db.into(db.channelReads).insert(ChannelReadsCompanion.insert(
      channelId: chRowId, userId: 0,
      lastReadAt: now, createdAt: now, updatedAt: now,
    ), onConflict: DoNothing());
  }

  if (auth.privateKeyHex != null) {
    final updatedServer = await (db.select(db.servers)..where((s) => s.id.equals(server.id))).getSingle();
    final publishSvc = ref.read(serverPublishServiceProvider);
    await publishSvc.publishStructure(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: updatedServer);
  }
}

Future<void> confirmDeleteChannel(BuildContext context, WidgetRef ref, {required Server server, required InfernoColors colors, required Channel channel}) async {
  final c = colors;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 400, padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: c.gray800, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.gray700.withValues(alpha: 0.5))),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Delete #${channel.name}?', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Text('All messages will be permanently lost. This cannot be undone.',
              style: TextStyle(color: c.gray400, fontSize: 14)),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: c.gray400))),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete', style: TextStyle(color: Colors.white))),
          ]),
        ]),
      ),
    ),
  );
  if (confirmed != true) return;
  final db = ref.read(databaseProvider);
  final deletedPublicId = channel.publicId;
  await (db.delete(db.messages)..where((m) => m.channelId.equals(channel.id))).go();
  await (db.delete(db.channels)..where((c) => c.id.equals(channel.id))).go();
  final auth = ref.read(authServiceProvider);
  if (auth.privateKeyHex != null) {
    final updatedServer = await (db.select(db.servers)..where((s) => s.id.equals(server.id))).getSingle();
    final publishSvc = ref.read(serverPublishServiceProvider);
    await publishSvc.publishStructure(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: updatedServer);
  }

  // Redirect if the user is currently viewing the deleted channel
  if (context.mounted) {
    final currentPath = GoRouterState.of(context).uri.toString();
    if (currentPath.contains(deletedPublicId)) {
      // Navigate to server landing — it auto-redirects to the first remaining channel
      GoRouter.of(context).go('/servers/${server.publicId}');
    }
  }
}

// ── Dialog helpers ──
Widget _dialogSection(InfernoColors c, String title, IconData icon, List<Widget> children) {
  return Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(icon, size: 16, color: c.gray400),
        const SizedBox(width: 8),
        Text(title, style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w600)),
      ]),
      const SizedBox(height: 12),
      ...children,
    ]),
  );
}

Widget _dialogLabel(InfernoColors c, String text, {bool optional = false}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(children: [
      Text(text, style: TextStyle(color: c.gray400, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
      if (optional) Text(' — optional', style: TextStyle(color: c.gray600, fontSize: 11)),
    ]),
  );
}

Widget _dialogCheckbox(InfernoColors c, String label, bool value, ValueChanged<bool> onChanged, {Widget? leading}) {
  return GestureDetector(
    onTap: () => onChanged(!value),
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(width: 18, height: 18, child: Checkbox(value: value, onChanged: (v) => onChanged(v ?? false),
            activeColor: c.accent, side: BorderSide(color: c.gray600),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap)),
          const SizedBox(width: 8),
          if (leading != null) ...[leading, const SizedBox(width: 6)],
          Expanded(child: Text(label, style: TextStyle(color: c.gray200, fontSize: 13))),
        ]),
      ),
    ),
  );
}


class _ChannelRow extends StatefulWidget {
  final Channel channel;
  final InfernoColors colors;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _ChannelRow({required this.channel, required this.colors, required this.onEdit, required this.onDelete});
  @override
  State<_ChannelRow> createState() => _ChannelRowState();
}
class _ChannelRowState extends State<_ChannelRow> {
  bool _hovering = false;
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final ch = widget.channel;
    return GestureDetector(
      onTap: widget.onEdit,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(gradient: _hovering ? LinearGradient(colors: [c.accent.withValues(alpha: 0.08), Colors.transparent]) : null, borderRadius: BorderRadius.circular(4)),
          child: Row(children: [
            Icon(ch.channelType == 1 ? Icons.volume_up : Icons.tag, size: 18, color: c.gray500),
            if (ch.encrypted) ...[const SizedBox(width: 4), Icon(Icons.lock, size: 14, color: c.gray600)],
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(ch.name, style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w500)),
              if (ch.topic != null && ch.topic!.isNotEmpty)
                Text(ch.topic!, style: TextStyle(color: c.gray500, fontSize: 12), overflow: TextOverflow.ellipsis),
            ])),
            if (_hovering) ...[
              GestureDetector(onTap: widget.onEdit,
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.edit_outlined, size: 16, color: c.gray400))),
              GestureDetector(onTap: widget.onDelete,
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.delete_outline, size: 16, color: Colors.red.withValues(alpha: 0.7)))),
            ],
          ]),
        ),
      ),
    );
  }
}

class _CategoryRow extends StatefulWidget {
  final Category category;
  final InfernoColors colors;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _CategoryRow({required this.category, required this.colors, required this.onEdit, required this.onDelete});
  @override
  State<_CategoryRow> createState() => _CategoryRowState();
}
class _CategoryRowState extends State<_CategoryRow> {
  bool _hovering = false;
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final cat = widget.category;
    return GestureDetector(
      onTap: widget.onEdit,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(gradient: _hovering ? LinearGradient(colors: [c.accent.withValues(alpha: 0.08), Colors.transparent]) : null, borderRadius: BorderRadius.circular(4)),
          child: Row(children: [
            Icon(Icons.folder_outlined, size: 18, color: c.gray500),
            const SizedBox(width: 10),
            Expanded(child: Text(cat.name ?? 'Unnamed', style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w500))),
            if (_hovering) ...[
              GestureDetector(onTap: widget.onEdit,
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.edit_outlined, size: 16, color: c.gray400))),
              GestureDetector(onTap: widget.onDelete,
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.delete_outline, size: 16, color: Colors.red.withValues(alpha: 0.7)))),
            ],
          ]),
        ),
      ),
    );
  }
}

// ── Roles Panel ─────────────────────────────────────────
class _RolesPanel extends ConsumerStatefulWidget {
  final int serverId;
  final Server server;
  final InfernoColors colors;
  const _RolesPanel({required this.serverId, required this.server, required this.colors});
  @override
  ConsumerState<_RolesPanel> createState() => _RolesPanelState();
}
class _RolesPanelState extends ConsumerState<_RolesPanel> {
  int? _selectedRoleId;
  String _editorTab = 'display';
  int _myHighestPosition = 0;
  @override
  void initState() {
    super.initState();
    _loadMyPosition();
  }
  Future<void> _loadMyPosition() async {
    final auth = ref.read(authServiceProvider);
    if (auth.publicKeyHex == null) return;
    final db = ref.read(databaseProvider);
    final myMember = await (db.select(db.remoteMembers)
      ..where((rm) => rm.pubkey.equals(auth.publicKeyHex!) & rm.serverId.equals(widget.serverId))).getSingleOrNull();
    if (myMember == null) return;
    final myAssignments = await (db.select(db.remoteMembershipRoles)
      ..where((r) => r.remoteMemberId.equals(myMember.id))).get();
    final myRoleIds = myAssignments.map((a) => a.roleId).toSet();
    final allRoles = await (db.select(db.roles)..where((r) => r.serverId.equals(widget.serverId))).get();
    int highest = 0;
    for (final r in allRoles) {
      if (myRoleIds.contains(r.id) && (r.position ?? 0) > highest) highest = r.position ?? 0;
      if (r.name?.toLowerCase() == 'owner' && myRoleIds.contains(r.id)) highest = 999;
    }
    if (mounted) setState(() => _myHighestPosition = highest);
  }
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final rolesAsync = ref.watch(serverRolesProvider(widget.serverId));
    return rolesAsync.when(
      data: (allRoles) {
        // Hide Owner role from list
        final roles = allRoles.where((r) => r.name?.toLowerCase() != 'owner').toList()
          ..sort((a, b) => (b.position ?? 0).compareTo(a.position ?? 0));
        final selectedRole = _selectedRoleId != null ? roles.cast<Role?>().firstWhere((r) => r?.id == _selectedRoleId, orElse: () => null) : null;
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 220, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('Roles', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              const Spacer(),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: c.accent, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
                onPressed: () => _createRole(ref),
                child: const Text('Create Role', style: TextStyle(color: Colors.white, fontSize: 13))),
            ]),
            const SizedBox(height: 16),
            // Drag-and-drop reorderable role list
            ReorderableListView.builder(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              itemCount: roles.length,
              onReorder: (oldIdx, newIdx) {
                // Prevent reordering roles at or above our level
                final movedRole = roles[oldIdx];
                if ((movedRole.position ?? 0) >= _myHighestPosition) return;
                _reorderRoles(ref, roles, oldIdx, newIdx);
              },
              itemBuilder: (ctx, i) {
                final role = roles[i];
                final memberCount = _getRoleMemberCount(ref, role.id);
                final canDrag = (role.position ?? 0) < _myHighestPosition;
                final item = _RoleListItem(key: ValueKey(role.id), role: role, colors: c, memberCount: memberCount,
                  selected: role.id == _selectedRoleId,
                  onTap: () => setState(() => _selectedRoleId = role.id));
                if (canDrag) {
                  return ReorderableDragStartListener(key: ValueKey(role.id), index: i, child: item);
                }
                // Non-draggable — wrap with key only
                return Container(key: ValueKey(role.id), child: item);
              },
            ),
          ])),
          const SizedBox(width: 24),
          Expanded(child: selectedRole != null
            ? _RoleEditor(role: selectedRole, colors: c, tab: _editorTab, server: widget.server,
                onTabChanged: (t) => setState(() => _editorTab = t), serverId: widget.serverId,
                onDelete: () => _deleteRole(ref, selectedRole))
            : Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.shield_outlined, size: 48, color: c.gray600),
                const SizedBox(height: 12),
                Text('Select a role to edit', style: TextStyle(color: c.gray500, fontSize: 16)),
              ]))),
        ]);
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e', style: TextStyle(color: c.accent))),
    );
  }
  int _getRoleMemberCount(WidgetRef ref, int roleId) {
    // Synchronous approximation — will be correct after first build
    return 0; // Actual count loaded async in _RoleListItem
  }
  Future<void> _createRole(WidgetRef ref) async {
    final db = ref.read(databaseProvider);
    final auth = ref.read(authServiceProvider);
    final now = DateTime.now();
    final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
    final roles = await (db.select(db.roles)..where((r) => r.serverId.equals(widget.serverId))).get();
    if (roles.length >= 250) return; // cap at 250 roles per server
    final maxPos = roles.fold<int>(0, (max, r) => (r.position ?? 0) > max ? (r.position ?? 0) : max);
    await db.into(db.roles).insert(RolesCompanion.insert(
      publicId: publicId, serverId: widget.serverId,
      name: Value('New Role'), position: Value(maxPos + 1),
      color: const Value('#9E9E9E'), hoist: const Value(false),
      selfAssignable: const Value(false),
      createdAt: now, updatedAt: now,
    ));
    await _publishRoles(ref);
  }
  Future<void> _deleteRole(WidgetRef ref, Role role) async {
    if (role.name?.toLowerCase() == '@everyone') return;
    final db = ref.read(databaseProvider);
    // Remove role assignments first
    await (db.delete(db.remoteMembershipRoles)..where((r) => r.roleId.equals(role.id))).go();
    await (db.delete(db.roles)..where((r) => r.id.equals(role.id))).go();
    setState(() => _selectedRoleId = null);
    await _publishRoles(ref);
  }
  Future<void> _reorderRoles(WidgetRef ref, List<Role> roles, int oldIdx, int newIdx) async {
    if (newIdx > oldIdx) newIdx--;
    final db = ref.read(databaseProvider);
    final reordered = List<Role>.from(roles);
    final item = reordered.removeAt(oldIdx);
    reordered.insert(newIdx, item);
    // Update positions (highest position = highest in hierarchy)
    for (int i = 0; i < reordered.length; i++) {
      final pos = reordered.length - i;
      await (db.update(db.roles)..where((r) => r.id.equals(reordered[i].id)))
        .write(RolesCompanion(position: Value(pos)));
    }
    await _publishRoles(ref);
  }
  Future<void> _publishRoles(WidgetRef ref) async {
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null) return;
    final db = ref.read(databaseProvider);
    final server = await (db.select(db.servers)..where((s) => s.id.equals(widget.serverId))).getSingle();
    final publishSvc = ref.read(serverPublishServiceProvider);
    await publishSvc.publishRoles(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: server);
  }
}
class _RoleListItem extends ConsumerStatefulWidget {
  final Role role;
  final InfernoColors colors;
  final int memberCount;
  final bool selected;
  final VoidCallback onTap;
  const _RoleListItem({super.key, required this.role, required this.colors, required this.memberCount, required this.selected, required this.onTap});
  @override
  ConsumerState<_RoleListItem> createState() => _RoleListItemState();
}
class _RoleListItemState extends ConsumerState<_RoleListItem> {
  bool _hovering = false;
  int _count = 0;
  @override
  void initState() {
    super.initState();
    _loadCount();
  }
  @override
  void didUpdateWidget(covariant _RoleListItem old) {
    super.didUpdateWidget(old);
    if (old.role.id != widget.role.id) _loadCount();
  }
  Future<void> _loadCount() async {
    final db = ref.read(databaseProvider);
    final assignments = await (db.select(db.remoteMembershipRoles)
      ..where((r) => r.roleId.equals(widget.role.id))).get();
    if (mounted) setState(() => _count = assignments.length);
  }
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final color = _parseColor(widget.role.color);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            color: widget.selected ? c.gray600 : (_hovering ? c.gray800 : Colors.transparent),
            borderRadius: BorderRadius.circular(4)),
          child: Row(children: [
            Container(width: 14, height: 14, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 10),
            Expanded(child: Text(widget.role.name ?? 'Unnamed', style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w500))),
            Text('$_count', style: TextStyle(color: c.gray500, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}
class _RoleEditor extends ConsumerStatefulWidget {
  final Role role;
  final InfernoColors colors;
  final String tab;
  final ValueChanged<String> onTabChanged;
  final int serverId;
  final Server server;
  final VoidCallback onDelete;
  const _RoleEditor({required this.role, required this.colors, required this.tab, required this.onTabChanged, required this.serverId, required this.server, required this.onDelete});
  @override
  ConsumerState<_RoleEditor> createState() => _RoleEditorState();
}
class _RoleEditorState extends ConsumerState<_RoleEditor> {
  late TextEditingController _nameCtrl;
  late TextEditingController _colorCtrl;
  late String _color;
  late bool _hoist;
  late Map<String, bool> _perms;
  bool _dirty = false;
  bool _saving = false;
  String _memberSearch = '';
  String? _myName;
  String? _myAvatarUrl;
  static const _presetColors = [
    '#E74C3C', '#E91E63', '#9B59B6', '#8E44AD', '#673AB7',
    '#3F51B5', '#2196F3', '#03A9F4', '#00BCD4', '#009688',
    '#4CAF50', '#8BC34A', '#CDDC39', '#FFEB3B', '#FFC107',
    '#FF9800', '#FF5722', '#795548', '#607D8B', '#9E9E9E',
  ];
  static const _permGroups = {
    'General': {
      'read_messages': 'View channels and read messages',
      'read_message_history': 'Read message history',
      'create_invite': 'Create invite links',
      'change_nickname': 'Change their own nickname',
    },
    'Text': {
      'send_messages': 'Send messages in text channels',
      'attach_files': 'Upload images and files',
      'send_gifs': 'Send GIFs in messages',
      'add_reactions': 'Add emoji reactions',
      'mention_everyone': 'Use @everyone mentions',
    },
    'Expression': {
      'send_custom_emojis': 'Use custom server emojis',
      'send_custom_stickers': 'Use custom server stickers',
      'create_emojis': 'Upload custom emojis',
      'create_stickers': 'Upload custom stickers',
      'manage_emojis': 'Delete others\' emojis/stickers',
    },
    'Management': {
      'manage_messages': 'Delete or pin others\' messages',
      'manage_channels': 'Create, edit, delete channels',
      'manage_roles': 'Create, edit, reorder roles',
      'manage_invites': 'View and revoke invite links',
      'manage_server': 'Edit server settings',
    },
    'Moderation': {
      'kick_members': 'Remove members from server',
      'ban_members': 'Permanently ban members',
    },
    'Voice': {
      'connect_voice': 'Join voice channels',
      'speak': 'Speak in voice channels',
      'video': 'Send video in voice channels',
      'screen_share': 'Share screen in voice channels',
      'mute_members': 'Server-mute other members',
      'deafen_members': 'Server-deafen other members',
      'move_members': 'Move members between channels',
    },
    'Dangerous': {
      'administrator': 'Full admin access — bypasses all checks',
    },
  };
  @override
  void initState() {
    super.initState();
    _initFromRole();
  }
  void _initFromRole() {
    _nameCtrl = TextEditingController(text: widget.role.name ?? '');
    _color = widget.role.color ?? '#9E9E9E';
    _colorCtrl = TextEditingController(text: _color);
    _hoist = widget.role.hoist;
    _perms = _parsePermissions(widget.role.permissions);
    _loadMyProfile();
  }
  Future<void> _loadMyProfile() async {
    final auth = ref.read(authServiceProvider);
    if (auth.publicKeyHex == null) return;
    final db = ref.read(databaseProvider);
    final contact = await (db.select(db.contacts)..where((c) => c.pubkey.equals(auth.publicKeyHex!))).getSingleOrNull();
    if (contact != null && mounted) {
      setState(() {
        _myName = contact.displayName ?? contact.username ?? auth.publicKeyHex!.substring(0, 8);
        _myAvatarUrl = contact.avatarUrl;
      });
    }
  }
  Map<String, bool> _parsePermissions(String? json) {
    if (json == null || json.isEmpty) return {};
    try {
      final map = (jsonDecode(json) as Map<String, dynamic>);
      return map.map((k, v) => MapEntry(k, v == true));
    } catch (_) { return {}; }
  }
  @override
  void didUpdateWidget(_RoleEditor old) {
    super.didUpdateWidget(old);
    if (old.role.id != widget.role.id) {
      _nameCtrl.dispose();
      _colorCtrl.dispose();
      _initFromRole();
      _dirty = false;
      _memberSearch = '';
    }
  }
  @override
  void dispose() { _nameCtrl.dispose(); _colorCtrl.dispose(); super.dispose(); }
  Future<void> _save() async {
    setState(() => _saving = true);
    final db = ref.read(databaseProvider);
    final permsJson = jsonEncode(_perms);
    await (db.update(db.roles)..where((r) => r.id.equals(widget.role.id)))
        .write(RolesCompanion(name: Value(_nameCtrl.text.trim()), color: Value(_color),
          hoist: Value(_hoist), permissions: Value(permsJson), updatedAt: Value(DateTime.now())));
    // Publish roles to relays
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex != null) {
      final server = await (db.select(db.servers)..where((s) => s.id.equals(widget.serverId))).getSingle();
      final publishSvc = ref.read(serverPublishServiceProvider);
      await publishSvc.publishRoles(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: server);
    }
    if (mounted) setState(() { _dirty = false; _saving = false; });
  }
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final roleColor = _parseColor(_color);
    final auth = ref.watch(authServiceProvider);
    final isEveryone = widget.role.name?.toLowerCase() == '@everyone' || widget.role.name?.toLowerCase() == 'everyone';
    return ListView(children: [
      Text('EDIT ROLE', style: TextStyle(color: c.gray500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
      Text(widget.role.name ?? 'Unnamed', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 16),
      Row(children: [
        _tabBtn('Display', widget.tab == 'display', c, () => widget.onTabChanged('display')),
        const SizedBox(width: 4),
        _tabBtn('Permissions', widget.tab == 'permissions', c, () => widget.onTabChanged('permissions')),
        const SizedBox(width: 4),
        _tabBtn('Members', widget.tab == 'members', c, () => widget.onTabChanged('members')),
      ]),
      const SizedBox(height: 24),
      // === DISPLAY TAB ===
      if (widget.tab == 'display') ...[
        _label('DISPLAY', c),
        const SizedBox(height: 12),
        _label('ROLE NAME', c),
        const SizedBox(height: 8),
        TextField(controller: _nameCtrl, onChanged: (_) => setState(() => _dirty = true),
          style: TextStyle(color: Colors.white, fontSize: 14), decoration: _inputDecor(c)),
        const SizedBox(height: 24),
        _label('ROLE COLOR', c),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final hex in _presetColors)
            GestureDetector(
              onTap: () => setState(() { _color = hex; _colorCtrl.text = hex; _dirty = true; }),
              child: Container(width: 28, height: 28,
                decoration: BoxDecoration(color: _parseColor(hex), shape: BoxShape.circle,
                  border: _color == hex ? Border.all(color: Colors.white, width: 2) : null)),
            ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Container(width: 28, height: 28, decoration: BoxDecoration(color: roleColor, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          SizedBox(width: 120, child: TextField(controller: _colorCtrl,
            style: TextStyle(color: c.gray200, fontSize: 13, fontFamily: 'monospace'),
            decoration: _inputDecor(c, hint: '#RRGGBB'),
            onChanged: (v) { if (v.startsWith('#') && v.length == 7) setState(() { _color = v; _dirty = true; }); })),
        ]),
        const SizedBox(height: 24),
        _CheckboxRow(label: 'Display separately', description: 'Show members with this role in their own group in the member list',
          value: _hoist, colors: c, onChanged: (v) => setState(() { _hoist = v; _dirty = true; })),
        const SizedBox(height: 24),
        _label('PREVIEW', c),
        const SizedBox(height: 12),
        Builder(builder: (_) {
          final previewName = _myName ?? auth.publicKeyHex?.substring(0, 8) ?? 'You';
          final previewAvatar = validImageUrl(_myAvatarUrl);
          Widget avatar({double size = 28}) => Container(
            width: size, height: size,
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: previewAvatar != null ? Colors.transparent : c.gray700),
            clipBehavior: Clip.antiAlias,
            child: previewAvatar != null
              ? Image.network(previewAvatar, fit: BoxFit.cover, width: size, height: size)
              : Center(child: Text(previewName[0].toUpperCase(),
                  style: TextStyle(color: c.gray200, fontSize: size * 0.45, fontWeight: FontWeight.w600))),
          );
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_hoist) ...[
                Text((_nameCtrl.text.isEmpty ? 'Role' : _nameCtrl.text).toUpperCase() + ' \u2014 1',
                  style: TextStyle(color: roleColor, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                const SizedBox(height: 6),
              ],
              Row(children: [
                avatar(),
                const SizedBox(width: 8),
                Text(previewName, style: TextStyle(color: roleColor, fontSize: 14, fontWeight: FontWeight.w600)),
                Container(width: 8, height: 8, margin: const EdgeInsets.only(left: 6),
                  decoration: BoxDecoration(color: c.online, shape: BoxShape.circle)),
              ]),
              const SizedBox(height: 10),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                avatar(),
                const SizedBox(width: 8),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(previewName, style: TextStyle(color: roleColor, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 6),
                    Text('Today at ${TimeOfDay.now().format(context)}', style: TextStyle(color: c.gray600, fontSize: 11)),
                  ]),
                  const SizedBox(height: 2),
                  Text('This is a preview of how the role color looks in chat.', style: TextStyle(color: c.gray200, fontSize: 13)),
                ])),
              ]),
            ]),
          );
        }),
        const SizedBox(height: 24),
        Row(children: [
          Expanded(child: _saveBar(c, dirty: _dirty, saving: _saving, onSave: _save, onReset: () {
            _nameCtrl.text = widget.role.name ?? '';
            _color = widget.role.color ?? '#9E9E9E';
            _colorCtrl.text = _color;
            _hoist = widget.role.hoist;
            setState(() => _dirty = false);
          })),
          if (!isEveryone) ...[
            const SizedBox(width: 12),
            _SmallButton(label: 'Delete Role', colors: c, danger: true, onTap: widget.onDelete),
          ],
        ]),
      ],
      // === PERMISSIONS TAB ===
      if (widget.tab == 'permissions') ...[
        for (final group in _permGroups.entries) ...[
          _label(group.key.toUpperCase(), c),
          const SizedBox(height: 8),
          for (final perm in group.value.entries)
            Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(perm.key.replaceAll('_', ' ').split(' ').map((w) => w[0].toUpperCase() + w.substring(1)).join(' '),
                  style: TextStyle(color: c.gray200, fontSize: 13)),
                Text(perm.value, style: TextStyle(color: c.gray500, fontSize: 11)),
              ])),
              Switch(
                value: _perms[perm.key] == true,
                activeColor: c.accent,
                onChanged: (v) => setState(() { _perms[perm.key] = v; _dirty = true; }),
              ),
            ])),
          const SizedBox(height: 12),
        ],
        _saveBar(c, dirty: _dirty, saving: _saving, onSave: _save, onReset: () {
          _perms = _parsePermissions(widget.role.permissions);
          setState(() => _dirty = false);
        }),
      ],
      // === MEMBERS TAB ===
      if (widget.tab == 'members')
        StreamBuilder<List<RemoteMember>>(
          stream: ref.watch(databaseProvider).serversDao.watchRemoteMembers(widget.serverId),
          builder: (context, snap) {
            final allMembers = snap.data ?? [];
            final filtered = _memberSearch.isEmpty ? allMembers
              : allMembers.where((m) {
                  final q = _memberSearch.toLowerCase();
                  return (m.displayName?.toLowerCase().contains(q) ?? false) || (m.username?.toLowerCase().contains(q) ?? false);
                }).toList();
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                _label('MEMBERS', c),
                const Spacer(),
                Text('${allMembers.length} assigned', style: TextStyle(color: c.gray500, fontSize: 12)),
              ]),
              const SizedBox(height: 8),
              TextField(
                style: TextStyle(color: Colors.white, fontSize: 13),
                decoration: _inputDecor(c, hint: 'Search members...').copyWith(
                  prefixIcon: Icon(Icons.search, size: 16, color: c.gray500),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8)),
                onChanged: (v) => setState(() => _memberSearch = v),
              ),
              const SizedBox(height: 12),
              for (final m in filtered)
                _RoleMemberToggle(member: m, roleId: widget.role.id, colors: c, serverId: widget.serverId, server: widget.server),
            ]);
          },
        ),
    ]);
  }
}
// Toggle widget for assigning/removing a role from a member
class _RoleMemberToggle extends ConsumerStatefulWidget {
  final RemoteMember member;
  final int roleId;
  final int serverId;
  final Server server;
  final InfernoColors colors;
  const _RoleMemberToggle({required this.member, required this.roleId, required this.serverId, required this.server, required this.colors});
  @override
  ConsumerState<_RoleMemberToggle> createState() => _RoleMemberToggleState();
}
class _RoleMemberToggleState extends ConsumerState<_RoleMemberToggle> {
  bool _assigned = false;
  @override
  void initState() {
    super.initState();
    _checkAssignment();
  }
  Future<void> _checkAssignment() async {
    final db = ref.read(databaseProvider);
    final existing = await (db.select(db.remoteMembershipRoles)
      ..where((r) => r.remoteMemberId.equals(widget.member.id) & r.roleId.equals(widget.roleId))).getSingleOrNull();
    if (mounted) setState(() => _assigned = existing != null);
  }
  Future<void> _toggle(bool value) async {
    final db = ref.read(databaseProvider);
    final auth = ref.read(authServiceProvider);
    if (value) {
      try {
        await db.into(db.remoteMembershipRoles).insert(RemoteMembershipRolesCompanion.insert(
          remoteMemberId: widget.member.id, roleId: widget.roleId,
          createdAt: DateTime.now(), updatedAt: DateTime.now()));
      } catch (_) {}
    } else {
      await (db.delete(db.remoteMembershipRoles)
        ..where((r) => r.remoteMemberId.equals(widget.member.id) & r.roleId.equals(widget.roleId))).go();
    }
    setState(() => _assigned = value);
    // Publish updated member roles
    if (auth.privateKeyHex != null) {
      final allAssignments = await (db.select(db.remoteMembershipRoles)
        ..where((r) => r.remoteMemberId.equals(widget.member.id))).get();
      final roleIds = allAssignments.map((a) => a.roleId).toList();
      final roles = await (db.select(db.roles)..where((r) => r.serverId.equals(widget.serverId))).get();
      final rolePublicIds = roles.where((r) => roleIds.contains(r.id)).map((r) => r.publicId).toList();
      final publishSvc = ref.read(serverPublishServiceProvider);
      await publishSvc.publishMemberRoleUpdate(
        privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!,
        server: widget.server, targetPubkey: widget.member.pubkey, rolePublicIds: rolePublicIds);
    }
  }
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final m = widget.member;
    final name = m.displayName ?? m.username ?? m.pubkey.substring(0, 8);
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
      Container(width: 28, height: 28, decoration: BoxDecoration(shape: BoxShape.circle,
        color: validImageUrl(m.avatarUrl) != null ? Colors.transparent : c.gray700),
        clipBehavior: Clip.antiAlias,
        child: validImageUrl(m.avatarUrl) != null
          ? Image.network(validImageUrl(m.avatarUrl)!, fit: BoxFit.cover, width: 28, height: 28)
          : Center(child: Text(name[0].toUpperCase(), style: TextStyle(color: c.gray200, fontSize: 12)))),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w500)),
        Text(m.username ?? m.pubkey.substring(0, 12), style: TextStyle(color: c.gray500, fontSize: 11)),
      ])),
      Switch(value: _assigned, activeColor: c.accent, onChanged: _toggle),
    ]));
  }
}

// ── Members Panel ───────────────────────────────────────
class _MembersPanel extends ConsumerStatefulWidget {
  final int serverId;
  final Server server;
  final InfernoColors colors;
  const _MembersPanel({required this.serverId, required this.server, required this.colors});
  @override
  ConsumerState<_MembersPanel> createState() => _MembersPanelState();
}
class _MembersPanelState extends ConsumerState<_MembersPanel> {
  String _search = '';
  bool _selectAll = false;
  final Set<int> _selected = {};
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final db = ref.watch(databaseProvider);
    final rolesAsync = ref.watch(serverRolesProvider(widget.serverId));
    return StreamBuilder<List<RemoteMember>>(
      stream: db.serversDao.watchRemoteMembers(widget.serverId),
      builder: (context, snapshot) {
        final allMembers = snapshot.data ?? [];
        final members = _search.isEmpty ? allMembers
            : allMembers.where((m) {
                final q = _search.toLowerCase();
                return (m.displayName?.toLowerCase().contains(q) ?? false) || (m.username?.toLowerCase().contains(q) ?? false) || m.pubkey.contains(q);
              }).toList();
        return ListView(children: [
          Row(children: [
            Text('Members (${allMembers.length})', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
            const Spacer(),
            SizedBox(width: 200, child: TextField(
              style: TextStyle(color: Colors.white, fontSize: 13),
              decoration: _inputDecor(c, hint: 'Search members...').copyWith(
                prefixIcon: Icon(Icons.search, size: 16, color: c.gray500),
                contentPadding: const EdgeInsets.symmetric(vertical: 8)),
              onChanged: (v) => setState(() => _search = v),
            )),
            const SizedBox(width: 8),
            _SmallButton(label: 'Prune', colors: c, onTap: () => _pruneMembers(context, ref, allMembers)),
          ]),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => setState(() {
              _selectAll = !_selectAll;
              if (_selectAll) { _selected.addAll(members.map((m) => m.id)); }
              else { _selected.clear(); }
            }),
            child: Row(children: [
              _Checkbox(value: _selectAll, colors: c),
              const SizedBox(width: 8),
              Text('Select all', style: TextStyle(color: c.gray400, fontSize: 13)),
            ]),
          ),
          const SizedBox(height: 8),
          for (final m in members)
            _MemberRow(member: m, colors: c, server: widget.server, selected: _selected.contains(m.id),
              roles: rolesAsync.valueOrNull ?? [],
              onSelect: (v) => setState(() { if (v) _selected.add(m.id); else _selected.remove(m.id); })),
          if (members.isEmpty)
            Padding(padding: const EdgeInsets.all(32),
              child: Text('No members synced yet.', style: TextStyle(color: c.gray500, fontSize: 14))),
        ]);
      },
    );
  }

  Future<void> _pruneMembers(BuildContext context, WidgetRef ref, List<RemoteMember> allMembers) async {
    final c = widget.colors;
    final db = ref.read(databaseProvider);
    final auth = ref.read(authServiceProvider);

    int days = 30;
    List<RemoteMember> prunable = [];

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDialogState) {
        final cutoff = DateTime.now().subtract(Duration(days: days));
        prunable = allMembers.where((m) {
          if (m.pubkey == auth.publicKeyHex) return false; // never prune self/owner
          final lastSeen = m.joinedAt ?? m.createdAt;
          return lastSeen.isBefore(cutoff);
        }).toList();

        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(width: 450, padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: c.gray800, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.gray700)),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Prune Members', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Remove members who have been inactive.', style: TextStyle(color: c.gray500, fontSize: 13)),
              const SizedBox(height: 16),
              Text('INACTIVE FOR', style: TextStyle(color: c.gray400, fontSize: 11, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              DropdownButtonFormField<int>(
                value: days, dropdownColor: c.gray900,
                style: TextStyle(color: c.gray200, fontSize: 14),
                decoration: InputDecoration(fillColor: c.gray900, filled: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700))),
                items: const [
                  DropdownMenuItem(value: 7, child: Text('7 days')),
                  DropdownMenuItem(value: 14, child: Text('14 days')),
                  DropdownMenuItem(value: 30, child: Text('30 days')),
                  DropdownMenuItem(value: 60, child: Text('60 days')),
                  DropdownMenuItem(value: 90, child: Text('90 days')),
                ],
                onChanged: (v) => setDialogState(() => days = v ?? 30),
              ),
              const SizedBox(height: 16),
              Text('${prunable.length} member(s) will be removed', style: TextStyle(
                color: prunable.isEmpty ? c.gray500 : c.accent, fontSize: 14, fontWeight: FontWeight.w600)),
              if (prunable.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  height: 120,
                  decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(6)),
                  child: ListView(padding: const EdgeInsets.all(8), children: [
                    for (final m in prunable)
                      Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(
                        m.displayName ?? m.username ?? m.pubkey.substring(0, 12),
                        style: TextStyle(color: c.gray400, fontSize: 12))),
                  ]),
                ),
              ],
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: c.gray400))),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: prunable.isEmpty ? c.gray700 : c.accent),
                  onPressed: prunable.isEmpty ? null : () async {
                    final publishSvc = ref.read(serverPublishServiceProvider);
                    for (final m in prunable) {
                      await (db.delete(db.remoteMembershipRoles)..where((r) => r.remoteMemberId.equals(m.id))).go();
                      await (db.delete(db.remoteMembers)..where((rm) => rm.id.equals(m.id))).go();
                      if (auth.privateKeyHex != null) {
                        await publishSvc.publishMemberRemoval(
                          privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!,
                          server: widget.server, targetPubkey: m.pubkey,
                        );
                      }
                    }
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: Text('Prune ${prunable.length} Members', style: const TextStyle(color: Colors.white))),
              ]),
            ])),
        );
      }),
    );
  }
}
class _MemberRow extends ConsumerStatefulWidget {
  final RemoteMember member;
  final InfernoColors colors;
  final Server server;
  final bool selected;
  final List<Role> roles;
  final ValueChanged<bool> onSelect;
  const _MemberRow({required this.member, required this.colors, required this.server, required this.selected, required this.roles, required this.onSelect});
  @override
  ConsumerState<_MemberRow> createState() => _MemberRowState();
}
class _MemberRowState extends ConsumerState<_MemberRow> {
  bool _hovering = false;
  List<Role>? _memberRoles;

  @override
  void initState() {
    super.initState();
    _loadMemberRoles();
  }

  @override
  void didUpdateWidget(covariant _MemberRow old) {
    super.didUpdateWidget(old);
    if (old.member.id != widget.member.id) _loadMemberRoles();
  }

  Future<void> _loadMemberRoles() async {
    final db = ref.read(databaseProvider);
    final assignments = await (db.select(db.remoteMembershipRoles)
      ..where((r) => r.remoteMemberId.equals(widget.member.id))).get();
    final roleIds = assignments.map((a) => a.roleId).toSet();
    final roles = widget.roles.where((r) => roleIds.contains(r.id)).toList();
    // Always include @everyone
    if (!roles.any((r) => r.name?.toLowerCase() == '@everyone' || r.name?.toLowerCase() == 'everyone')) {
      final everyone = widget.roles.where((r) => r.name?.toLowerCase() == '@everyone' || r.name?.toLowerCase() == 'everyone').firstOrNull;
      if (everyone != null) roles.add(everyone);
    }
    if (mounted) setState(() => _memberRoles = roles);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final m = widget.member;
    final name = m.displayName ?? m.username ?? '${m.pubkey.substring(0, 8)}...';
    final username = m.username ?? m.pubkey.substring(0, 12);
    final joinDate = (m.joinedAt != null && m.joinedAt!.year > 2000) ? m.joinedAt! : (m.createdAt.year > 2000 ? m.createdAt : null);
    final joined = joinDate != null ? _formatDate(joinDate) : '';
    final memberRoles = _memberRoles ?? [];
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color: c.gray900,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _hovering ? c.gray600 : c.gray800),
        ),
        child: Row(children: [
          GestureDetector(
            onTap: () => widget.onSelect(!widget.selected),
            child: _Checkbox(value: widget.selected, colors: c),
          ),
          const SizedBox(width: 10),
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: validImageUrl(m.avatarUrl) != null ? Colors.transparent : c.gray700,
            ),
            clipBehavior: Clip.antiAlias,
            child: validImageUrl(m.avatarUrl) != null
                ? Image.network(validImageUrl(m.avatarUrl)!, fit: BoxFit.cover, width: 32, height: 32)
                : Center(child: Text(name[0].toUpperCase(), style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w600))),
          ),
          const SizedBox(width: 10),
          Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
            Text('$username${joined.isNotEmpty ? ' \u00b7 Joined $joined' : ''}', style: TextStyle(color: c.gray500, fontSize: 11)),
          ])),
          const SizedBox(width: 12),
          Expanded(flex: 3, child: Wrap(spacing: 4, runSpacing: 4, children: [
            for (final role in memberRoles)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _parseColor(role.color).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _parseColor(role.color).withValues(alpha: 0.4)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: _parseColor(role.color), shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text(role.name ?? '', style: TextStyle(color: _parseColor(role.color), fontSize: 11, fontWeight: FontWeight.w500)),
                ]),
              ),
          ])),
          if (_hovering) ...[
            _linkBtn('History', c.gray400, () => _showHistory(context)),
            _linkBtn('Manage Roles', c.gray400, () => _manageRoles(context)),
            _linkBtn('Timeout', c.gray400, () => _timeoutMember(context)),
            _linkBtn('Kick', c.accent, () => _kickMember(context)),
            _linkBtn('Ban', c.accent, () => _banMember(context)),
          ],
        ]),
      ),
    );
  }

  Future<void> _kickMember(BuildContext context) async {
    final c = widget.colors;
    final m = widget.member;
    final name = m.displayName ?? m.username ?? m.pubkey.substring(0, 8);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(width: 400, padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: c.gray800, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.gray700)),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Kick $name', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text('Are you sure you want to kick $name from the server? They can rejoin with an invite.',
              style: TextStyle(color: c.gray400, fontSize: 14)),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: c.gray400))),
              const SizedBox(width: 8),
              ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Kick', style: TextStyle(color: Colors.white))),
            ]),
          ])),
      ),
    );
    if (confirmed != true) return;

    final auth = ref.read(authServiceProvider);
    final db = ref.read(databaseProvider);
    final publishSvc = ref.read(serverPublishServiceProvider);
    if (auth.privateKeyHex == null) return;

    // Remove from local DB
    await (db.delete(db.remoteMembershipRoles)..where((r) => r.remoteMemberId.equals(m.id))).go();
    await (db.delete(db.remoteMembers)..where((rm) => rm.id.equals(m.id))).go();

    // Publish removal event to relays
    await publishSvc.publishMemberRemoval(
      privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!,
      server: widget.server, targetPubkey: m.pubkey,
    );
  }

  Future<void> _banMember(BuildContext context) async {
    final c = widget.colors;
    final m = widget.member;
    final name = m.displayName ?? m.username ?? m.pubkey.substring(0, 8);
    final reasonCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(width: 400, padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: c.gray800, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.gray700)),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Ban $name', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text('This will permanently ban $name from the server.',
              style: TextStyle(color: c.gray400, fontSize: 14)),
            const SizedBox(height: 12),
            Text('REASON (optional)', style: TextStyle(color: c.gray400, fontSize: 11, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            TextField(controller: reasonCtrl, style: TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(hintText: 'Why are they being banned?', hintStyle: TextStyle(color: c.gray500),
                fillColor: c.gray900, filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.accent)))),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: c.gray400))),
              const SizedBox(width: 8),
              ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Ban', style: TextStyle(color: Colors.white))),
            ]),
          ])),
      ),
    );
    if (confirmed != true) return;

    final auth = ref.read(authServiceProvider);
    final db = ref.read(databaseProvider);
    final publishSvc = ref.read(serverPublishServiceProvider);
    if (auth.privateKeyHex == null) return;

    // Remove member from local DB
    await (db.delete(db.remoteMembershipRoles)..where((r) => r.remoteMemberId.equals(m.id))).go();
    await (db.delete(db.remoteMembers)..where((rm) => rm.id.equals(m.id))).go();

    // Add to bans table
    final now = DateTime.now();
    try {
      await db.into(db.bans).insert(BansCompanion.insert(
        serverId: widget.server.id, userId: 0, bannedById: 0,
        reason: Value(reasonCtrl.text.trim().isEmpty ? null : reasonCtrl.text.trim()),
        createdAt: now, updatedAt: now,
      ));
    } catch (_) {}

    // Publish ban + member removal to relays
    await publishSvc.publishBan(
      privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!,
      server: widget.server, targetPubkey: m.pubkey, reason: reasonCtrl.text.trim(),
    );
    await publishSvc.publishMemberRemoval(
      privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!,
      server: widget.server, targetPubkey: m.pubkey,
    );
    reasonCtrl.dispose();
  }

  Future<void> _showHistory(BuildContext context) async {
    final c = widget.colors;
    final m = widget.member;
    final db = ref.read(databaseProvider);
    final auth = ref.read(authServiceProvider);
    final name = m.displayName ?? m.username ?? m.pubkey.substring(0, 8);
    final username = m.username ?? m.pubkey.substring(0, 12);
    final joinDate = (m.joinedAt != null && m.joinedAt!.year > 2000) ? m.joinedAt! : (m.createdAt.year > 2000 ? m.createdAt : null);
    final memberRoles = _memberRoles ?? [];

    // Fetch all channels + messages by this member
    final channels = await (db.select(db.channels)..where((ch) => ch.serverId.equals(widget.server.id))).get();
    final channelIds = channels.map((ch) => ch.id).toList();
    List<Message> allMessages = [];
    if (channelIds.isNotEmpty) {
      allMessages = await (db.select(db.messages)
        ..where((msg) => msg.nostrAuthorPubkey.equals(m.pubkey) & msg.channelId.isIn(channelIds))
        ..orderBy([(msg) => OrderingTerm.desc(msg.createdAt)])
        ..limit(50)).get();
    }

    // Stats
    final totalMessages = allMessages.length;
    final imageCount = allMessages.where((msg) => msg.fileUrls != null && msg.fileUrls!.isNotEmpty).length;

    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) {
        int? filterChannelId;
        return StatefulBuilder(builder: (ctx, setDialogState) {
          final messages = filterChannelId == null
              ? allMessages
              : allMessages.where((msg) => msg.channelId == filterChannelId).toList();
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 100, vertical: 40),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 700),
              decoration: BoxDecoration(color: c.gray950, borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Back button + close
                Padding(padding: const EdgeInsets.only(left: 20, right: 20, top: 16),
                  child: Row(children: [
                    MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(
                      onTap: () => Navigator.pop(ctx),
                      child: Row(children: [
                        Icon(Icons.chevron_left, color: c.accent, size: 18),
                        const SizedBox(width: 4),
                        Text('Back to Members', style: TextStyle(color: c.accent, fontSize: 13)),
                      ]),
                    )),
                    const Spacer(),
                    GestureDetector(onTap: () => Navigator.pop(ctx),
                      child: Container(width: 32, height: 32, decoration: BoxDecoration(color: c.gray800, shape: BoxShape.circle, border: Border.all(color: c.gray700)),
                        child: Icon(Icons.close, color: c.gray400, size: 16))),
                  ])),

                // Profile header card
                Container(
                  margin: const EdgeInsets.all(20),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [
                    Container(width: 48, height: 48, decoration: BoxDecoration(shape: BoxShape.circle,
                      color: validImageUrl(m.avatarUrl) != null ? Colors.transparent : c.gray700),
                      clipBehavior: Clip.antiAlias,
                      child: validImageUrl(m.avatarUrl) != null
                          ? Image.network(validImageUrl(m.avatarUrl)!, fit: BoxFit.cover, width: 48, height: 48)
                          : Center(child: Text(name[0].toUpperCase(), style: TextStyle(color: c.gray200, fontSize: 20, fontWeight: FontWeight.bold)))),
                    const SizedBox(width: 14),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text(name, style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: c.gray600)),
                          child: Text('Remote', style: TextStyle(color: c.gray400, fontSize: 10))),
                      ]),
                      Text(username, style: TextStyle(color: c.gray500, fontSize: 13)),
                      const SizedBox(height: 4),
                      Text('Joined ${joinDate != null ? _formatDate(joinDate) : 'Unknown'}  ·  Last online ${m.lastSeenAt != null && m.lastSeenAt!.year > 2000 ? _formatDate(m.lastSeenAt!) : 'Never'}',
                        style: TextStyle(color: c.gray500, fontSize: 12)),
                    ])),
                    _linkBtn('Kick', c.accent, () { Navigator.pop(ctx); _kickMember(context); }),
                    _linkBtn('Ban', c.accent, () { Navigator.pop(ctx); _banMember(context); }),
                  ]),
                ),

                // Stats row
                Padding(padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(children: [
                    _statCard('$totalMessages', 'Messages', c),
                    _statCard('$imageCount', 'Images', c),
                    _statCard('0', 'Stickers', c),
                    _statCard('0', 'Links', c),
                  ])),

                const SizedBox(height: 16),

                // Message History header + channel filter
                Padding(padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(children: [
                    Text('Message History', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 16),
                    Expanded(child: DropdownButtonFormField<int?>(
                      value: filterChannelId, dropdownColor: c.gray900,
                      style: TextStyle(color: c.gray200, fontSize: 13),
                      decoration: InputDecoration(fillColor: c.gray900, filled: true, contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700))),
                      items: [
                        DropdownMenuItem<int?>(value: null, child: Text('All Channels')),
                        ...channels.map((ch) => DropdownMenuItem<int?>(value: ch.id, child: Text('#${ch.name}'))),
                      ],
                      onChanged: (v) => setDialogState(() => filterChannelId = v),
                    )),
                  ])),

                const SizedBox(height: 8),

                // Message list
                Expanded(child: messages.isEmpty
                  ? Center(child: Text('No messages found.', style: TextStyle(color: c.gray500)))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      itemCount: messages.length,
                      itemBuilder: (ctx, i) {
                        final msg = messages[i];
                        final ch = channels.where((ch) => ch.id == msg.channelId).firstOrNull;
                        final time = msg.createdAt.toLocal();
                        final timeStr = '${_formatDate(time)} ${time.hour}:${time.minute.toString().padLeft(2, '0')} ${time.hour >= 12 ? 'PM' : 'AM'}';
                        return Padding(padding: const EdgeInsets.only(bottom: 16), child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('#${ch?.name ?? '?'}  ·  $timeStr', style: TextStyle(color: c.gray500, fontSize: 12)),
                            const SizedBox(height: 6),
                            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Container(
                                width: 32, height: 32,
                                decoration: BoxDecoration(shape: BoxShape.circle,
                                  color: validImageUrl(m.avatarUrl) != null ? Colors.transparent : c.gray700),
                                clipBehavior: Clip.antiAlias,
                                child: validImageUrl(m.avatarUrl) != null
                                    ? Image.network(validImageUrl(m.avatarUrl)!, fit: BoxFit.cover, width: 32, height: 32)
                                    : Center(child: Text(name[0].toUpperCase(), style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w600))),
                              ),
                              const SizedBox(width: 10),
                              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Row(children: [
                                  Text(name, style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                                  const SizedBox(width: 8),
                                  Text(timeStr, style: TextStyle(color: c.gray600, fontSize: 11)),
                                ]),
                                const SizedBox(height: 2),
                                MessageContent(content: msg.content ?? '', colors: c),
                              ])),
                            ]),
                          ],
                        ));
                      },
                    )),
                const SizedBox(height: 16),
              ]),
            ),
          );
        });
      },
    );
  }

  Widget _statCard(String value, String label, InfernoColors c) => Expanded(child: Container(
    padding: const EdgeInsets.symmetric(vertical: 12),
    margin: const EdgeInsets.only(right: 4),
    decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(6)),
    child: Column(children: [
      Text(value, style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
      Text(label, style: TextStyle(color: c.gray500, fontSize: 12)),
    ]),
  ));

  Future<void> _manageRoles(BuildContext context) async {
    final c = widget.colors;
    final m = widget.member;
    final db = ref.read(databaseProvider);
    final auth = ref.read(authServiceProvider);
    final name = m.displayName ?? m.username ?? m.pubkey.substring(0, 8);

    // Get current role assignments
    final assignments = await (db.select(db.remoteMembershipRoles)
      ..where((r) => r.remoteMemberId.equals(m.id))).get();
    final assignedRoleIds = assignments.map((a) => a.roleId).toSet();

    // Determine the current user's highest role position for hierarchy enforcement
    int myHighestPosition = 0;
    Set<int> myRoleIds = {};
    if (auth.publicKeyHex != null) {
      final myMember = await (db.select(db.remoteMembers)
        ..where((rm) => rm.pubkey.equals(auth.publicKeyHex!) & rm.serverId.equals(widget.server.id))).getSingleOrNull();
      if (myMember != null) {
        final myAssignments = await (db.select(db.remoteMembershipRoles)
          ..where((r) => r.remoteMemberId.equals(myMember.id))).get();
        myRoleIds = myAssignments.map((a) => a.roleId).toSet();
        for (final role in widget.roles) {
          if (myRoleIds.contains(role.id) && (role.position ?? 0) > myHighestPosition) {
            myHighestPosition = role.position ?? 0;
          }
        }
        // Owner role gets max position
        final hasOwnerRole = widget.roles.any((r) =>
          r.name?.toLowerCase() == 'owner' && myRoleIds.contains(r.id));
        if (hasOwnerRole) myHighestPosition = 999;
      }
    }

    // Filter: exclude Owner role, sort by position descending
    final editableRoles = widget.roles
        .where((r) => r.name?.toLowerCase() != 'owner')
        .toList()
      ..sort((a, b) => (b.position ?? 0).compareTo(a.position ?? 0));

    if (!context.mounted) return;
    final result = await showDialog<Set<int>>(
      context: context,
      builder: (ctx) {
        final selected = Set<int>.from(assignedRoleIds);
        return StatefulBuilder(builder: (ctx, setDialogState) => Dialog(
          backgroundColor: Colors.transparent,
          child: Container(width: 360, padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: c.gray800, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.gray700)),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Manage Roles — $name', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              for (final role in editableRoles) ...[
                () {
                  // Can only toggle roles below our own position
                  final canEdit = (role.position ?? 0) < myHighestPosition;
                  return GestureDetector(
                    onTap: canEdit ? () => setDialogState(() {
                      if (selected.contains(role.id)) { selected.remove(role.id); } else { selected.add(role.id); }
                    }) : null,
                    child: Opacity(
                      opacity: canEdit ? 1.0 : 0.4,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(children: [
                          Container(
                            width: 18, height: 18,
                            decoration: BoxDecoration(
                              color: selected.contains(role.id) ? _parseColor(role.color) : Colors.transparent,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: selected.contains(role.id) ? _parseColor(role.color) : c.gray600),
                            ),
                            child: selected.contains(role.id) ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
                          ),
                          const SizedBox(width: 10),
                          Container(width: 10, height: 10, decoration: BoxDecoration(color: _parseColor(role.color), shape: BoxShape.circle)),
                          const SizedBox(width: 8),
                          Text(role.name ?? '', style: TextStyle(color: canEdit ? c.gray200 : c.gray600, fontSize: 14)),
                          if (!canEdit) ...[
                            const SizedBox(width: 8),
                            Icon(Icons.lock_outline, size: 12, color: c.gray600),
                          ],
                        ]),
                      ),
                    ),
                  );
                }(),
              ],
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: c.gray400))),
                const SizedBox(width: 8),
                ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                  onPressed: () => Navigator.pop(ctx, selected),
                  child: const Text('Save', style: TextStyle(color: Colors.white))),
              ]),
            ])),
        ));
      },
    );

    if (result == null || auth.privateKeyHex == null) return;

    // Update local DB: remove old assignments, add new ones
    await (db.delete(db.remoteMembershipRoles)..where((r) => r.remoteMemberId.equals(m.id))).go();
    final now = DateTime.now();
    for (final roleId in result) {
      try {
        await db.into(db.remoteMembershipRoles).insert(RemoteMembershipRolesCompanion.insert(
          remoteMemberId: m.id, roleId: roleId, createdAt: now, updatedAt: now,
        ));
      } catch (_) {}
    }

    // Publish to relays
    final rolePublicIds = <String>[];
    for (final roleId in result) {
      final role = widget.roles.where((r) => r.id == roleId).firstOrNull;
      if (role?.publicId != null) rolePublicIds.add(role!.publicId);
    }
    final publishSvc = ref.read(serverPublishServiceProvider);
    await publishSvc.publishMemberRoleUpdate(
      privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!,
      server: widget.server, targetPubkey: m.pubkey, rolePublicIds: rolePublicIds,
    );

    // Reload roles
    _loadMemberRoles();
  }

  Future<void> _timeoutMember(BuildContext context) async {
    final c = widget.colors;
    final m = widget.member;
    final name = m.displayName ?? m.username ?? m.pubkey.substring(0, 8);

    const durations = {
      '60 seconds': 60,
      '5 minutes': 300,
      '10 minutes': 600,
      '1 hour': 3600,
      '1 day': 86400,
      '1 week': 604800,
    };

    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(width: 320, padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: c.gray800, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.gray700)),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Timeout $name', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Member will be unable to send messages for the duration.', style: TextStyle(color: c.gray500, fontSize: 13)),
            const SizedBox(height: 16),
            for (final entry in durations.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => Navigator.pop(ctx, entry.value),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(6)),
                      child: Text(entry.key, style: TextStyle(color: c.gray200, fontSize: 14)),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: c.gray400))),
          ])),
      ),
    );
    if (result == null) return;

    // Timeout is application-level state (not stored in Nostr events).
    // For now, publish a member update event. The timeout is enforced
    // by the message-sending gate on each instance.
    final timeoutUntil = DateTime.now().add(Duration(seconds: result));
    debugPrint('[ServerSettings] Timed out ${m.pubkey.substring(0, 8)} until $timeoutUntil');
  }
}

// ── Invites Panel ───────────────────────────────────────
class _InvitesPanel extends ConsumerStatefulWidget {
  final Server server;
  final InfernoColors colors;
  const _InvitesPanel({required this.server, required this.colors});
  @override
  ConsumerState<_InvitesPanel> createState() => _InvitesPanelState();
}
class _InvitesPanelState extends ConsumerState<_InvitesPanel> {
  bool _canManageInvites = false;
  bool _canCreateInvite = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    final auth = ref.read(authServiceProvider);
    if (auth.publicKeyHex == null) return;
    final permSvc = ref.read(permissionServiceProvider);
    final sid = widget.server.id;
    final pk = auth.publicKeyHex!;
    final results = await Future.wait([
      permSvc.hasPermission(sid, pk, Permission.manageInvites),
      permSvc.hasPermission(sid, pk, Permission.createInvite),
    ]);
    if (mounted) {
      setState(() {
        _canManageInvites = results[0];
        _canCreateInvite = results[1];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final inviteService = ref.watch(inviteServiceProvider);
    final c = widget.colors;
    return StreamBuilder<List<Invite>>(
      stream: inviteService.watchInvites(widget.server.id),
      builder: (context, snapshot) {
        final invites = snapshot.data ?? [];
        final active = invites.where((i) => i.active).toList();
        return ListView(children: [
          Text('Invites', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          if (_canCreateInvite)
            _InviteCreateCard(server: widget.server, colors: c),
          const SizedBox(height: 24),
          _label('ACTIVE INVITES (${active.length})', c),
          const SizedBox(height: 12),
          for (final inv in active)
            _InviteRow(invite: inv, server: widget.server, colors: c, canManageInvites: _canManageInvites),
          if (active.isEmpty)
            Padding(padding: const EdgeInsets.all(32),
              child: Text('No invites yet. Generate one to share.', style: TextStyle(color: c.gray500, fontSize: 14))),
        ]);
      },
    );
  }
}

class _InviteRow extends ConsumerWidget {
  final Invite invite;
  final Server server;
  final InfernoColors colors;
  final bool canManageInvites;
  const _InviteRow({required this.invite, required this.server, required this.colors, this.canManageInvites = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = colors;
    final auth = ref.watch(authServiceProvider);
    final inviteService = ref.read(inviteServiceProvider);

    // Generate the shareable link
    final link = auth.publicKeyHex != null
        ? inviteService.generateInviteLink(invite: invite, server: server, creatorPubkey: auth.publicKeyHex!)
        : invite.code;

    // Status info
    final usesText = invite.maxUses != null
        ? '${invite.usesCount}/${invite.maxUses} uses'
        : '${invite.usesCount} uses';
    final expiryText = invite.expiresAt != null
        ? (invite.expiresAt!.isBefore(DateTime.now()) ? 'Expired' : 'Expires in ${_timeUntil(invite.expiresAt!)}')
        : 'Never expires';

    return Container(
      padding: const EdgeInsets.all(12), margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Link (selectable, truncated)
        SelectableText(
          link.length > 60 ? '${link.substring(0, 60)}...' : link,
          style: TextStyle(color: c.gray200, fontSize: 13, fontFamily: 'monospace'),
        ),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: Text('${_timeAgo(invite.createdAt)} \u00b7 $usesText \u00b7 $expiryText',
            style: TextStyle(color: c.gray500, fontSize: 12))),
          GestureDetector(
            onTap: () => Clipboard.setData(ClipboardData(text: link)),
            child: MouseRegion(cursor: SystemMouseCursors.click,
              child: Text('Copy', style: TextStyle(color: c.accent, fontSize: 13))),
          ),
          if (canManageInvites) ...[
            const SizedBox(width: 12),
            GestureDetector(
              onTap: () async {
                if (auth.privateKeyHex == null) return;
                await inviteService.revokeInvite(
                  privateKeyHex: auth.privateKeyHex!,
                  publicKeyHex: auth.publicKeyHex!,
                  invite: invite,
                  server: server,
                );
              },
              child: MouseRegion(cursor: SystemMouseCursors.click,
                child: Text('Revoke', style: TextStyle(color: c.accent, fontSize: 13))),
            ),
          ],
        ]),
      ]),
    );
  }
}
class _InviteCreateCard extends ConsumerStatefulWidget {
  final Server server;
  final InfernoColors colors;
  const _InviteCreateCard({required this.server, required this.colors});
  @override
  ConsumerState<_InviteCreateCard> createState() => _InviteCreateCardState();
}
class _InviteCreateCardState extends ConsumerState<_InviteCreateCard> {
  String _expiry = 'never';
  String _maxUses = 'unlimited';
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('GENERATE A NEW INVITE', style: TextStyle(color: c.gray400, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('EXPIRE AFTER', style: TextStyle(color: c.gray400, fontSize: 11, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              value: _expiry, dropdownColor: c.gray900,
              style: TextStyle(color: c.gray200, fontSize: 14),
              decoration: _inputDecor(c),
              items: const [
                DropdownMenuItem(value: 'never', child: Text('Never')),
                DropdownMenuItem(value: '30m', child: Text('30 minutes')),
                DropdownMenuItem(value: '1h', child: Text('1 hour')),
                DropdownMenuItem(value: '6h', child: Text('6 hours')),
                DropdownMenuItem(value: '12h', child: Text('12 hours')),
                DropdownMenuItem(value: '1d', child: Text('1 day')),
                DropdownMenuItem(value: '7d', child: Text('7 days')),
              ],
              onChanged: (v) => setState(() => _expiry = v!),
            ),
          ])),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('MAX USES', style: TextStyle(color: c.gray400, fontSize: 11, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              value: _maxUses, dropdownColor: c.gray900,
              style: TextStyle(color: c.gray200, fontSize: 14),
              decoration: _inputDecor(c),
              items: const [
                DropdownMenuItem(value: 'unlimited', child: Text('Unlimited')),
                DropdownMenuItem(value: '1', child: Text('1 use')),
                DropdownMenuItem(value: '5', child: Text('5 uses')),
                DropdownMenuItem(value: '10', child: Text('10 uses')),
                DropdownMenuItem(value: '25', child: Text('25 uses')),
                DropdownMenuItem(value: '50', child: Text('50 uses')),
                DropdownMenuItem(value: '100', child: Text('100 uses')),
              ],
              onChanged: (v) => setState(() => _maxUses = v!),
            ),
          ])),
          const SizedBox(width: 12),
          Padding(padding: const EdgeInsets.only(top: 18), child: ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: c.accent, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
            onPressed: () => _generate(),
            child: const Text('Generate Invite', style: TextStyle(color: Colors.white)),
          )),
        ]),
      ]),
    );
  }
  DateTime? _parseExpiry(String value) {
    final now = DateTime.now();
    switch (value) {
      case '30m': return now.add(const Duration(minutes: 30));
      case '1h': return now.add(const Duration(hours: 1));
      case '6h': return now.add(const Duration(hours: 6));
      case '12h': return now.add(const Duration(hours: 12));
      case '1d': return now.add(const Duration(days: 1));
      case '7d': return now.add(const Duration(days: 7));
      default: return null;
    }
  }

  int? _parseMaxUses(String value) {
    if (value == 'unlimited') return null;
    return int.tryParse(value);
  }

  Future<void> _generate() async {
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null) return;
    final inviteService = ref.read(inviteServiceProvider);
    try {
      await inviteService.createInvite(
        privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!,
        server: widget.server, creatorId: 1,
        maxUses: _parseMaxUses(_maxUses),
        expiresAt: _parseExpiry(_expiry),
      );
    } catch (_) {}
  }
}

// ── Bans Panel ──────────────────────────────────────────
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
            child: Text('No banned users.', style: TextStyle(color: c.gray500, fontSize: 14))),
      ]),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e', style: TextStyle(color: c.accent))),
    );
  }
}

/// Resolve a pubkey to a display name from remoteMembers or contacts.
Future<String> _resolveCreatorName(InfernoDatabase db, int serverId, String? pubkey) async {
  if (pubkey == null || pubkey.isEmpty) return 'Unknown';
  final member = await (db.select(db.remoteMembers)
        ..where((m) => m.serverId.equals(serverId) & m.pubkey.equals(pubkey))
        ..limit(1))
      .getSingleOrNull();
  if (member != null) return member.displayName ?? member.username ?? '${pubkey.substring(0, 8)}...';
  final contact = await db.contactsDao.getByPubkey(pubkey);
  if (contact != null) return contact.displayName ?? contact.username ?? '${pubkey.substring(0, 8)}...';
  return '${pubkey.substring(0, 8)}...';
}

// ── Emojis Panel ────────────────────────────────────────
class _EmojisPanel extends ConsumerStatefulWidget {
  final Server server;
  final InfernoColors colors;
  const _EmojisPanel({required this.server, required this.colors});
  @override
  ConsumerState<_EmojisPanel> createState() => _EmojisPanelState();
}
class _EmojisPanelState extends ConsumerState<_EmojisPanel> {
  final _nameCtrl = TextEditingController();
  bool _uploading = false;
  String? _previewPath;
  String? _pickedFilePath;
  final Map<String, String> _creatorNames = {};
  bool _canCreate = false;

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    final auth = ref.read(authServiceProvider);
    if (auth.publicKeyHex == null) return;
    final can = await ref.read(permissionServiceProvider)
        .hasPermission(widget.server.id, auth.publicKeyHex!, Permission.createEmojis);
    if (mounted) setState(() => _canCreate = can);
  }

  @override
  void dispose() { _nameCtrl.dispose(); super.dispose(); }

  Future<void> _resolveCreators(List<ServerEmoji> emojis) async {
    final db = ref.read(databaseProvider);
    for (final e in emojis) {
      final pk = e.creatorPubkey;
      if (pk != null && !_creatorNames.containsKey(pk)) {
        _creatorNames[pk] = await _resolveCreatorName(db, widget.server.id, pk);
      }
    }
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['png', 'gif', 'webp'],
    );
    if (result == null || result.files.first.path == null) return;
    final fileSize = result.files.first.size;
    if (fileSize > 256 * 1024) return;
    final file = result.files.first;
    if (_nameCtrl.text.trim().isEmpty) {
      _nameCtrl.text = file.name.split('.').first.toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
          .replaceAll(RegExp(r'_+'), '_')
          .replaceAll(RegExp(r'^_|_$'), '');
    }
    setState(() { _pickedFilePath = file.path; _previewPath = file.path; });
  }

  Future<void> _upload() async {
    if (_pickedFilePath == null) { _pickFile(); return; }
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null) return;
    setState(() => _uploading = true);
    final emojiName = _nameCtrl.text.trim().isNotEmpty
        ? _nameCtrl.text.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_')
        : _pickedFilePath!.split('/').last.split('.').first.toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    final url = await BlossomClient.uploadFile(
      filePath: _pickedFilePath!, privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!,
    );
    if (url != null) {
      final db = ref.read(databaseProvider);
      final now = DateTime.now();
      final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
      await db.into(db.serverEmojis).insert(ServerEmojisCompanion.insert(
        publicId: publicId, serverId: widget.server.id, name: emojiName, creatorId: 0,
        creatorPubkey: Value(auth.publicKeyHex),
        url: Value(url), createdAt: now, updatedAt: now,
      ));
      _nameCtrl.clear();
      setState(() { _pickedFilePath = null; _previewPath = null; });
    }
    if (mounted) setState(() => _uploading = false);
  }

  Future<void> _deleteEmoji(ServerEmoji emoji) async {
    final db = ref.read(databaseProvider);
    await (db.delete(db.serverEmojis)..where((e) => e.id.equals(emoji.id))).go();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final db = ref.watch(databaseProvider);
    return StreamBuilder<List<ServerEmoji>>(
      stream: (db.select(db.serverEmojis)..where((e) => e.serverId.equals(widget.server.id))).watch(),
      builder: (context, snapshot) {
        final emojis = snapshot.data ?? [];
        _resolveCreators(emojis);
        return ListView(padding: EdgeInsets.zero, children: [
          Text('Emojis', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          // Upload form (only if user has createEmojis permission)
          if (_canCreate)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                GestureDetector(
                  onTap: _pickFile,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      width: 48, height: 48,
                      decoration: BoxDecoration(
                        color: c.gray800, borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: c.gray700),
                      ),
                      child: _previewPath != null
                          ? ClipRRect(borderRadius: BorderRadius.circular(8),
                              child: Image.file(File(_previewPath!), fit: BoxFit.contain))
                          : Icon(Icons.add_photo_alternate_outlined, size: 24, color: c.gray600),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  TextField(controller: _nameCtrl, style: TextStyle(color: Colors.white, fontSize: 14),
                    decoration: _inputDecor(c, hint: 'emoji_name')),
                  const SizedBox(height: 8),
                  Row(children: [
                    Text('PNG, GIF, WebP. Max 256KB.', style: TextStyle(color: c.gray500, fontSize: 12)),
                    const Spacer(),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                      onPressed: _uploading ? null : _upload,
                      child: Text(_uploading ? 'Uploading...' : 'Upload', style: const TextStyle(color: Colors.white))),
                  ]),
                ])),
              ]),
            ),
          const SizedBox(height: 24),
          _label('EMOJIS (${emojis.length}/50)', c),
          const SizedBox(height: 12),
          // Row card list
          for (final emoji in emojis)
            _AssetRow(
              imageUrl: emoji.url,
              name: ':${emoji.name}:',
              subtitle: 'by ${_creatorNames[emoji.creatorPubkey] ?? 'Unknown'}',
              colors: c,
              imageSize: 40,
              onDelete: _canCreate ? () => _deleteEmoji(emoji) : null,
            ),
          if (emojis.isEmpty)
            Padding(padding: const EdgeInsets.all(32),
              child: Text('No custom emojis yet.', style: TextStyle(color: c.gray500, fontSize: 14))),
        ]);
      },
    );
  }
}

// ── Stickers Panel ──────────────────────────────────────
class _StickersPanel extends ConsumerStatefulWidget {
  final Server server;
  final InfernoColors colors;
  const _StickersPanel({required this.server, required this.colors});
  @override
  ConsumerState<_StickersPanel> createState() => _StickersPanelState();
}
class _StickersPanelState extends ConsumerState<_StickersPanel> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  bool _uploading = false;
  String? _previewPath;
  String? _pickedFilePath;
  final Map<String, String> _creatorNames = {};
  bool _canCreate = false;

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    final auth = ref.read(authServiceProvider);
    if (auth.publicKeyHex == null) return;
    final can = await ref.read(permissionServiceProvider)
        .hasPermission(widget.server.id, auth.publicKeyHex!, Permission.createStickers);
    if (mounted) setState(() => _canCreate = can);
  }

  @override
  void dispose() { _nameCtrl.dispose(); _descCtrl.dispose(); super.dispose(); }

  Future<void> _resolveCreators(List<ServerSticker> stickers) async {
    final db = ref.read(databaseProvider);
    for (final s in stickers) {
      final pk = s.creatorPubkey;
      if (pk != null && !_creatorNames.containsKey(pk)) {
        _creatorNames[pk] = await _resolveCreatorName(db, widget.server.id, pk);
      }
    }
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['png', 'gif', 'webp'],
    );
    if (result == null || result.files.first.path == null) return;
    final fileSize = result.files.first.size;
    if (fileSize > 512 * 1024) return;
    final file = result.files.first;
    if (_nameCtrl.text.trim().isEmpty) {
      _nameCtrl.text = file.name.split('.').first
          .replaceAll(RegExp(r'[-_]'), ' ')
          .replaceAllMapped(RegExp(r'\b\w'), (m) => m.group(0)!.toUpperCase());
    }
    setState(() { _pickedFilePath = file.path; _previewPath = file.path; });
  }

  Future<void> _upload() async {
    if (_pickedFilePath == null) { _pickFile(); return; }
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null) return;
    setState(() => _uploading = true);
    final stickerName = _nameCtrl.text.trim().isNotEmpty
        ? _nameCtrl.text.trim()
        : _pickedFilePath!.split('/').last.split('.').first;
    final url = await BlossomClient.uploadFile(
      filePath: _pickedFilePath!, privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!,
    );
    if (url != null) {
      final db = ref.read(databaseProvider);
      final now = DateTime.now();
      final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
      await db.into(db.serverStickers).insert(ServerStickersCompanion.insert(
        publicId: publicId, serverId: widget.server.id, name: stickerName, creatorId: 0,
        creatorPubkey: Value(auth.publicKeyHex),
        description: _descCtrl.text.trim().isNotEmpty ? Value(_descCtrl.text.trim()) : const Value.absent(),
        url: Value(url), createdAt: now, updatedAt: now,
      ));
      _nameCtrl.clear();
      _descCtrl.clear();
      setState(() { _pickedFilePath = null; _previewPath = null; });
    }
    if (mounted) setState(() => _uploading = false);
  }

  Future<void> _deleteSticker(ServerSticker sticker) async {
    final db = ref.read(databaseProvider);
    await (db.delete(db.serverStickers)..where((s) => s.id.equals(sticker.id))).go();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final db = ref.watch(databaseProvider);
    return StreamBuilder<List<ServerSticker>>(
      stream: (db.select(db.serverStickers)..where((s) => s.serverId.equals(widget.server.id))).watch(),
      builder: (context, snap) {
        final stickers = snap.data ?? [];
        _resolveCreators(stickers);
        return ListView(padding: EdgeInsets.zero, children: [
          Text('Stickers', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          // Upload form (only if user has createStickers permission)
          if (_canCreate)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                GestureDetector(
                  onTap: _pickFile,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      width: 80, height: 80,
                      decoration: BoxDecoration(
                        color: c.gray800, borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: c.gray700),
                      ),
                      child: _previewPath != null
                          ? ClipRRect(borderRadius: BorderRadius.circular(8),
                              child: Image.file(File(_previewPath!), fit: BoxFit.contain))
                          : Icon(Icons.add_photo_alternate_outlined, size: 32, color: c.gray600),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  TextField(controller: _nameCtrl, style: TextStyle(color: Colors.white, fontSize: 14),
                    decoration: _inputDecor(c, hint: 'Sticker name')),
                  const SizedBox(height: 8),
                  TextField(controller: _descCtrl, style: TextStyle(color: Colors.white, fontSize: 14),
                    decoration: _inputDecor(c, hint: 'Description (optional)')),
                  const SizedBox(height: 8),
                  Row(children: [
                    Text('PNG, GIF, WebP. Max 512KB.', style: TextStyle(color: c.gray500, fontSize: 12)),
                    const Spacer(),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                      onPressed: _uploading ? null : _upload,
                      child: Text(_uploading ? 'Uploading...' : 'Upload', style: const TextStyle(color: Colors.white))),
                  ]),
                ])),
              ]),
            ),
          const SizedBox(height: 24),
          _label('STICKERS (${stickers.length}/30)', c),
          const SizedBox(height: 12),
          // Row card list
          for (final sticker in stickers)
            _AssetRow(
              imageUrl: sticker.url,
              name: sticker.name,
              subtitle: 'by ${_creatorNames[sticker.creatorPubkey] ?? 'Unknown'}',
              colors: c,
              imageSize: 56,
              onDelete: _canCreate ? () => _deleteSticker(sticker) : null,
            ),
          if (stickers.isEmpty)
            Padding(padding: const EdgeInsets.all(32),
              child: Text('No stickers yet.', style: TextStyle(color: c.gray500, fontSize: 14))),
        ]);
      },
    );
  }
}

/// Shared row card for emoji/sticker lists — image, name, creator, delete on hover.
class _AssetRow extends StatefulWidget {
  final String? imageUrl;
  final String name;
  final String subtitle;
  final InfernoColors colors;
  final double imageSize;
  final VoidCallback? onDelete;
  const _AssetRow({this.imageUrl, required this.name, required this.subtitle,
    required this.colors, required this.imageSize, this.onDelete});
  @override
  State<_AssetRow> createState() => _AssetRowState();
}
class _AssetRowState extends State<_AssetRow> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: _hovered ? c.gray900 : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          Container(
            width: widget.imageSize, height: widget.imageSize,
            decoration: BoxDecoration(color: c.gray800, borderRadius: BorderRadius.circular(6)),
            child: widget.imageUrl != null
                ? ClipRRect(borderRadius: BorderRadius.circular(6),
                    child: Image.network(widget.imageUrl!, fit: BoxFit.contain))
                : Icon(Icons.image, size: widget.imageSize * 0.5, color: c.gray600),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(widget.name, style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(widget.subtitle, style: TextStyle(color: c.gray500, fontSize: 12)),
          ])),
          if (_hovered && widget.onDelete != null)
            GestureDetector(
              onTap: widget.onDelete,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.delete_outline, size: 18, color: Colors.red.withValues(alpha: 0.7)),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

// ── Audit Log Panel ─────────────────────────────────────
class _AuditLogPanel extends ConsumerStatefulWidget {
  final Server server;
  final InfernoColors colors;
  const _AuditLogPanel({required this.server, required this.colors});
  @override
  ConsumerState<_AuditLogPanel> createState() => _AuditLogPanelState();
}

class _AuditLogPanelState extends ConsumerState<_AuditLogPanel> {
  Map<String, String> _nameCache = {};

  Future<void> _resolveNames(InfernoDatabase db, List<NostrEventLog> events) async {
    final pubkeys = events.map((e) => e.pubkey).toSet();
    final resolved = <String, String>{};
    if (pubkeys.isEmpty) return;

    // Check remote_members for this server
    final members = await (db.select(db.remoteMembers)
          ..where((m) => m.serverId.equals(widget.server.id) & m.pubkey.isIn(pubkeys.toList())))
        .get();
    for (final m in members) {
      final name = m.displayName ?? m.username;
      if (name != null && name.isNotEmpty) resolved[m.pubkey] = name;
    }

    // Fall back to contacts for unresolved
    final unresolved = pubkeys.where((p) => !resolved.containsKey(p)).toList();
    if (unresolved.isNotEmpty) {
      final contacts = await (db.select(db.contacts)
            ..where((c) => c.pubkey.isIn(unresolved)))
          .get();
      for (final c in contacts) {
        final name = c.displayName ?? c.username;
        if (name != null && name.isNotEmpty) resolved[c.pubkey] = name;
      }
    }

    if (mounted) setState(() => _nameCache = resolved);
  }

  String _displayName(String pubkey) {
    return _nameCache[pubkey] ?? '${pubkey.substring(0, 12)}...';
  }

  static String _describeKind(int kind) {
    switch (kind) {
      case 31750: return 'updated server settings';
      case 31751: return 'updated channels';
      case 31752: return 'updated roles';
      case 31753: return 'updated a member';
      case 31754: return 'updated emojis';
      case 31755: return 'updated stickers';
      case 31756: return 'updated bans';
      case 31757: return 'updated invites';
      default: return 'performed action (kind $kind)';
    }
  }

  static (IconData, Color) _kindStyle(int kind) {
    switch (kind) {
      case 31750: return (Icons.edit_outlined, Colors.blue);
      case 31751: return (Icons.edit_outlined, Colors.blue);
      case 31752: return (Icons.edit_outlined, Colors.purple);
      case 31753: return (Icons.person_outline, Colors.green);
      case 31754: return (Icons.edit_outlined, Colors.orange);
      case 31755: return (Icons.edit_outlined, Colors.orange);
      case 31756: return (Icons.block, Colors.red);
      case 31757: return (Icons.link, Colors.cyan);
      default: return (Icons.info_outline, Colors.grey);
    }
  }

  static String _formatDate(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final db = ref.watch(databaseProvider);
    const adminKinds = [31750, 31751, 31752, 31753, 31754, 31755, 31756, 31757];
    return StreamBuilder<List<NostrEventLog>>(
      stream: (db.select(db.nostrEventLogs)
        ..where((e) => e.serverId.equals(widget.server.id) & e.kind.isIn(adminKinds))
        ..orderBy([(e) => OrderingTerm.desc(e.eventCreatedAt)])
        ..limit(50)).watch(),
      builder: (context, snap) {
        final events = snap.data ?? [];
        // Resolve names whenever events change
        if (events.isNotEmpty) {
          _resolveNames(db, events);
        }
        return ListView(children: [
          Text('Audit Log', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('Recent actions and events for this server.', style: TextStyle(color: c.gray400, fontSize: 14)),
          const SizedBox(height: 24),
          if (events.isEmpty)
            Padding(padding: const EdgeInsets.all(32),
              child: Text('No audit log entries yet.', style: TextStyle(color: c.gray500, fontSize: 14))),
          for (final event in events)
            _buildLogRow(c, event),
        ]);
      },
    );
  }

  Widget _buildLogRow(InfernoColors c, NostrEventLog event) {
    final (icon, color) = _kindStyle(event.kind);
    final ts = event.eventCreatedAt ?? event.createdAt;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(child: RichText(text: TextSpan(children: [
          TextSpan(text: _displayName(event.pubkey),
            style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w600)),
          TextSpan(text: ' ${_describeKind(event.kind)}',
            style: TextStyle(color: c.gray400, fontSize: 14)),
        ]))),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_timeAgo(ts), style: TextStyle(color: c.gray500, fontSize: 12)),
          Text(_formatDate(ts), style: TextStyle(color: c.gray600, fontSize: 11)),
        ]),
      ]),
    );
  }
}

// ── Delete Panel ────────────────────────────────────────
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
      SizedBox(width: 200, child: ElevatedButton(
        style: ElevatedButton.styleFrom(backgroundColor: c.accent),
        onPressed: () => _confirmDelete(context, ref),
        child: const Text('Delete Server', style: TextStyle(color: Colors.white)),
      )),
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
        Navigator.pop(context);
        Navigator.pop(context);
      }
    }
  }
}

// ── Shared Widgets ──────────────────────────────────────
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
        _Checkbox(value: value, colors: c),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(color: c.gray200, fontSize: 14)),
          Text(description, style: TextStyle(color: c.gray500, fontSize: 12)),
        ])),
      ]),
    );
  }
}
class _Checkbox extends StatelessWidget {
  final bool value;
  final InfernoColors colors;
  const _Checkbox({required this.value, required this.colors});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18, height: 18,
      decoration: BoxDecoration(
        color: value ? colors.accent : colors.gray900,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: value ? colors.accent : colors.gray700),
      ),
      child: value ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
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
Widget _badge(String text, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
  decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), color: color.withValues(alpha: 0.15)),
  child: Text(text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)));

class _RadioOption extends StatelessWidget {
  final String label; final String value; final String groupValue;
  final InfernoColors colors; final ValueChanged<String> onChanged;
  const _RadioOption({required this.label, required this.value, required this.groupValue, required this.colors, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final sel = value == groupValue;
    return GestureDetector(onTap: () => onChanged(value), child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 18, height: 18, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: sel ? colors.accent : colors.gray700, width: 2)),
        child: sel ? Center(child: Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: colors.accent))) : null),
      const SizedBox(width: 6), Text(label, style: TextStyle(color: colors.gray200, fontSize: 14)),
    ]));
  }
}
Widget _tabBtn(String label, bool active, InfernoColors c, VoidCallback onTap) => GestureDetector(onTap: onTap, child: Container(
  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
  decoration: BoxDecoration(color: active ? c.gray600 : Colors.transparent, borderRadius: BorderRadius.circular(4), border: active ? null : Border.all(color: c.gray700)),
  child: Text(label, style: TextStyle(color: active ? Colors.white : c.gray400, fontSize: 13, fontWeight: active ? FontWeight.w600 : FontWeight.w400))));

Widget _linkBtn(String label, Color color, VoidCallback onTap) => Padding(padding: const EdgeInsets.only(left: 6),
  child: GestureDetector(onTap: onTap, child: MouseRegion(cursor: SystemMouseCursors.click,
    child: Text(label, style: TextStyle(color: color, fontSize: 12, decoration: TextDecoration.underline)))));
