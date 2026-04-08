import 'dart:convert';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart';
import '../../database/database.dart';
import '../../providers/database_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/realtime_provider.dart';
import '../../services/voice_token_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../providers/conversations_provider.dart';
import '../../crypto/nostr_event.dart' as nostr;
import '../../crypto/nostr_signer.dart';
import '../../widgets/participant_tile.dart';
import '../../models/permission.dart';
import '../../providers/server_settings_provider.dart';
import '../../theme/all_themes.dart';
import '../../theme/theme_provider.dart';

class VoiceChannelScreen extends ConsumerStatefulWidget {
  final String channelPublicId;
  final String serverPublicId;

  const VoiceChannelScreen({
    super.key,
    required this.channelPublicId,
    required this.serverPublicId,
  });

  @override
  ConsumerState<VoiceChannelScreen> createState() => _VoiceChannelScreenState();
}

class _VoiceChannelScreenState extends ConsumerState<VoiceChannelScreen> {
  Channel? _channel;
  bool _connecting = false;
  bool _muted = false;
  bool _deafened = false;
  String? _error;

  // Permission cache
  bool _canConnect = true;
  bool _canSpeak = true;
  bool _canVideo = true;
  bool _canScreenShare = true;
  bool _canMuteMembers = false;
  bool _canDeafenMembers = false;
  bool _canMoveMembers = false;

  @override
  void initState() {
    super.initState();
    _loadChannel();
    _loadPermissions();
  }

  @override
  void didUpdateWidget(VoiceChannelScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelPublicId != widget.channelPublicId) {
      _loadChannel();
    }
  }

  Future<void> _loadChannel() async {
    final db = ref.read(databaseProvider);
    final ch = await db.serversDao.getChannelByPublicId(widget.channelPublicId);
    if (mounted) setState(() => _channel = ch);
    if (ch != null) _loadPermissions(ch.serverId);
  }

  Future<void> _loadPermissions([int? serverId]) async {
    final sid = serverId ?? _channel?.serverId;
    if (sid == null) return;
    final auth = ref.read(authServiceProvider);
    if (auth.publicKeyHex == null) return;
    final permSvc = ref.read(permissionServiceProvider);
    final pk = auth.publicKeyHex!;
    final results = await Future.wait([
      permSvc.hasPermission(sid, pk, Permission.connectVoice),
      permSvc.hasPermission(sid, pk, Permission.speak),
      permSvc.hasPermission(sid, pk, Permission.video),
      permSvc.hasPermission(sid, pk, Permission.screenShare),
      permSvc.hasPermission(sid, pk, Permission.muteMembers),
      permSvc.hasPermission(sid, pk, Permission.deafenMembers),
      permSvc.hasPermission(sid, pk, Permission.moveMembers),
    ]);
    if (mounted) {
      setState(() {
        _canConnect = results[0];
        _canSpeak = results[1];
        _canVideo = results[2];
        _canScreenShare = results[3];
        _canMuteMembers = results[4];
        _canDeafenMembers = results[5];
        _canMoveMembers = results[6];
      });
    }
  }

  Future<void> _joinVoice() async {
    setState(() { _connecting = true; _error = null; });
    try {
      final auth = ref.read(authServiceProvider);
      final livekit = ref.read(livekitServiceProvider);
      final db = ref.read(databaseProvider);
      final dmService = ref.read(dmServiceProvider);

      if (auth.privateKeyHex == null || _channel == null) return;

      // Find a voice provider for this server
      final providers = await (db.select(db.serverVoiceProviders)
            ..where((p) => p.serverId.equals(_channel!.serverId) & p.active.equals(true))
            ..limit(1))
          .get();

      if (providers.isEmpty) {
        setState(() { _error = 'No voice provider configured for this server.'; _connecting = false; });
        return;
      }

      final provider = providers.first;
      if (provider.providerPubkey == null) {
        setState(() { _error = 'Voice provider has no pubkey.'; _connecting = false; });
        return;
      }

      // Send token request via encrypted DM to the provider
      final pool = ref.read(relayPoolProvider);
      final requestId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final server = await (db.select(db.servers)..where((s) => s.id.equals(_channel!.serverId))).getSingle();

      if (mounted) setState(() => _error = 'Requesting voice token...');

      // Resolve our display name for the token
      final contact = await (db.select(db.contacts)..where((c) => c.pubkey.equals(auth.publicKeyHex!))..limit(1)).getSingleOrNull();
      final displayName = contact?.displayName ?? contact?.username ?? auth.publicKeyHex!.substring(0, 8);

      await VoiceTokenService.requestToken(
        relayPool: pool,
        privateKeyHex: auth.privateKeyHex!,
        publicKeyHex: auth.publicKeyHex!,
        providerPubkey: provider.providerPubkey!,
        serverGroupId: server.nostrGroupId ?? '',
        channelPublicId: widget.channelPublicId,
        requestId: requestId,
        userDisplayName: displayName,
      );

      // Wait for the provider to respond with a token (up to 15 seconds)
      if (mounted) setState(() => _error = 'Waiting for provider response...');

      final response = await dmService.waitForVoiceToken(requestId);
      if (response == null) {
        if (mounted) setState(() { _error = 'Voice provider did not respond. Try again.'; _connecting = false; });
        return;
      }

      final token = response['token'] as String?;
      final livekitUrl = response['livekit_url'] as String?;
      if (token == null || livekitUrl == null) {
        if (mounted) setState(() { _error = 'Invalid token response.'; _connecting = false; });
        return;
      }

      // Load audio processing settings
      const storage = FlutterSecureStorage();
      // Default to true if not set (matching Rails defaults)
      final noiseSuppression = (await storage.read(key: 'voice_noise_suppression')) != 'false';
      final echoCancellation = (await storage.read(key: 'voice_echo_cancellation')) != 'false';
      final autoGainControl = (await storage.read(key: 'voice_auto_gain_control')) != 'false';
      final suppressionLevel = (await storage.read(key: 'voice_suppression_level')) ?? 'moderate';

      // Connect to LiveKit with audio processing options
      if (mounted) setState(() => _error = 'Connecting...');
      await livekit.connect(
        url: livekitUrl, token: token,
        noiseSuppression: noiseSuppression,
        echoCancellation: echoCancellation,
        autoGainControl: autoGainControl,
        suppressionLevel: suppressionLevel,
      );
      await livekit.setMicrophoneEnabled(_canSpeak);

      // Set leave callback so sidebar disconnect also publishes leave state
      livekit.onLeaveCallback = () => _publishVoiceState('leave');

      // Set token refresh callback — requests a new token from the provider
      // before the current one expires (fires 30 min before expiry)
      livekit.onTokenRefreshNeeded = () async {
        final newRequestId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
        await VoiceTokenService.requestToken(
          relayPool: pool,
          privateKeyHex: auth.privateKeyHex!,
          publicKeyHex: auth.publicKeyHex!,
          providerPubkey: provider.providerPubkey!,
          serverGroupId: server.nostrGroupId ?? '',
          channelPublicId: widget.channelPublicId,
          requestId: newRequestId,
          userDisplayName: displayName,
        );
        final resp = await dmService.waitForVoiceToken(newRequestId);
        return resp?['token'] as String?;
      };

      // Publish voice state join to remote instances
      await _publishVoiceState('join');

      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _leaveVoice() async {
    final livekit = ref.read(livekitServiceProvider);
    await livekit.disconnect(); // this calls onLeaveCallback which publishes leave state
    if (mounted) setState(() {});
  }

  Future<void> _publishVoiceState(String action) async {
    if (_channel == null) return;
    final auth = ref.read(authServiceProvider);
    final db = ref.read(databaseProvider);
    final relayPool = ref.read(relayPoolProvider);
    final livekit = ref.read(livekitServiceProvider);
    if (auth.privateKeyHex == null) return;

    final server = await (db.select(db.servers)..where((s) => s.id.equals(_channel!.serverId))).getSingleOrNull();
    if (server == null || server.nostrGroupId == null) return;

    final contact = await (db.select(db.contacts)..where((c) => c.pubkey.equals(auth.publicKeyHex!))..limit(1)).getSingleOrNull();
    final displayName = contact?.displayName ?? contact?.username ?? auth.publicKeyHex!.substring(0, 8);

    // Publish as a public event with #h tag on the server group — all subscribers see it.
    // One event instead of N encrypted DMs.
    final payload = json.encode({
      'type': 'voice_state_sync',
      'action': action,
      'server_nostr_group_id': server.nostrGroupId,
      'channel_id': widget.channelPublicId,
      'user_id': auth.publicKeyHex!.substring(0, 12),
      'user_pubkey': auth.publicKeyHex,
      'username': displayName,
      'avatar_url': contact?.avatarUrl,
      'self_mute': livekit.isMuted,
      'self_deaf': livekit.isDeafened,
    });

    final event = nostr.NostrEvent(
      pubkey: auth.publicKeyHex!,
      createdAt: nostr.NostrEvent.now(),
      kind: 10070,
      tags: [['h', server.nostrGroupId!]],
      content: payload,
    );

    final signer = NostrSigner(privateKeyHex: auth.privateKeyHex!);
    final signed = signer.sign(event);
    await relayPool.publish(signed);
  }

  @override
  Widget build(BuildContext context) {
    if (_channel == null) return const Center(child: CircularProgressIndicator());

    final c = ref.watch(infernoColorsProvider);
    final livekit = ref.watch(livekitServiceProvider);
    ref.watch(livekitConnectionProvider); // triggers rebuild on connect/disconnect
    final isConnected = livekit.isConnected;
    final hasParent = _channel!.parentChannelId != null;

    return Row(children: [
      // ── Main voice area (participants + status) ──
      Expanded(child: Column(children: [
        // Participant tiles
        Expanded(
          child: isConnected
              ? StreamBuilder<List<Participant>>(
                  stream: livekit.participantsStream,
                  builder: (context, snapshot) {
                    final participants = snapshot.data ?? livekit.participants;
                    if (participants.isEmpty) {
                      return Center(child: Text('Connecting...', style: TextStyle(color: c.gray500)));
                    }
                    // Responsive grid — match Rails large tile layout
                    final count = participants.length;
                    final cols = count <= 1 ? 1 : (count <= 4 ? 2 : 3);
                    return GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: count <= 2 ? 4 / 3 : 16 / 9,
                      ),
                      itemCount: count,
                      itemBuilder: (context, index) {
                        final p = participants[index];
                        final isMuted = p is LocalParticipant
                            ? !(p.isMicrophoneEnabled())
                            : p.audioTrackPublications.every((t) => t.muted);
                        // Use participant metadata for profile info
                        String? metaAvatar;
                        try {
                          if (p.metadata != null && p.metadata!.isNotEmpty) {
                            final meta = json.decode(p.metadata!) as Map<String, dynamic>;
                            metaAvatar = meta['avatar_url'] as String?;
                          }
                        } catch (_) {}

                        return _ParticipantCard(
                          identity: p.identity,
                          displayName: p.name.isNotEmpty ? p.name : null,
                          avatarUrlOverride: metaAvatar,
                          isMuted: isMuted,
                          isSpeaking: p.isSpeaking,
                          colors: c,
                        );
                      },
                    );
                  },
                )
              : Center(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.headset, size: 64, color: c.gray500),
                    const SizedBox(height: 16),
                    if (!_canConnect)
                      Text('You do not have permission to connect to voice channels.',
                        style: TextStyle(color: c.gray500, fontSize: 13)),
                    if (_canConnect && !_connecting)
                      GestureDetector(
                        onTap: _joinVoice,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                          decoration: BoxDecoration(color: c.online, borderRadius: BorderRadius.circular(6)),
                          child: const Text('Join Voice', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    if (_canConnect && _connecting)
                      SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: c.accent)),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: c.accent, fontSize: 13)),
                    ],
                  ]),
                ),
        ),

        // Bottom status bar — "Voice Connected" spanning content
        if (isConnected)
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.gray700.withValues(alpha: 0.3)))),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: c.online, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Text('Voice Connected', style: TextStyle(color: c.online, fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
      ])),

      // ── Sidechat panel (right side) — matches Rails Chat panel ──
      if (isConnected && _channel!.sidechatChannelId != null)
        Container(
          width: 300,
          decoration: BoxDecoration(
            color: c.gray800,
            border: Border(left: BorderSide(color: c.accent.withValues(alpha: 0.08))),
          ),
          child: Column(children: [
            // Chat header
            Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.gray700.withValues(alpha: 0.3)))),
              child: Row(children: [
                Icon(Icons.chat_bubble_outline, size: 16, color: c.gray400),
                const SizedBox(width: 8),
                Text('Chat', style: TextStyle(color: c.gray200, fontSize: 14, fontWeight: FontWeight.w600)),
              ]),
            ),
            // Sidechat messages placeholder
            Expanded(child: Center(child: Text('No messages yet', style: TextStyle(color: c.gray500, fontSize: 13)))),
          ]),
        ),
    ]);
  }
}

/// Large participant card matching Rails — avatar centered, name at bottom, speaking ring
class _ParticipantCard extends ConsumerWidget {
  final String identity;
  final String? displayName;
  final String? avatarUrlOverride;
  final bool isMuted;
  final bool isSpeaking;
  final InfernoColors colors;
  const _ParticipantCard({required this.identity, this.displayName, this.avatarUrlOverride, required this.isMuted, required this.isSpeaking, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = colors;
    final db = ref.read(databaseProvider);

    return FutureBuilder<_ProfileData>(
      future: _resolveProfile(db, identity),
      builder: (context, snap) {
        final resolved = snap.data;
        // Priority: resolved DB profile > LiveKit metadata > displayName > identity
        final name = resolved?.name ?? displayName ?? identity;
        final avatarUrl = avatarUrlOverride ?? resolved?.avatarUrl;
        final profileColor = resolved?.profileColor;
        final profile = _ProfileData(name: name, avatarUrl: avatarUrl, profileColor: profileColor);

        // Parse profile color hex → Color, fallback to gray800
        Color cardColor = c.gray800;
        Color avatarBg = c.gray700;
        if (profile.profileColor != null && profile.profileColor!.isNotEmpty) {
          try {
            final hex = profile.profileColor!.replaceFirst('#', '');
            cardColor = Color(int.parse('FF$hex', radix: 16));
            // Lighter variant for avatar bg: mix with white ~20%
            avatarBg = Color.lerp(cardColor, Colors.white, 0.2) ?? cardColor;
          } catch (_) {}
        }

        return _SpeakingCard(
          isSpeaking: isSpeaking,
          accentColor: c.accent,
          child: Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: isSpeaking ? c.accent : c.gray700, width: isSpeaking ? 2 : 1),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Avatar
              CircleAvatar(
                radius: 40,
                backgroundColor: avatarBg,
                backgroundImage: profile.avatarUrl != null && profile.avatarUrl!.startsWith('http')
                    ? NetworkImage(profile.avatarUrl!) : null,
                child: profile.avatarUrl == null || !profile.avatarUrl!.startsWith('http')
                    ? Text(profile.name[0].toUpperCase(), style: TextStyle(color: c.gray200, fontSize: 28, fontWeight: FontWeight.bold))
                    : null,
              ),
              // Name label at bottom
              Positioned(
                bottom: 8, left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (isMuted) ...[
                      Icon(Icons.mic_off, size: 12, color: c.accent),
                      const SizedBox(width: 4),
                    ],
                    Text(profile.name, style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
                  ]),
                ),
              ),
            ],
          ),
        ));
      },
    );
  }

  static Future<_ProfileData> _resolveProfile(InfernoDatabase db, String identity) async {
    // Identity could be: full pubkey, truncated pubkey (first 12-16 chars), or public_id
    // Try remote member first (has profileColor)
    var member = await (db.select(db.remoteMembers)..where((m) => m.pubkey.equals(identity) | m.publicId.equals(identity))..limit(1)).getSingleOrNull();
    if (member != null) return _ProfileData(name: member.displayName ?? member.username ?? identity, avatarUrl: member.avatarUrl, profileColor: member.profileColor);

    // Try exact pubkey match in contacts
    var contact = await (db.select(db.contacts)..where((c) => c.pubkey.equals(identity))..limit(1)).getSingleOrNull();
    if (contact != null) return _ProfileData(name: contact.displayName ?? contact.username ?? identity, avatarUrl: contact.avatarUrl);

    // Try prefix match — identity might be first 12-16 chars of a pubkey
    if (identity.length >= 8 && identity.length <= 16) {
      final members = await db.select(db.remoteMembers).get();
      member = members.where((m) => m.pubkey != null && m.pubkey!.startsWith(identity)).firstOrNull;
      if (member != null) return _ProfileData(name: member.displayName ?? member.username ?? identity, avatarUrl: member.avatarUrl, profileColor: member.profileColor);

      final contacts = await db.select(db.contacts).get();
      contact = contacts.where((c) => c.pubkey.startsWith(identity)).firstOrNull;
      if (contact != null) return _ProfileData(name: contact.displayName ?? contact.username ?? identity, avatarUrl: contact.avatarUrl);
    }

    return _ProfileData(name: identity.length > 12 ? '${identity.substring(0, 8)}...' : identity, avatarUrl: null);
  }
}

class _ProfileData {
  final String name;
  final String? avatarUrl;
  final String? profileColor;
  _ProfileData({required this.name, this.avatarUrl, this.profileColor});
}

/// Pulsing glow wrapper for speaking participants — matches Rails audio-level responsive ring
class _SpeakingCard extends StatefulWidget {
  final Widget child;
  final bool isSpeaking;
  final Color accentColor;
  const _SpeakingCard({required this.child, required this.isSpeaking, required this.accentColor});
  @override
  State<_SpeakingCard> createState() => _SpeakingCardState();
}

class _SpeakingCardState extends State<_SpeakingCard> with SingleTickerProviderStateMixin {
  AnimationController? _pulseController;

  @override
  void didUpdateWidget(_SpeakingCard old) {
    super.didUpdateWidget(old);
    if (widget.isSpeaking && !old.isSpeaking) {
      _pulseController ??= AnimationController(vsync: this, duration: const Duration(milliseconds: 800))
        ..addListener(() { if (mounted) setState(() {}); });
      _pulseController!.repeat(reverse: true);
    } else if (!widget.isSpeaking && old.isSpeaking) {
      _pulseController?.stop();
      _pulseController?.value = 0;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _pulseController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isSpeaking) return widget.child;

    final pulse = _pulseController?.value ?? 0.0;
    final glowIntensity = 0.25 + pulse * 0.35;
    final glowRadius = 8.0 + pulse * 12.0;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: widget.accentColor.withValues(alpha: glowIntensity),
            blurRadius: glowRadius,
            spreadRadius: 0,
          ),
          BoxShadow(
            color: widget.accentColor.withValues(alpha: 0.5),
            blurRadius: 3,
            spreadRadius: 0,
          ),
        ],
      ),
      child: widget.child,
    );
  }
}

class _VoiceBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool active;
  final bool danger;
  final InfernoColors colors;
  final VoidCallback onTap;
  const _VoiceBtn({required this.icon, required this.label, required this.active, this.danger = false,
    required this.colors, required this.onTap});
  @override
  State<_VoiceBtn> createState() => _VoiceBtnState();
}

class _VoiceBtnState extends State<_VoiceBtn> {
  bool _hovering = false;
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return Tooltip(
      message: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: widget.danger
                  ? (_hovering ? c.accent : c.accent.withValues(alpha: 0.6))
                  : (widget.active ? c.gray600 : (_hovering ? c.gray600 : c.gray800)),
              shape: BoxShape.circle,
            ),
            child: Icon(widget.icon, size: 20,
              color: widget.active ? Colors.white : (widget.danger ? Colors.white : c.gray400)),
          ),
        ),
      ),
    );
  }
}
