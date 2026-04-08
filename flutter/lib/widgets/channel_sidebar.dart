import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../database/database.dart';
import '../models/permission.dart';
import '../providers/database_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/servers_provider.dart';
import '../providers/server_settings_provider.dart';
import '../services/auth_service.dart';
import '../services/invite_service.dart';
import '../services/presence_service.dart';
import '../providers/realtime_provider.dart';
import '../providers/app_update_provider.dart';
import '../theme/all_themes.dart';
import '../theme/theme_provider.dart';
import '../screens/settings/settings_overlay.dart';
import '../screens/server_settings/server_settings_overlay.dart';
import 'channel_reorder.dart';

// Voice permission state for sidebar controls
class _VoicePerms {
  final bool canSpeak;
  final bool canVideo;
  final bool canScreenShare;
  const _VoicePerms({this.canSpeak = true, this.canVideo = true, this.canScreenShare = true});
}

final _voicePermsProvider = FutureProvider.family<_VoicePerms, int>((ref, serverId) async {
  final auth = ref.read(authServiceProvider);
  if (auth.publicKeyHex == null) return const _VoicePerms();
  final permSvc = ref.read(permissionServiceProvider);
  final pk = auth.publicKeyHex!;
  final results = await Future.wait([
    permSvc.hasPermission(serverId, pk, Permission.speak),
    permSvc.hasPermission(serverId, pk, Permission.video),
    permSvc.hasPermission(serverId, pk, Permission.screenShare),
  ]);
  return _VoicePerms(canSpeak: results[0], canVideo: results[1], canScreenShare: results[2]);
});

/// Show the invite dialog for a server. Callable from anywhere.
void showInviteDialog({
  required BuildContext context,
  required Server server,
  required InfernoColors colors,
  required String privateKeyHex,
  required String publicKeyHex,
  required InviteService inviteService,
}) {
  showDialog(
    context: context,
    builder: (ctx) => _InviteGenerateDialog(
      server: server,
      colors: colors,
      authPrivateKeyHex: privateKeyHex,
      authPublicKeyHex: publicKeyHex,
      inviteService: inviteService,
    ),
  );
}

class ChannelSidebar extends ConsumerStatefulWidget {
  final Server server;
  final String? activeChannelId;

  const ChannelSidebar({super.key, required this.server, this.activeChannelId});

  @override
  ConsumerState<ChannelSidebar> createState() => _ChannelSidebarState();
}

class _ChannelSidebarState extends ConsumerState<ChannelSidebar> {
  final Set<String> _collapsedCategories = {};
  bool _canManageChannels = false;

  @override
  void initState() {
    super.initState();
    _loadPermissions();
  }

  @override
  void didUpdateWidget(ChannelSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.server.id != widget.server.id) _loadPermissions();
  }

  Future<void> _loadPermissions() async {
    final auth = ref.read(authServiceProvider);
    if (auth.publicKeyHex == null) return;
    final permSvc = ref.read(permissionServiceProvider);
    final can = await permSvc.hasPermission(widget.server.id, auth.publicKeyHex!, Permission.manageChannels);
    if (mounted) setState(() => _canManageChannels = can);
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(databaseProvider);
    final auth = ref.watch(authServiceProvider);
    final c = ref.watch(infernoColorsProvider);

    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: c.gray800,
        border: Border(
          right: BorderSide(color: c.accent.withValues(alpha: 0.08), width: 1),
        ),
      ),
      child: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<Channel>>(
              stream: db.serversDao.watchServerChannels(widget.server.id),
              builder: (context, channelSnap) {
                return StreamBuilder<List<Category>>(
                  stream: db.serversDao.watchServerCategories(widget.server.id),
                  builder: (context, catSnap) {
                    final channels = channelSnap.data ?? [];
                    final categories = catSnap.data ?? [];
                    if (channels.isEmpty && categories.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('No channels', style: TextStyle(color: c.gray500, fontSize: 13)),
                      );
                    }
                    return ChannelReorderList(
                      server: widget.server,
                      activeChannelId: widget.activeChannelId,
                      channels: channels,
                      categories: categories,
                      colors: c,
                      collapsedCategories: _collapsedCategories,
                      onToggleCategory: (catId) {
                        setState(() {
                          if (_collapsedCategories.contains(catId)) {
                            _collapsedCategories.remove(catId);
                          } else {
                            _collapsedCategories.add(catId);
                          }
                        });
                      },
                      onEditChannel: _canManageChannels ? (ch) => _editChannelInline(context, ch) : null,
                      onDeleteChannel: _canManageChannels ? (ch) => _deleteChannelInline(context, ch) : null,
                      onEditCategory: _canManageChannels ? (cat) => _editCategoryInline(context, cat) : null,
                      onDeleteCategory: _canManageChannels ? (cat) => _deleteCategoryInline(context, cat) : null,
                      onCreateChannel: _canManageChannels ? (cat, {int? position}) => _createChannelInCategory(context, categoryId: cat?.id, position: position) : null,
                      onCreateCategory: _canManageChannels ? ({int? position}) => _createCategoryInline(context, position: position) : null,
                    );
                  },
                );
              },
            ),
          ),
          // Voice controls bar (shown when connected to voice)
          Consumer(builder: (context, ref, _) {
            final livekit = ref.watch(livekitServiceProvider);
            ref.watch(livekitConnectionProvider); // rebuild on connect/disconnect
            if (!livekit.isConnected) return const SizedBox.shrink();

            // Resolve voice channel from room name
            final roomName = livekit.room?.name ?? '';
            final db2 = ref.read(databaseProvider);
            // Extract channel publicId from room name (srv-{serverId}-{channelId})
            final parts = roomName.split('-');
            final channelPubId = parts.length >= 3 ? parts.sublist(2).join('-') : '';

            return FutureBuilder<Channel?>(
              future: channelPubId.isNotEmpty ? db2.serversDao.getChannelByPublicId(channelPubId) : Future.value(null),
              builder: (context, chSnap) {
            final voiceChannel = chSnap.data;
            final voiceChannelName = voiceChannel?.name ?? 'Voice';
            final isParent = voiceChannel != null && voiceChannel.parentChannelId == null;
            final isChild = voiceChannel != null && voiceChannel.parentChannelId != null;

            // Permission-gate voice controls
            final voicePermsAsync = voiceChannel != null
                ? ref.watch(_voicePermsProvider(voiceChannel.serverId)).valueOrNull ?? const _VoicePerms()
                : const _VoicePerms();

            return Column(mainAxisSize: MainAxisSize.min, children: [
              VoiceControlsBar(
                channelName: voiceChannelName,
                colors: c,
                isMuted: livekit.isMuted,
                isDeafened: livekit.isDeafened,
                onDisconnect: () => livekit.disconnect(),
                onToggleMute: voicePermsAsync.canSpeak ? () => livekit.toggleMicrophone() : null,
                onToggleDeafen: () => livekit.toggleDeafen(),
                onToggleCamera: voicePermsAsync.canVideo ? () => livekit.toggleCamera() : null,
                onToggleScreenShare: voicePermsAsync.canScreenShare ? () => livekit.toggleScreenShare() : null,
                hierarchyLabel: isParent ? '\u2193 Broadcast' : (isChild ? '\u2191 Ask to Speak' : null),
                onHierarchyAction: (isParent || isChild) ? () {} : null,
              ),
              Container(height: 1, color: c.gray700.withValues(alpha: 0.5)),
            ]);
          }); }),
          _UserPanel(auth: auth, colors: c),
        ],
      ),
    );
  }

  Future<void> _editChannelInline(BuildContext ctx, Channel ch) async {
    final c = ref.read(infernoColorsProvider);
    await showChannelDialog(ctx, ref, server: widget.server, colors: c, editing: ch);
  }

  Future<void> _deleteChannelInline(BuildContext ctx, Channel ch) async {
    final c = ref.read(infernoColorsProvider);
    await confirmDeleteChannel(ctx, ref, server: widget.server, colors: c, channel: ch);
  }

  Future<void> _editCategoryInline(BuildContext ctx, Category cat) async {
    final c = ref.read(infernoColorsProvider);
    final nameCtrl = TextEditingController(text: cat.name ?? '');
    final result = await showDialog<String>(
      context: ctx,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 400, padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.gray700.withValues(alpha: 0.5))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Edit Category', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            TextField(controller: nameCtrl, autofocus: true, style: TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(hintText: 'Category name', hintStyle: TextStyle(color: c.gray500),
                fillColor: c.gray900, filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent)))),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel', style: TextStyle(color: c.gray400))),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: () => Navigator.pop(context, nameCtrl.text.trim()), child: const Text('Save')),
            ]),
          ]),
        ),
      ),
    );
    nameCtrl.dispose();
    if (result == null || result.isEmpty) return;
    final db = ref.read(databaseProvider);
    await (db.update(db.categories)..where((c) => c.id.equals(cat.id)))
        .write(CategoriesCompanion(name: Value(result), updatedAt: Value(DateTime.now())));
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex != null) {
      final publishSvc = ref.read(serverPublishServiceProvider);
      await publishSvc.publishStructure(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: widget.server);
    }
  }

  Future<void> _deleteCategoryInline(BuildContext ctx, Category cat) async {
    final c = ref.read(infernoColorsProvider);
    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 400, padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: c.gray800, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.gray700.withValues(alpha: 0.5))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Delete "${cat.name}"?', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text('Channels in this category will be moved to uncategorized.', style: TextStyle(color: c.gray400, fontSize: 14)),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel', style: TextStyle(color: c.gray400))),
              const SizedBox(width: 8),
              ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true), child: const Text('Delete', style: TextStyle(color: Colors.white))),
            ]),
          ]),
        ),
      ),
    );
    if (confirmed != true) return;
    final db = ref.read(databaseProvider);
    await (db.update(db.channels)..where((ch) => ch.categoryId.equals(cat.id)))
        .write(ChannelsCompanion(categoryId: const Value(null), updatedAt: Value(DateTime.now())));
    await (db.delete(db.categories)..where((c) => c.id.equals(cat.id))).go();
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex != null) {
      final publishSvc = ref.read(serverPublishServiceProvider);
      await publishSvc.publishStructure(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: widget.server);
    }
  }

  Future<void> _createCategoryInline(BuildContext ctx, {int? position}) async {
    final c = ref.read(infernoColorsProvider);
    final nameCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: ctx,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 400, padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.gray700.withValues(alpha: 0.5))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Create Category', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            TextField(controller: nameCtrl, autofocus: true, style: TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(hintText: 'Category name', hintStyle: TextStyle(color: c.gray500),
                fillColor: c.gray900, filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent)))),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel', style: TextStyle(color: c.gray400))),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: () => Navigator.pop(context, nameCtrl.text.trim()), child: const Text('Create')),
            ]),
          ]),
        ),
      ),
    );
    nameCtrl.dispose();
    if (result == null || result.isEmpty) return;
    final db = ref.read(databaseProvider);
    final now = DateTime.now();
    final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
    final categories = await (db.select(db.categories)..where((c) => c.serverId.equals(widget.server.id))).get();
    final maxPos = categories.fold<int>(0, (max, cat) => (cat.position ?? 0) > max ? (cat.position ?? 0) : max);
    final insertPosition = position ?? (maxPos + 1);
    // If inserting at a specific position, shift existing categories down
    if (position != null) {
      final toShift = categories.where((cat) => (cat.position ?? 0) >= position).toList();
      for (final cat in toShift) {
        await (db.update(db.categories)..where((c) => c.id.equals(cat.id)))
            .write(CategoriesCompanion(position: Value((cat.position ?? 0) + 1)));
      }
    }
    await db.into(db.categories).insert(CategoriesCompanion.insert(
      publicId: publicId, serverId: widget.server.id,
      name: Value(result), position: Value(insertPosition),
      createdAt: now, updatedAt: now,
    ));
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex != null) {
      final publishSvc = ref.read(serverPublishServiceProvider);
      await publishSvc.publishStructure(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: widget.server);
    }
  }

  Future<void> _createChannelInCategory(BuildContext ctx, {int? categoryId, int? position}) async {
    final c = ref.read(infernoColorsProvider);
    final nameCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: ctx,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 400, padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.gray700.withValues(alpha: 0.5))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Create Channel', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            TextField(controller: nameCtrl, autofocus: true, style: TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(hintText: 'channel-name', hintStyle: TextStyle(color: c.gray500),
                fillColor: c.gray900, filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent)))),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel', style: TextStyle(color: c.gray400))),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: () => Navigator.pop(context, nameCtrl.text.trim()), child: const Text('Create')),
            ]),
          ]),
        ),
      ),
    );
    nameCtrl.dispose();
    if (result == null || result.isEmpty) return;
    final db = ref.read(databaseProvider);
    final now = DateTime.now();
    final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
    final nostrGroupId = widget.server.nostrGroupId != null ? '${widget.server.nostrGroupId}-$publicId' : null;
    final channels = await (db.select(db.channels)..where((ch) => ch.serverId.equals(widget.server.id))).get();
    final maxPos = channels.fold<int>(0, (max, ch) => (ch.position ?? 0) > max ? (ch.position ?? 0) : max);
    final insertPosition = position ?? (maxPos + 1);
    // If inserting at a specific position, shift existing channels down
    if (position != null) {
      final toShift = channels.where((ch) =>
          ch.categoryId == categoryId && (ch.position ?? 0) >= position).toList();
      for (final ch in toShift) {
        await (db.update(db.channels)..where((c) => c.id.equals(ch.id)))
            .write(ChannelsCompanion(position: Value((ch.position ?? 0) + 1)));
      }
    }
    final chRowId = await db.into(db.channels).insert(ChannelsCompanion.insert(
      publicId: publicId, serverId: widget.server.id,
      name: result.toLowerCase().replaceAll(' ', '-'), channelType: 0,
      position: Value(insertPosition), categoryId: Value(categoryId),
      nostrGroupId: Value(nostrGroupId), createdAt: now, updatedAt: now,
    ));
    // Seed channel_reads so new channel doesn't appear as unread
    await db.into(db.channelReads).insert(ChannelReadsCompanion.insert(
      channelId: chRowId, userId: 0,
      lastReadAt: now, createdAt: now, updatedAt: now,
    ), onConflict: DoNothing());
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex != null) {
      final publishSvc = ref.read(serverPublishServiceProvider);
      await publishSvc.publishStructure(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: widget.server);
    }
  }
}

/// Voice controls bar — shown in sidebar when connected to a voice channel.
/// Matches Rails: green "Voice Connected" header + channel name + mute/deafen/camera/screenshare + disconnect
class VoiceControlsBar extends StatelessWidget {
  final String channelName;
  final InfernoColors colors;
  final VoidCallback? onDisconnect;
  final VoidCallback? onToggleMute;
  final VoidCallback? onToggleDeafen;
  final VoidCallback? onToggleCamera;
  final VoidCallback? onToggleScreenShare;
  final bool isMuted;
  final bool isDeafened;
  final String? hierarchyLabel; // "↓ Broadcast" or "↑ Ask to Speak"
  final VoidCallback? onHierarchyAction;

  const VoiceControlsBar({
    super.key,
    required this.channelName,
    required this.colors,
    this.onDisconnect,
    this.onToggleMute,
    this.onToggleDeafen,
    this.onToggleCamera,
    this.onToggleScreenShare,
    this.isMuted = false,
    this.isDeafened = false,
    this.hierarchyLabel,
    this.onHierarchyAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: colors.gray900,
        border: Border(top: BorderSide(color: colors.accent.withValues(alpha: 0.12))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header: "Voice Connected" + disconnect button
          Row(
            children: [
              Icon(Icons.volume_up, size: 16, color: colors.online),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Voice Connected', style: TextStyle(color: colors.online, fontSize: 13, fontWeight: FontWeight.w600)),
                    Text(channelName, style: TextStyle(color: colors.gray400, fontSize: 11), overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              // Disconnect button
              GestureDetector(
                onTap: onDisconnect,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: colors.accent.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(Icons.call_end, size: 16, color: colors.accent),
                ),
              ),
            ],
          ),
          // Hierarchy button (Broadcast / Ask to Speak)
          if (hierarchyLabel != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onHierarchyAction,
                  child: Text(hierarchyLabel!, style: TextStyle(color: colors.gray400, fontSize: 12)),
                ),
              ),
            ),
          const SizedBox(height: 2),
          // Controls: mute, deafen, camera, screen share
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _VoiceButton(
                icon: isMuted ? Icons.mic_off : Icons.mic,
                isActive: isMuted,
                colors: colors,
                onTap: onToggleMute,
                tooltip: isMuted ? 'Unmute' : 'Mute',
              ),
              const SizedBox(width: 8),
              _VoiceButton(
                icon: isDeafened ? Icons.headset_off : Icons.headset,
                isActive: isDeafened,
                colors: colors,
                onTap: onToggleDeafen,
                tooltip: isDeafened ? 'Undeafen' : 'Deafen',
              ),
              const SizedBox(width: 8),
              _VoiceButton(
                icon: Icons.videocam,
                isActive: false,
                colors: colors,
                onTap: onToggleCamera,
                tooltip: 'Camera',
              ),
              const SizedBox(width: 8),
              _VoiceButton(
                icon: Icons.screen_share,
                isActive: false,
                colors: colors,
                onTap: onToggleScreenShare,
                tooltip: 'Screen Share',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _VoiceButton extends StatefulWidget {
  final IconData icon;
  final bool isActive;
  final InfernoColors colors;
  final VoidCallback? onTap;
  final String tooltip;
  const _VoiceButton({required this.icon, required this.isActive, required this.colors, this.onTap, required this.tooltip});

  @override
  State<_VoiceButton> createState() => _VoiceButtonState();
}

class _VoiceButtonState extends State<_VoiceButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: widget.isActive ? widget.colors.gray700 : (_hovering ? widget.colors.gray600 : Colors.transparent),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              widget.icon,
              size: 20,
              color: widget.isActive ? Colors.white : widget.colors.gray400,
            ),
          ),
        ),
      ),
    );
  }
}

class _ServerHeader extends ConsumerStatefulWidget {
  final Server server;
  final InfernoColors colors;
  const _ServerHeader({required this.server, required this.colors});

  @override
  ConsumerState<_ServerHeader> createState() => _ServerHeaderState();
}

class _ServerHeaderState extends ConsumerState<_ServerHeader> {
  bool _hovering = false;
  bool _dropdownOpen = false;
  bool _canManageServer = false;
  bool _canManageChannels = false;
  bool _canInvite = false;

  @override
  void initState() {
    super.initState();
    _loadPerms();
  }

  @override
  void didUpdateWidget(covariant _ServerHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.server.id != widget.server.id) _loadPerms();
  }

  Future<void> _loadPerms() async {
    final auth = ref.read(authServiceProvider);
    if (auth.publicKeyHex == null) return;
    final permSvc = ref.read(permissionServiceProvider);
    final manage = await permSvc.hasPermission(widget.server.id, auth.publicKeyHex!, Permission.manageServer);
    final channels = await permSvc.hasPermission(widget.server.id, auth.publicKeyHex!, Permission.manageChannels);
    final invite = await permSvc.hasPermission(widget.server.id, auth.publicKeyHex!, Permission.createInvite);
    if (mounted) {
      setState(() {
        _canManageServer = manage;
        _canManageChannels = channels;
        _canInvite = invite;
      });
    }
  }

  void _toggleDropdown() async {
    if (_dropdownOpen) return;
    setState(() => _dropdownOpen = true);

    final renderBox = context.findRenderObject() as RenderBox;
    final offset = renderBox.localToGlobal(Offset.zero);
    final c = widget.colors;
    final menuTop = offset.dy + renderBox.size.height + 4;
    final menuLeft = offset.dx + 8;
    final menuWidth = renderBox.size.width - 16;

    final action = await showDialog<String>(
      context: context,
      barrierColor: Colors.transparent,
      barrierDismissible: true,
      builder: (ctx) => Stack(
        children: [
          Positioned(
            left: menuLeft,
            top: menuTop,
            width: menuWidth,
            child: Material(
              color: Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  color: c.gray900,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: c.gray700),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 12, offset: const Offset(0, 4))],
                ),
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_canInvite)
                      _DropdownItem(icon: Icons.link, label: 'Invite People', colors: c,
                        onTap: () => Navigator.pop(ctx, 'invite')),
                    if (_canManageServer)
                      _DropdownItem(icon: Icons.settings, label: 'Server Settings', colors: c,
                        onTap: () => Navigator.pop(ctx, 'settings')),
                    if (_canManageChannels)
                      _DropdownItem(icon: Icons.add, label: 'Create Channel', colors: c,
                        onTap: () => Navigator.pop(ctx, 'createChannel')),
                    if (_canManageChannels)
                      _DropdownItem(icon: Icons.create_new_folder_outlined, label: 'Create Category', colors: c,
                        onTap: () => Navigator.pop(ctx, 'createCategory')),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Container(height: 1, color: c.gray700),
                    ),
                    _DropdownItem(icon: null, label: 'Leave Server', colors: c, danger: true,
                      onTap: () => Navigator.pop(ctx, 'leave')),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );

    if (mounted) setState(() => _dropdownOpen = false);

    if (action == null) return;
    switch (action) {
      case 'invite': _showInviteDialog(); break;
      case 'settings': _showServerSettings(context); break;
      case 'createChannel': _showCreateChannel(context); break;
      case 'createCategory': _showCreateCategory(context); break;
      case 'leave': _leaveServer(context); break;
    }
  }

  void _showInviteDialog() {
    final auth = ref.read(authServiceProvider);
    final inviteService = ref.read(inviteServiceProvider);
    if (auth.privateKeyHex == null) return;
    showDialog(
      context: context,
      builder: (ctx) => _InviteGenerateDialog(
        server: widget.server,
        colors: widget.colors,
        authPrivateKeyHex: auth.privateKeyHex!,
        authPublicKeyHex: auth.publicKeyHex!,
        inviteService: inviteService,
      ),
    );
  }

  void _showServerSettings(BuildContext ctx) {
    showServerSettingsOverlay(ctx, widget.server);
  }

  Future<void> _showCreateChannel(BuildContext ctx, {int? categoryId}) async {
    final c = widget.colors;
    final nameController = TextEditingController();
    final result = await showDialog<String>(
      context: ctx,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: c.gray900,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Create Channel', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                autofocus: true,
                style: TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'channel-name',
                  hintStyle: TextStyle(color: c.gray500),
                  fillColor: c.gray900,
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent)),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Cancel', style: TextStyle(color: c.gray400)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, nameController.text.trim()),
                    child: const Text('Create'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (result != null && result.isNotEmpty) {
      final db = ref.read(databaseProvider);
      final now = DateTime.now();
      final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
      final nostrGroupId = widget.server.nostrGroupId != null ? '${widget.server.nostrGroupId}-$publicId' : null;

      final channels = await (db.select(db.channels)..where((ch) => ch.serverId.equals(widget.server.id))).get();
      final maxPos = channels.fold<int>(0, (max, ch) => (ch.position ?? 0) > max ? (ch.position ?? 0) : max);

      final chRowId2 = await db.into(db.channels).insert(ChannelsCompanion.insert(
        publicId: publicId,
        serverId: widget.server.id,
        name: result.toLowerCase().replaceAll(' ', '-'),
        channelType: 0,
        position: Value(maxPos + 1),
        categoryId: Value(categoryId),
        nostrGroupId: Value(nostrGroupId),
        createdAt: now,
        updatedAt: now,
      ));
      // Seed channel_reads so new channel doesn't appear as unread
      await db.into(db.channelReads).insert(ChannelReadsCompanion.insert(
        channelId: chRowId2, userId: 0,
        lastReadAt: now, createdAt: now, updatedAt: now,
      ), onConflict: DoNothing());

      final auth = ref.read(authServiceProvider);
      final serverPublish = ref.read(serverPublishServiceProvider);
      if (auth.privateKeyHex != null) {
        await serverPublish.publishStructure(
          privateKeyHex: auth.privateKeyHex!,
          publicKeyHex: auth.publicKeyHex!,
          server: widget.server,
        );
      }
    }
    nameController.dispose();
  }

  Future<void> _showCreateCategory(BuildContext ctx) async {
    final c = widget.colors;
    final nameController = TextEditingController();
    final result = await showDialog<String>(
      context: ctx,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: c.gray900,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Create Category', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                autofocus: true,
                style: TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Category name',
                  hintStyle: TextStyle(color: c.gray500),
                  fillColor: c.gray900,
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent)),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Cancel', style: TextStyle(color: c.gray400)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, nameController.text.trim()),
                    child: const Text('Create'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (result != null && result.isNotEmpty) {
      final db = ref.read(databaseProvider);
      final now = DateTime.now();
      final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);

      final cats = await (db.select(db.categories)..where((cat) => cat.serverId.equals(widget.server.id))).get();
      final maxPos = cats.fold<int>(0, (max, cat) => (cat.position ?? 0) > max ? (cat.position ?? 0) : max);

      await db.into(db.categories).insert(CategoriesCompanion.insert(
        publicId: publicId,
        serverId: widget.server.id,
        name: Value(result),
        position: Value(maxPos + 1),
        createdAt: now,
        updatedAt: now,
      ));
    }
    nameController.dispose();
  }

  Future<void> _leaveServer(BuildContext ctx) async {
    final c = widget.colors;
    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: c.gray900,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Leave Server', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text('Are you sure you want to leave "${widget.server.name}"? You won\'t be able to rejoin unless you are re-invited.',
                style: TextStyle(color: c.gray400, fontSize: 14)),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text('Cancel', style: TextStyle(color: c.gray400)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Leave Server', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true) {
      final db = ref.read(databaseProvider);
      final serverId = widget.server.id;

      await (db.delete(db.serverMemberships)..where((m) => m.serverId.equals(serverId))).go();

      final auth = ref.read(authServiceProvider);
      if (auth.privateKeyHex != null && widget.server.nostrGroupId != null) {
        final serverPublish = ref.read(serverPublishServiceProvider);
        await serverPublish.publishMemberRemoval(
          privateKeyHex: auth.privateKeyHex!,
          publicKeyHex: auth.publicKeyHex!,
          server: widget.server,
          targetPubkey: auth.publicKeyHex!,
        );
      }

      final channels = await (db.select(db.channels)..where((ch) => ch.serverId.equals(serverId))).get();
      for (final ch in channels) {
        await (db.delete(db.messages)..where((m) => m.channelId.equals(ch.id))).go();
      }
      await (db.delete(db.channels)..where((ch) => ch.serverId.equals(serverId))).go();
      await (db.delete(db.categories)..where((cat) => cat.serverId.equals(serverId))).go();
      await (db.delete(db.remoteMembers)..where((m) => m.serverId.equals(serverId))).go();
      await (db.delete(db.servers)..where((s) => s.id.equals(serverId))).go();

      GoRouter.of(context).go('/conversations');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: _toggleDropdown,
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: c.gray900,
            gradient: (_hovering || _dropdownOpen) ? LinearGradient(colors: [c.accent.withValues(alpha: 0.08), Colors.transparent]) : null,
            border: Border(bottom: BorderSide(color: c.gray700.withValues(alpha: 0.3))),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 4, offset: const Offset(0, 2))],
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.server.name,
                  style: TextStyle(color: c.gray50, fontWeight: FontWeight.w600, fontSize: 15),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.keyboard_arrow_down, color: c.gray400, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}


class _DropdownItem extends StatefulWidget {
  final IconData? icon;
  final String label;
  final InfernoColors colors;
  final bool danger;
  final VoidCallback onTap;

  const _DropdownItem({
    this.icon,
    required this.label,
    required this.colors,
    this.danger = false,
    required this.onTap,
  });

  @override
  State<_DropdownItem> createState() => _DropdownItemState();
}

class _DropdownItemState extends State<_DropdownItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final textColor = widget.danger
        ? c.accent
        : (_hovering ? Colors.white : c.gray400);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            gradient: _hovering ? LinearGradient(colors: [c.accent.withValues(alpha: 0.08), Colors.transparent]) : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 18, color: textColor),
                const SizedBox(width: 10),
              ],
              Text(
                widget.label,
                style: TextStyle(color: textColor, fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UserPanel extends ConsumerWidget {
  final AuthService auth;
  final InfernoColors colors;
  const _UserPanel({required this.auth, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pubkey = auth.publicKeyHex;
    final db = ref.watch(databaseProvider);
    final presenceSvc = ref.watch(presenceServiceProvider);
    final currentState = presenceSvc.currentState;
    final statusColor = _presenceColor(currentState, colors);
    final statusText = currentState.value[0].toUpperCase() + currentState.value.substring(1);

    return StreamBuilder<List<Contact>>(
      stream: pubkey != null
          ? (db.select(db.contacts)..where((c) => c.pubkey.equals(pubkey))).watch()
          : const Stream.empty(),
      builder: (context, snap) {
        final contact = snap.data?.firstOrNull;
        final displayName = contact?.displayName ?? contact?.username ?? (pubkey != null ? '${pubkey.substring(0, 8)}...' : 'User');
        final avatarUrl = contact?.avatarUrl;

    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: colors.gray950,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          children: [
            Stack(
              children: [
                Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: avatarUrl != null && avatarUrl.startsWith('http') ? Colors.transparent : colors.gray700,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: avatarUrl != null && avatarUrl.startsWith('http')
                      ? Image.network(avatarUrl, fit: BoxFit.cover, width: 32, height: 32)
                      : Center(child: Text(displayName[0].toUpperCase(), style: TextStyle(color: colors.gray200, fontSize: 14, fontWeight: FontWeight.w600))),
                ),
                Positioned(
                  right: 0, bottom: 0,
                  child: Container(
                    width: 12, height: 12,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.gray600, width: 2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(displayName,
                    style: TextStyle(color: colors.gray200, fontSize: 13, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis),
                  Text(statusText,
                    style: TextStyle(color: colors.gray500, fontSize: 11)),
                ],
              ),
            ),
            ref.watch(appVersionProvider).when(
              data: (v) => Text('v$v', style: TextStyle(color: colors.gray500, fontSize: 10)),
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
            const SizedBox(width: 6),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => showSettingsOverlay(context),
                child: Icon(Icons.settings, color: colors.gray400, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
      },
    );
  }

  static Color _presenceColor(OnlineState state, InfernoColors c) {
    switch (state) {
      case OnlineState.online: return c.online;
      case OnlineState.idle: return c.idle;
      case OnlineState.dnd: return c.dnd;
      default: return c.offline;
    }
  }
}

/// Discord-style invite dialog with member list and auto-generated link.
class _InviteGenerateDialog extends StatefulWidget {
  final Server server;
  final InfernoColors colors;
  final String authPrivateKeyHex;
  final String authPublicKeyHex;
  final InviteService inviteService;

  const _InviteGenerateDialog({
    required this.server,
    required this.colors,
    required this.authPrivateKeyHex,
    required this.authPublicKeyHex,
    required this.inviteService,
  });

  @override
  State<_InviteGenerateDialog> createState() => _InviteGenerateDialogState();
}

class _InviteGenerateDialogState extends State<_InviteGenerateDialog> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  String? _inviteLink;
  bool _generating = false;
  bool _editingLink = false;
  String _expiry = '7d';
  String _maxUses = 'unlimited';
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _generateDefaultLink();
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text.toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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

  String _expiryLabel(String value) {
    switch (value) {
      case '30m': return '30 minutes';
      case '1h': return '1 hour';
      case '6h': return '6 hours';
      case '12h': return '12 hours';
      case '1d': return '1 day';
      case '7d': return '7 days';
      case 'never': return 'never';
      default: return value;
    }
  }

  Future<void> _generateDefaultLink() async {
    setState(() => _generating = true);
    try {
      final invite = await widget.inviteService.createInvite(
        privateKeyHex: widget.authPrivateKeyHex,
        publicKeyHex: widget.authPublicKeyHex,
        server: widget.server,
        creatorId: 1,
        maxUses: _parseMaxUses(_maxUses),
        expiresAt: _parseExpiry(_expiry),
      );
      final link = widget.inviteService.generateInviteLink(
        invite: invite,
        server: widget.server,
        creatorPubkey: widget.authPublicKeyHex,
      );
      if (mounted) setState(() { _inviteLink = link; _generating = false; });
    } catch (e) {
      if (mounted) setState(() { _generating = false; });
    }
  }

  Future<void> _regenerateLink() async {
    setState(() { _editingLink = false; _generating = true; _inviteLink = null; _copied = false; });
    await _generateDefaultLink();
  }

  void _copyLink() {
    if (_inviteLink == null) return;
    Clipboard.setData(ClipboardData(text: _inviteLink!));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 440,
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
        decoration: BoxDecoration(
          color: c.gray800,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Invite friends to ${widget.server.name}',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                ])),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      width: 28, height: 28,
                      decoration: BoxDecoration(color: c.gray700, shape: BoxShape.circle),
                      child: Icon(Icons.close, size: 14, color: c.gray400),
                    ),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 16),

            // Search bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _searchController,
                style: TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search for friends',
                  hintStyle: TextStyle(color: c.gray500, fontSize: 14),
                  prefixIcon: Icon(Icons.search, size: 18, color: c.gray500),
                  filled: true, fillColor: c.gray900,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Member list header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text('Server Members', style: TextStyle(color: c.gray500, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 8),

            // Member list
            Flexible(
              child: _MemberInviteList(
                serverId: widget.server.id,
                colors: c,
                searchQuery: _searchQuery,
              ),
            ),

            // Bottom: invite link section
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.gray700.withValues(alpha: 0.5))),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Or, send a server invite link to a friend',
                      style: TextStyle(color: c.gray400, fontSize: 13)),
                  const SizedBox(height: 10),
                  // Link row
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: c.gray900,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(children: [
                      Expanded(
                        child: _generating
                            ? Text('Generating...', style: TextStyle(color: c.gray500, fontSize: 13))
                            : Text(
                                _inviteLink ?? '',
                                style: TextStyle(color: c.gray200, fontSize: 13),
                                overflow: TextOverflow.ellipsis,
                              ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 36,
                        child: ElevatedButton(
                          onPressed: _inviteLink != null ? _copyLink : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: c.accent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          ),
                          child: Text(_copied ? 'Copied!' : 'Copy', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 8),
                  // Expiry info + edit link
                  if (!_editingLink)
                    Row(children: [
                      Text(
                        _expiry == 'never'
                            ? 'Your invite link never expires.'
                            : 'Your invite link expires in ${_expiryLabel(_expiry)}.',
                        style: TextStyle(color: c.gray500, fontSize: 12),
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () => setState(() => _editingLink = true),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Text('Edit invite link.', style: TextStyle(color: c.accent, fontSize: 12)),
                        ),
                      ),
                    ])
                  else ...[
                    const SizedBox(height: 4),
                    Row(children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('EXPIRE AFTER', style: TextStyle(color: c.gray500, fontSize: 10, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        DropdownButtonFormField<String>(
                          initialValue: _expiry, dropdownColor: c.gray900,
                          style: TextStyle(color: c.gray200, fontSize: 13),
                          decoration: InputDecoration(
                            isDense: true, filled: true, fillColor: c.gray900,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
                          ),
                          items: const [
                            DropdownMenuItem(value: '30m', child: Text('30 minutes')),
                            DropdownMenuItem(value: '1h', child: Text('1 hour')),
                            DropdownMenuItem(value: '6h', child: Text('6 hours')),
                            DropdownMenuItem(value: '12h', child: Text('12 hours')),
                            DropdownMenuItem(value: '1d', child: Text('1 day')),
                            DropdownMenuItem(value: '7d', child: Text('7 days')),
                            DropdownMenuItem(value: 'never', child: Text('Never')),
                          ],
                          onChanged: (v) => setState(() => _expiry = v!),
                        ),
                      ])),
                      const SizedBox(width: 8),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('MAX USES', style: TextStyle(color: c.gray500, fontSize: 10, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        DropdownButtonFormField<String>(
                          initialValue: _maxUses, dropdownColor: c.gray900,
                          style: TextStyle(color: c.gray200, fontSize: 13),
                          decoration: InputDecoration(
                            isDense: true, filled: true, fillColor: c.gray900,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
                          ),
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
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: SizedBox(
                          height: 36,
                          child: ElevatedButton(
                            onPressed: _generating ? null : _regenerateLink,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: c.accent,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                            ),
                            child: const Text('Generate', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Scrollable member list inside the invite dialog.
class _MemberInviteList extends ConsumerWidget {
  final int serverId;
  final InfernoColors colors;
  final String searchQuery;
  const _MemberInviteList({required this.serverId, required this.colors, required this.searchQuery});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    return StreamBuilder<List<RemoteMember>>(
      stream: (db.select(db.remoteMembers)..where((m) => m.serverId.equals(serverId))).watch(),
      builder: (context, snapshot) {
        final members = snapshot.data ?? [];
        final filtered = searchQuery.isEmpty
            ? members
            : members.where((m) {
                final name = (m.displayName ?? m.username ?? m.pubkey).toLowerCase();
                return name.contains(searchQuery);
              }).toList();

        if (filtered.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Text(
              searchQuery.isEmpty ? 'No members found' : 'No matches for "$searchQuery"',
              style: TextStyle(color: colors.gray500, fontSize: 13),
            )),
          );
        }

        return ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: filtered.length,
          itemBuilder: (context, index) => _MemberInviteRow(member: filtered[index], colors: colors),
        );
      },
    );
  }
}

class _MemberInviteRow extends StatefulWidget {
  final RemoteMember member;
  final InfernoColors colors;
  const _MemberInviteRow({required this.member, required this.colors});
  @override
  State<_MemberInviteRow> createState() => _MemberInviteRowState();
}

class _MemberInviteRowState extends State<_MemberInviteRow> {
  bool _hovering = false;
  bool _invited = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final m = widget.member;
    final displayName = m.displayName ?? m.username ?? m.pubkey.substring(0, 12);
    final subtitle = m.status ?? m.username ?? m.pubkey.substring(0, 16);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: _hovering ? c.gray700.withValues(alpha: 0.3) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          // Avatar
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.gray600,
              image: m.avatarUrl != null
                  ? DecorationImage(image: NetworkImage(m.avatarUrl!), fit: BoxFit.cover)
                  : null,
            ),
            child: m.avatarUrl == null
                ? Center(child: Text(displayName[0].toUpperCase(), style: TextStyle(color: c.gray200, fontWeight: FontWeight.bold, fontSize: 14)))
                : null,
          ),
          const SizedBox(width: 10),
          // Name + status
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(displayName, style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
            if (subtitle != displayName)
              Text(subtitle, style: TextStyle(color: c.gray500, fontSize: 12), overflow: TextOverflow.ellipsis),
          ])),
          // Invite button
          SizedBox(
            height: 32,
            child: ElevatedButton(
              onPressed: _invited ? null : () {
                // For now, mark as invited (visual feedback). DM invite sending can be added later.
                setState(() => _invited = true);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _invited ? c.gray700 : c.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                elevation: 0,
              ),
              child: Text(_invited ? 'Sent' : 'Invite', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
    );
  }
}
