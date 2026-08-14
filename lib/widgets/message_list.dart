import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart' show Value, TableUpdateQuery;
import '../utils/stream_debounce.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../database/database.dart';
import '../models/permission.dart';
import '../providers/database_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/servers_provider.dart';
import '../providers/realtime_provider.dart';
import '../providers/server_settings_provider.dart';
import '../theme/all_themes.dart';
import '../theme/theme_provider.dart';
import 'reaction_bar.dart';
import 'unified_picker.dart';
import 'message_content.dart';
import 'user_profile_card.dart';
import 'context_menu.dart';
import '../services/gif_favorites_service.dart';
import '../screens/main_shell.dart';

typedef MessageReplyCallback = void Function(Message message, String authorName, String preview);

typedef MessageEditCallback = void Function(Message message);

class MessageList extends ConsumerStatefulWidget {
  final int? channelId;
  final int? conversationId;
  final MessageReplyCallback? onReply;
  final MessageEditCallback? onEdit;
  final Channel? channel;
  const MessageList({super.key, this.channelId, this.conversationId, this.onReply, this.onEdit, this.channel});

  /// Active instance registry — allows external code to scroll to a message
  static _MessageListState? _activeInstance;

  /// Scroll the active message list to a specific message and highlight it
  static void scrollToMessage(String nostrEventId) {
    _activeInstance?._scrollToAndHighlight(nostrEventId);
  }

  @override
  ConsumerState<MessageList> createState() => _MessageListState();
}

class _MessageListState extends ConsumerState<MessageList> {
  // ItemScrollController lets us jump to a specific index reliably regardless
  // of variable item heights. Paired with the ItemPositionsListener so we can
  // keep the saved scroll restore behavior.
  final ItemScrollController _itemController = ItemScrollController();
  final ItemPositionsListener _itemPositions = ItemPositionsListener.create();
  // Cache resolved author info: pubkey -> {name, avatarUrl}
  final Map<String, _AuthorInfo> _authorCache = {};
  // Cached reference to MainShellState — saved early so it's safe to use in dispose()
  MainShellState? _mainShell;
  // Cached message stream — prevents recreation on parent rebuilds which causes image flicker
  Stream<List<Message>>? _messageStream;
  int? _streamChannelId;
  // Message highlight state — when scrolling to a pinned message
  String? _highlightedEventId;
  // Custom emoji map: name -> url (loaded per server)
  Map<String, String> _customEmojis = {};
  // Current user's username(s) and role names — for mention highlighting
  Set<String> _myUsernames = {};
  Set<String> _myRoleNames = {};
  bool _mentionInfoLoaded = false;
  // Permission cache
  bool _canManageMessages = false;
  bool _canAddReactions = true;
  bool _canReadMessageHistory = true;
  // NSFW channel blur — null means not yet loaded from settings
  bool? _blurNsfwSetting;

  // Invalidates the author resolve cache and triggers a rebuild whenever the
  // contacts / remote_members tables change so avatars + display names update
  // live as profile metadata streams in (matches member list behavior).
  StreamSubscription<void>? _profileUpdatesSub;

  @override
  void initState() {
    super.initState();
    _loadCustomEmojis();
    _loadMentionInfo();
    _loadPermissions();
    _loadNsfwBlur();
    _initScrollController();
    _subscribeToProfileUpdates();
  }

  void _subscribeToProfileUpdates() {
    _profileUpdatesSub?.cancel();
    final db = ref.read(databaseProvider);
    // Debounce profile table changes — during sync dozens of Kind 0 events
    // fire rapidly. Only rebuild once the burst settles.
    _profileUpdatesSub = db
        .tableUpdates(TableUpdateQuery.onAllTables([db.contacts, db.remoteMembers]))
        .debounce(const Duration(milliseconds: 500))
        .listen((_) {
      if (!mounted) return;
      _authorCache.clear();
      _pendingResolves.clear();
      setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _mainShell = context.findAncestorStateOfType<MainShellState>();
  }

  @override
  void didUpdateWidget(MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelId != widget.channelId || oldWidget.conversationId != widget.conversationId) {
      // Save current scroll offset for the old channel/conversation
      _saveScrollOffset(oldWidget.channelId ?? oldWidget.conversationId ?? 0);
      _initScrollController();
      _authorCache.clear();
      _mentionInfoLoaded = false;
      _loadCustomEmojis();
      _loadMentionInfo();
      _loadPermissions();
      _loadNsfwBlur();
    } else if (oldWidget.channel?.nsfw != widget.channel?.nsfw) {
      // Channel nsfw flag changed dynamically — getter auto-recalculates
      setState(() {}); // trigger rebuild with new getter value
    }
  }

  Future<void> _loadCustomEmojis() async {
    final db = ref.read(databaseProvider);
    if (widget.channel != null) {
      // Channel: only this server's emojis
      final emojis = await (db.select(db.serverEmojis)
        ..where((e) => e.serverId.equals(widget.channel!.serverId)))
        .get();
      if (mounted) {
        setState(() {
          _customEmojis = {for (final e in emojis) if (e.url != null) e.name: e.url!};
        });
      }
    } else {
      // DM: merge current server emojis with the persistent emoji_cache so that
      // :shortcode: references keep resolving even after the source server was
      // left or the emoji was deleted server-side.
      final serverRows = await db.select(db.serverEmojis).get();
      final cacheRows = await db.select(db.emojiCache).get();
      final merged = <String, String>{};
      for (final c in cacheRows) {
        merged[c.name] = c.url;
      }
      for (final e in serverRows) {
        if (e.url != null && e.url!.isNotEmpty) merged[e.name] = e.url!;
      }
      if (mounted) {
        setState(() { _customEmojis = merged; });
      }
    }
  }

  Future<void> _loadMentionInfo() async {
    final auth = ref.read(authServiceProvider);
    if (auth.publicKeyHex == null) return;
    final db = ref.read(databaseProvider);
    final usernames = <String>{};

    // Get current user's usernames from contacts and remote members
    final contact = await db.contactsDao.getByPubkey(auth.publicKeyHex!);
    if (contact != null) {
      if (contact.username != null) usernames.add(contact.username!.toLowerCase());
      if (contact.displayName != null) usernames.add(contact.displayName!.toLowerCase());
    }
    if (widget.channel != null) {
      final members = await (db.select(db.remoteMembers)
            ..where((m) => m.pubkey.equals(auth.publicKeyHex!))
            ..where((m) => m.serverId.equals(widget.channel!.serverId)))
          .get();
      for (final m in members) {
        if (m.username != null) usernames.add(m.username!.toLowerCase());
        if (m.displayName != null) usernames.add(m.displayName!.toLowerCase());
      }

      // Get role names for the current user's roles
      final roleNames = <String>{};
      for (final m in members) {
        final memberRoles = await (db.select(db.remoteMembershipRoles)
              ..where((mr) => mr.remoteMemberId.equals(m.id)))
            .get();
        for (final mr in memberRoles) {
          final role = await (db.select(db.roles)
                ..where((r) => r.id.equals(mr.roleId)))
              .getSingleOrNull();
          if (role?.name != null) roleNames.add(role!.name!.toLowerCase());
        }
      }
      if (mounted) setState(() => _myRoleNames = roleNames);
    }

    if (mounted) {
      setState(() {
        _myUsernames = usernames;
        _mentionInfoLoaded = true;
      });
    }
  }

  Future<void> _loadPermissions() async {
    if (widget.channel == null) {
      _canManageMessages = false;
      _canAddReactions = true;
      return;
    }
    final auth = ref.read(authServiceProvider);
    if (auth.publicKeyHex == null) return;
    final permSvc = ref.read(permissionServiceProvider);
    final sid = widget.channel!.serverId;
    final pk = auth.publicKeyHex!;
    final results = await Future.wait([
      permSvc.hasPermission(sid, pk, Permission.manageMessages),
      permSvc.hasPermission(sid, pk, Permission.addReactions),
      permSvc.hasPermission(sid, pk, Permission.readMessageHistory),
    ]);
    if (mounted) {
      setState(() {
        _canManageMessages = results[0];
        _canAddReactions = results[1];
        _canReadMessageHistory = results[2];
      });
    }
  }

  Future<void> _loadNsfwBlur() async {
    final db = ref.read(databaseProvider);
    final settings = await (db.select(db.appSettings)..limit(1)).getSingleOrNull();
    final val = settings?.safetyBlurNsfw ?? true;
    if (mounted && val != _blurNsfwSetting) {
      setState(() => _blurNsfwSetting = val);
    }
  }

  /// NSFW blur is active when: channel is NSFW AND setting allows it (default: true).
  /// Before the setting loads, defaults to true (blur on) to be safe.
  bool get _blurNsfwImages => widget.channel?.nsfw == true && (_blurNsfwSetting ?? true);

  static final _mentionCheckPattern = RegExp(r'(?:^|\s)@(\w+)');

  bool _isMentioned(Message msg) {
    if (!_mentionInfoLoaded) return false;
    final content = msg.content?.toLowerCase() ?? '';
    if (content.isEmpty) return false;

    for (final match in _mentionCheckPattern.allMatches(content)) {
      final name = match.group(1)!;
      if (name == 'everyone' || name == 'here') return true;
      if (_myUsernames.contains(name)) return true;
      if (_myRoleNames.contains(name)) return true;
    }
    return false;
  }

  void _initScrollController() {
    _savedTopIndex = _mainShell
        ?.getScrollOffset((widget.channelId ?? widget.conversationId ?? 0).toString())
        ?.toInt();
  }

  int? _savedTopIndex;

  void _saveScrollOffset(int channelId) {
    // Save the top visible item index so the list can restore to roughly the
    // same spot on the next mount. ItemPositionsListener exposes the mounted
    // items; the one with the smallest itemLeadingEdge is at the top.
    final positions = _itemPositions.itemPositions.value;
    if (positions.isEmpty) return;
    final top = positions.reduce((a, b) =>
        a.itemLeadingEdge < b.itemLeadingEdge ? a : b);
    _mainShell?.saveScrollOffset(channelId.toString(), top.index.toDouble());
  }

  @override
  void dispose() {
    if (MessageList._activeInstance == this) MessageList._activeInstance = null;
    _saveScrollOffset(widget.channelId ?? widget.conversationId ?? 0);
    _profileUpdatesSub?.cancel();
    super.dispose();
  }

  // Cache latest messages for scroll-to lookup
  List<Message> _lastMessages = [];

  /// Scroll to a message by nostrEventId and highlight it briefly
  Future<void> _scrollToAndHighlight(String nostrEventId) async {
    // If the target isn't in the currently-loaded window yet, retry a few
    // times — the message may still be streaming in, or the user clicked a
    // reply pointing to an older message that's about to arrive.
    int index = _lastMessages.indexWhere((m) => m.nostrEventId == nostrEventId);
    for (int attempt = 0; attempt < 5 && index == -1; attempt++) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      index = _lastMessages.indexWhere((m) => m.nostrEventId == nostrEventId);
    }
    if (index == -1) return;

    setState(() => _highlightedEventId = nostrEventId);

    if (_itemController.isAttached) {
      // jumpTo sidesteps the semantics-collection race that scrollTo's
      // animation pipeline triggers in scrollable_positioned_list
      // (`!childSemantics.renderObject._needsLayout` assertions after a few
      // animated jumps). Instant jump = no animated frames = no bug.
      _itemController.jumpTo(index: index);
    }
    _scheduleHighlightClear();
  }

  void _scheduleHighlightClear() {
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _highlightedEventId = null);
    });
  }

  Future<_AuthorInfo> _resolveAuthor(String pubkey) async {
    final cached = _authorCache[pubkey];
    if (cached != null) return cached;

    final db = ref.read(databaseProvider);
    String name = '${pubkey.substring(0, 8)}...';
    String? avatarUrl;

    final contact = await db.contactsDao.getByPubkey(pubkey);
    if (contact != null) {
      name = contact.displayName ?? contact.username ?? name;
      avatarUrl = contact.avatarUrl;
    } else {
      final members = await (db.select(db.remoteMembers)
            ..where((m) => m.pubkey.equals(pubkey))
            ..limit(1))
          .get();
      if (members.isNotEmpty) {
        final m = members.first;
        name = m.displayName ?? m.username ?? name;
        avatarUrl = m.avatarUrl;
      }
    }

    Color? roleColor;
    final serverId = widget.channel?.serverId;
    if (serverId != null) {
      final permSvc = ref.read(permissionServiceProvider);
      final colorHex = await permSvc.getDisplayColor(serverId, pubkey);
      if (colorHex != '#ffffff') {
        roleColor = _parseHexColor(colorHex);
      }
    }

    final info = _AuthorInfo(name: name, avatarUrl: avatarUrl, roleColor: roleColor);
    _authorCache[pubkey] = info;
    return info;
  }

  /// Pre-resolve all authors for visible messages, then rebuild once
  final Map<String, Future<_AuthorInfo>> _pendingResolves = {};

  _AuthorInfo _getAuthorSync(String pubkey) {
    final cached = _authorCache[pubkey];
    if (cached != null) return cached;

    // Kick off async resolve if not already pending
    if (!_pendingResolves.containsKey(pubkey)) {
      _pendingResolves[pubkey] = _resolveAuthor(pubkey).then((info) {
        _pendingResolves.remove(pubkey);
        if (mounted) setState(() {});
        return info;
      });
    }

    return _AuthorInfo(name: '${pubkey.substring(0, 8)}...', avatarUrl: null);
  }

  static Color? _parseHexColor(String hex) {
    try {
      final cleaned = hex.replaceFirst('#', '');
      if (cleaned.length == 6) return Color(int.parse('FF$cleaned', radix: 16));
    } catch (_) {}
    return null;
  }

  Future<void> _handlePin(Message msg) async {
    if (widget.channel == null) return;
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null) return;
    final svc = ref.read(groupMessageServiceProvider);
    await svc.togglePin(
      privateKeyHex: auth.privateKeyHex!,
      publicKeyHex: auth.publicKeyHex!,
      channel: widget.channel!,
      message: msg,
    );
  }

  Future<void> _handleDelete(Message msg) async {
    if (widget.channel == null || msg.nostrEventId == null) return;
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null) return;
    final svc = ref.read(groupMessageServiceProvider);
    await svc.deleteMessage(
      privateKeyHex: auth.privateKeyHex!,
      publicKeyHex: auth.publicKeyHex!,
      channel: widget.channel!,
      eventId: msg.nostrEventId!,
    );
  }

  Future<void> _handleReaction(Message msg, String emoji) async {
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null || msg.nostrEventId == null) return;
    final svc = ref.read(reactionServiceProvider);
    await svc.toggleReaction(
      privateKeyHex: auth.privateKeyHex!,
      publicKeyHex: auth.publicKeyHex!,
      eventId: msg.nostrEventId!,
      emoji: emoji,
      channelGroupId: widget.channel?.nostrGroupId,
    );
    if (svc.lastAddWasBlocked && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Reaction limit reached (15 emojis per message).'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    MessageList._activeInstance = this; // always keep current
    final db = ref.watch(databaseProvider);
    final auth = ref.watch(authServiceProvider);
    final c = ref.watch(infernoColorsProvider);

    // Cache the stream to prevent recreation on parent rebuilds (avoids image flicker)
    final streamKey = widget.channelId ?? widget.conversationId ?? 0;
    if (_messageStream == null || _streamChannelId != streamKey) {
      if (widget.channelId != null) {
        _messageStream = db.messagesDao.watchChannelMessages(widget.channelId!);
      } else if (widget.conversationId != null) {
        _messageStream = db.messagesDao.watchConversationMessages(widget.conversationId!);
      }
      _streamChannelId = streamKey;
    }

    return StreamBuilder<List<Message>>(
      stream: _messageStream,
      builder: (context, snapshot) {
        var messages = snapshot.data ?? [];
        // readMessageHistory gate: when denied, show no history — user can still send new messages
        if (!_canReadMessageHistory) {
          messages = [];
        }
        _lastMessages = messages; // cache for scroll-to lookup

        if (messages.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 68, height: 68,
                  decoration: BoxDecoration(color: c.gray600, shape: BoxShape.circle),
                  child: Center(child: Text('#', style: TextStyle(color: c.gray400, fontSize: 32, fontWeight: FontWeight.bold))),
                ),
                const SizedBox(height: 16),
                Text('Welcome to the channel!', style: TextStyle(color: c.gray50, fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('This is the start of this channel.', style: TextStyle(color: c.gray500, fontSize: 14)),
              ],
            ),
          );
        }

        final initialIndex = (_savedTopIndex != null &&
                _savedTopIndex! >= 0 &&
                _savedTopIndex! < messages.length)
            ? _savedTopIndex!
            : 0;
        // ExcludeSemantics works around a known layout-ordering assertion in
        // scrollable_positioned_list on Flutter 3.4x where the semantics tree
        // is walked before child layout finishes, producing
        // `!childSemantics.renderObject._needsLayout` failures every frame.
        // We don't expose per-message accessibility nodes today.
        return ExcludeSemantics(
          child: ScrollablePositionedList.builder(
          itemScrollController: _itemController,
          itemPositionsListener: _itemPositions,
          initialScrollIndex: initialIndex,
          reverse: true,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: messages.length,
          addAutomaticKeepAlives: true,
          itemBuilder: (context, index) {
            final msg = messages[index];
            final prevMsg = index < messages.length - 1 ? messages[index + 1] : null;
            final isGrouped = prevMsg != null &&
                prevMsg.nostrAuthorPubkey == msg.nostrAuthorPubkey &&
                msg.createdAt.difference(prevMsg.createdAt).inMinutes.abs() < 5 &&
                !(msg.systemMessage);
            final isOwn = msg.nostrAuthorPubkey == null || msg.nostrAuthorPubkey == auth.publicKeyHex;

            if (msg.systemMessage) {
              return RepaintBoundary(child: _SystemMessage(message: msg, colors: c));
            }

            final isHighlighted = _highlightedEventId != null && msg.nostrEventId == _highlightedEventId;

            final author = _getAuthorSync(msg.nostrAuthorPubkey ?? auth.publicKeyHex ?? '');

            return RepaintBoundary(child: _HighlightWrap(
              // ValueKey, not GlobalObjectKey. A GlobalKey makes Flutter treat
              // the element as globally unique and RE-PARENT it whenever its
              // position changes — so every sync that inserts a message shifted
              // indices, deactivated and reactivated these elements in the same
              // frame, and rebuilt their subtrees. That recreated the avatar
              // Image state and made the list visibly blink while syncing.
              //
              // Nothing needed the global key: scroll-to-message is index-based
              // via _itemController.jumpTo (see _scrollToAndHighlight), not a
              // key lookup. A ValueKey gives the child-matching algorithm the
              // identity it needs to reuse elements in place.
              key: msg.nostrEventId != null ? ValueKey('msg-${msg.nostrEventId}') : null,
              highlighted: isHighlighted,
              accentColor: c.accent,
              child: _ChannelMessage(
                message: msg,
                isGrouped: isGrouped,
                isOwn: isOwn,
                authorName: author.name,
                authorAvatarUrl: author.avatarUrl,
                colors: c,
                db: db,
                authPubkey: auth.publicKeyHex,
                onReply: widget.onReply != null
                    ? () {
                        final preview = (msg.content ?? '').length > 80
                            ? '${msg.content!.substring(0, 80)}...'
                            : msg.content ?? '';
                        widget.onReply!(msg, author.name, preview);
                      }
                    : null,
                onPin: (isOwn || _canManageMessages) ? () => _handlePin(msg) : null,
                onDelete: (isOwn || _canManageMessages) ? () => _confirmDelete(context, msg, c) : null,
                onEdit: isOwn ? () => widget.onEdit?.call(msg) : null,
                onReaction: (emoji) => _handleReaction(msg, emoji),
                onAuthorTap: msg.nostrAuthorPubkey != null ? (rect) {
                  showUserProfileCard(context, ref, msg.nostrAuthorPubkey!,
                    anchor: rect.topLeft, anchorSize: rect.size);
                } : null,
                isDm: widget.conversationId != null,
                authorRoleColor: author.roleColor,
                customEmojis: _customEmojis,
                isMentioned: _isMentioned(msg),
                canAddReactions: _canAddReactions,
                blurNsfwImages: _blurNsfwImages,
              ),
            ));
          },
        ));
      },
    );
  }

  void _confirmDelete(BuildContext context, Message msg, InfernoColors c) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: c.gray800,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Delete Message', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text('Are you sure you want to delete this message? This cannot be undone.',
                style: TextStyle(color: c.gray400, fontSize: 14)),
              if (msg.content != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
                  child: Text(msg.content!, style: TextStyle(color: c.gray200, fontSize: 13), maxLines: 3, overflow: TextOverflow.ellipsis),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: c.gray400))),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                    onPressed: () { Navigator.pop(ctx); _handleDelete(msg); },
                    child: const Text('Delete', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

}

class _AuthorInfo {
  final String name;
  final String? avatarUrl;
  final Color? roleColor;
  _AuthorInfo({required this.name, this.avatarUrl, this.roleColor});
}

class _ChannelMessage extends StatefulWidget {
  final Message message;
  final bool isGrouped;
  final bool isOwn;
  final String authorName;
  final String? authorAvatarUrl;
  final InfernoColors colors;
  final InfernoDatabase db;
  final String? authPubkey;
  final VoidCallback? onReply;
  final VoidCallback? onPin;
  final VoidCallback? onDelete;
  final void Function(String emoji) onReaction;
  final void Function(Rect elementRect)? onAuthorTap;
  final VoidCallback? onEdit;
  final bool isDm;
  final Color? authorRoleColor;
  final Map<String, String> customEmojis;
  final bool isMentioned;
  final bool canAddReactions;
  final bool blurNsfwImages;

  const _ChannelMessage({
    required this.message,
    required this.isGrouped,
    required this.isOwn,
    required this.authorName,
    this.authorAvatarUrl,
    required this.colors,
    required this.db,
    this.authPubkey,
    this.onReply,
    this.onPin,
    this.onDelete,
    required this.onReaction,
    this.onAuthorTap,
    this.onEdit,
    this.isDm = false,
    this.authorRoleColor,
    this.customEmojis = const {},
    this.isMentioned = false,
    this.canAddReactions = true,
    this.blurNsfwImages = false,
  });

  @override
  State<_ChannelMessage> createState() => _ChannelMessageState();
}

class _ChannelMessageState extends State<_ChannelMessage> with AutomaticKeepAliveClientMixin {
  bool _hovering = false;
  OverlayEntry? _reactPickerOverlay;
  final GlobalKey _reactButtonKey = GlobalKey();

  /// Merge per-message custom emoji URLs (stored from NIP-30 tags / payload) with
  /// the global map (server emoji + persistent cache). Per-message URLs win so
  /// a message keeps rendering even if the source server deleted the emoji or
  /// the user left that server.
  Map<String, String> _emojisForMessage(Message msg) {
    if (msg.customEmojiUrls == null || msg.customEmojiUrls!.isEmpty) {
      return widget.customEmojis;
    }
    try {
      final decoded = json.decode(msg.customEmojiUrls!);
      if (decoded is! Map) return widget.customEmojis;
      final perMsg = decoded.cast<String, dynamic>().map(
            (k, v) => MapEntry(k, v is String ? v : ''),
          );
      return {...widget.customEmojis, ...perMsg};
    } catch (_) {
      return widget.customEmojis;
    }
  }

  void _showReactPicker() {
    _closeReactPicker();

    // Get the react button's global position for absolute placement
    final renderBox = _reactButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final buttonPos = renderBox.localToGlobal(Offset.zero);
    final buttonSize = renderBox.size;
    final screen = MediaQuery.of(context).size;

    const pickerW = 384.0;
    const pickerH = 380.0;

    // Position: right-aligned with button, above the button
    double left = buttonPos.dx + buttonSize.width - pickerW;
    double top = buttonPos.dy - pickerH - 4;

    // Clamp to screen bounds
    if (left < 8) left = 8;
    if (left + pickerW > screen.width - 8) left = screen.width - pickerW - 8;
    if (top < 8) {
      // Not enough space above — show below instead
      top = buttonPos.dy + buttonSize.height + 4;
    }
    if (top + pickerH > screen.height - 8) top = screen.height - pickerH - 8;

    // Keep hover actions visible while picker is open
    setState(() => _hovering = true);

    _reactPickerOverlay = OverlayEntry(builder: (ctx) {
      return Stack(children: [
        Positioned.fill(child: GestureDetector(
          onTap: _closeReactPicker,
          behavior: HitTestBehavior.translucent,
          child: Container(color: Colors.transparent),
        )),
        Positioned(
          left: left,
          top: top,
          width: pickerW,
          height: pickerH,
          child: Material(
            color: Colors.transparent,
            child: UnifiedPicker(
              emojiOnly: true,
              onEmojiSelect: (emoji) {
                widget.onReaction(emoji);
                _closeReactPicker();
              },
            ),
          ),
        ),
      ]);
    });
    Overlay.of(context).insert(_reactPickerOverlay!);
  }

  /// Close picker from user interaction (tap-outside, emoji select) — triggers rebuild
  void _closeReactPicker() {
    _reactPickerOverlay?.remove();
    _reactPickerOverlay = null;
    if (mounted) setState(() => _hovering = false);
  }

  @override
  void dispose() {
    _reactPickerOverlay?.remove();
    _reactPickerOverlay = null;
    super.dispose();
  }

  /// Only keep alive messages with media content (images, video, audio, embeds).
  /// Plain text messages are cheap to rebuild — keeping them all alive bloats
  /// memory and causes stutter when the theme changes (every kept-alive widget rebuilds).
  @override
  bool get wantKeepAlive {
    final content = widget.message.content ?? '';
    final hasFiles = widget.message.fileUrls != null && widget.message.fileUrls!.isNotEmpty;
    if (hasFiles) return true;
    // Check for URLs that would create heavy embed widgets
    return content.contains('http://') || content.contains('https://');
  }

  /// Detect GIF URL in a message — checks tenor media, .gif extension, tenor view pages
  static String? _extractGifUrl(String content) {
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('http')) {
        final lower = trimmed.toLowerCase();
        if (lower.contains('tenor.com') || lower.endsWith('.gif') || lower.contains('.gif?')) {
          return trimmed;
        }
      }
    }
    return null;
  }

  void _showContextMenu(TapDownDetails details) async {
    final content = widget.message.content ?? '';
    final gifUrl = _extractGifUrl(content);

    // Build GIF collection items if message contains a GIF
    List<CtxEntry> gifItems = [];
    if (gifUrl != null) {
      final favService = GifFavoritesService(widget.db, 1);
      final collections = await favService.watchCollections().first;
      final defaultCol = await favService.getDefaultCollection();
      final containingIds = await favService.getCollectionIdsContainingGif(gifUrl);

      if (!mounted) return;

      // Exclude Favorites from collection menus — fire icon handles that
      final customCollections = collections.where((c) => c.id != defaultCol.id).toList();

      // "Add to Collection" submenu — only custom collections that don't already have this GIF
      final addToItems = <CtxEntry>[];
      for (final col in customCollections) {
        if (containingIds.contains(col.id)) continue;
        final iconText = col.icon ?? '\u{1F4C1}';
        final isUrl = iconText.startsWith('http');
        addToItems.add(CtxItem(
          '${isUrl ? '' : '$iconText '}${col.name}', null,
          () async {
            await favService.addToCollection(
              collectionId: col.id,
              tenorGifId: gifUrl,
              tenorUrl: gifUrl,
              previewUrl: gifUrl,
              gifUrl: gifUrl,
            );
          },
        ));
      }

      if (addToItems.isNotEmpty) {
        gifItems.add(CtxItem('Add to Collection', Icons.folder_open, () {}, submenu: addToItems));
      }

      // "Remove from" submenu — only custom collections that contain this GIF
      final customContainingIds = containingIds.where((id) => id != defaultCol.id).toSet();
      if (customContainingIds.isNotEmpty) {
        final removeItems = <CtxEntry>[];
        for (final col in customCollections) {
          if (!customContainingIds.contains(col.id)) continue;
          final iconText = col.icon ?? '\u{1F4C1}';
          final isUrl = iconText.startsWith('http');
          removeItems.add(CtxItem(
            '${isUrl ? '' : '$iconText '}${col.name}', null,
            () async {
              final favs = await favService.watchFavorites(col.id).first;
              final match = favs.where((f) => f.tenorGifId == gifUrl).firstOrNull;
              if (match != null) await favService.removeFavorite(match.id);
            },
            danger: true,
          ));
        }
        gifItems.add(CtxItem('Remove from', Icons.delete_outline, () {}, submenu: removeItems));
      }
    }

    if (!mounted) return;

    showStyledMenu(
      context: context,
      position: details.globalPosition,
      items: [
        CtxItem('Copy Text', Icons.copy, () {
          if (widget.message.content != null) Clipboard.setData(ClipboardData(text: widget.message.content!));
        }),
        CtxItem('Reply', Icons.reply, () => widget.onReply?.call()),
        CtxItem(widget.message.pinned == true ? 'Unpin' : 'Pin', Icons.push_pin_outlined, () => widget.onPin?.call()),
        if (widget.isOwn) CtxItem('Edit', Icons.edit_outlined, () => widget.onEdit?.call()),
        if (widget.message.hiddenAt == null)
          CtxItem('Hide Message', Icons.visibility_off_outlined, () async {
            await (widget.db.update(widget.db.messages)
                  ..where((m) => m.id.equals(widget.message.id)))
                .write(MessagesCompanion(
              hiddenAt: Value(DateTime.now()),
              hiddenReason: const Value('manual'),
            ));
          })
        else
          CtxItem('Unhide Message', Icons.visibility_outlined, () async {
            if (widget.message.hiddenReason?.contains('csam') == true) return;
            await (widget.db.update(widget.db.messages)
                  ..where((m) => m.id.equals(widget.message.id)))
                .write(const MessagesCompanion(
              hiddenAt: Value(null),
              hiddenReason: Value(null),
            ));
          }),
        // GIF collection items
        if (gifItems.isNotEmpty) ...[
          CtxDivider(),
          ...gifItems,
        ],
        if (widget.isOwn) ...[
          CtxDivider(),
          CtxItem('Delete', Icons.delete_outline, () => widget.onDelete?.call(), danger: true),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    final c = widget.colors;
    final msg = widget.message;
    // In DMs/group chats, don't color names — use neutral white for all
    // In server channels, own messages use accent color
    // Use role color for author name — matches Rails role_color_for(server)
    final nameColor = widget.authorRoleColor ?? c.gray50;

    return GestureDetector(
      onSecondaryTapDown: _showContextMenu,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) { if (_reactPickerOverlay == null) setState(() => _hovering = false); },
        child: Container(
          padding: EdgeInsets.only(top: widget.isGrouped ? 2 : 12, bottom: widget.isGrouped ? 2 : 12, left: 14, right: 16),
          decoration: BoxDecoration(
            color: widget.isMentioned && !_hovering ? c.accent.withValues(alpha: 0.06) : null,
            gradient: _hovering ? LinearGradient(
              colors: [c.accent.withValues(alpha: widget.isMentioned ? 0.12 : 0.06), Colors.transparent],
              begin: Alignment.centerLeft, end: Alignment.centerRight,
            ) : null,
            border: Border(left: BorderSide(
              color: _hovering ? c.accent.withValues(alpha: 0.4)
                  : widget.isMentioned ? c.accent.withValues(alpha: 0.3) : Colors.transparent,
              width: 2,
            )),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Avatar column
                  SizedBox(
                    width: 40,
                    child: widget.isGrouped
                        // Always laid out; only opacity changes. Swapping
                        // between an empty SizedBox and a Text made the row
                        // reflow on hover: "10:30 PM" at fontSize 10 is wider
                        // than this 40px gutter, so it wrapped to two lines and
                        // grew the row. Rails avoids this the same way — a
                        // fixed w-10 spacer whose span is always present with
                        // opacity-0 / group-hover:opacity-100.
                        //
                        // scaleDown keeps a long timestamp on one line without
                        // overflowing the gutter, and never scales up, so the
                        // common case still renders at exactly fontSize 10.
                        ? Center(
                            child: Opacity(
                              opacity: _hovering ? 1.0 : 0.0,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  DateFormat('h:mm a').format(msg.createdAt.toLocal()),
                                  maxLines: 1,
                                  softWrap: false,
                                  style: TextStyle(color: c.gray500, fontSize: 10),
                                ),
                              ),
                            ),
                          )
                        : GestureDetector(
                            onTap: () {
                              final box = context.findRenderObject() as RenderBox?;
                              if (box != null) {
                                final pos = box.localToGlobal(Offset.zero);
                                widget.onAuthorTap?.call(Rect.fromLTWH(pos.dx, pos.dy, box.size.width, box.size.height));
                              }
                            },
                            child: MouseRegion(cursor: SystemMouseCursors.click, child: CircleAvatar(
                              radius: 20,
                              backgroundColor: Colors.transparent,
                              // ResizeImage caps the decode at the size actually
                              // drawn (radius 20 = 40dp, allowing 3x DPR) instead
                              // of decoding a full-resolution avatar for a 40dp
                              // circle. Cheaper in memory, and makes any decode
                              // fast enough not to be seen. Part of #42.
                              backgroundImage: widget.authorAvatarUrl != null && widget.authorAvatarUrl!.startsWith('http')
                                  ? ResizeImage(
                                      NetworkImage(widget.authorAvatarUrl!),
                                      width: 120,
                                      height: 120,
                                      policy: ResizeImagePolicy.fit,
                                    )
                                  : null,
                              child: (widget.authorAvatarUrl == null || !widget.authorAvatarUrl!.startsWith('http'))
                                  ? Text(widget.authorName[0].toUpperCase(), style: TextStyle(color: c.gray200, fontSize: 16))
                                  : null,
                            )),
                          ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Reply indicator — mini avatar + author + snippet,
                        // click to jump to the parent. Rendered before the
                        // author line so it sits above the replier's name.
                        if (msg.parentId != null)
                          _ReplyIndicator(
                            db: widget.db,
                            parentId: msg.parentId!,
                            colors: c,
                            customEmojis: widget.customEmojis,
                          ),
                        if (!widget.isGrouped)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Row(children: [
                              MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: Builder(builder: (ctx) => GestureDetector(
                                  onTap: () {
                                    final box = ctx.findRenderObject() as RenderBox?;
                                    if (box != null) {
                                      final pos = box.localToGlobal(Offset.zero);
                                      widget.onAuthorTap?.call(Rect.fromLTWH(pos.dx, pos.dy, box.size.width, box.size.height));
                                    }
                                  },
                                  child: Text(widget.authorName, style: TextStyle(color: nameColor, fontWeight: FontWeight.w600, fontSize: 14)),
                                )),
                              ),
                              const SizedBox(width: 8),
                              Text(DateFormat('MM/dd/yyyy h:mm a').format(msg.createdAt.toLocal()), style: TextStyle(color: c.gray500, fontSize: 12)),
                              if (msg.editedAt != null) ...[
                                const SizedBox(width: 4),
                                Text('(edited)', style: TextStyle(color: c.gray500, fontSize: 11)),
                              ],
                            ]),
                          ),
                        if (msg.pinned == true)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Row(children: [
                              Icon(Icons.push_pin, size: 12, color: c.idle),
                              const SizedBox(width: 4),
                              Text('Pinned', style: TextStyle(color: c.idle, fontSize: 12)),
                            ]),
                          ),
                        if ((msg.content != null && msg.content!.isNotEmpty) || (msg.fileUrls != null && msg.fileUrls!.isNotEmpty))
                          MessageContent(content: msg.content ?? '', colors: c, isSpoiler: msg.spoiler, customEmojis: _emojisForMessage(msg), fileUrls: msg.fileUrls,
                            blurImages: widget.blurNsfwImages || (msg.hiddenReason != null && msg.hiddenReason!.contains('nsfw'))),
                        // Reactions
                        StreamBuilder<List<Reaction>>(
                          stream: widget.db.messagesDao.watchReactions(msg.id),
                          builder: (context, snap) {
                            final reactions = snap.data ?? [];
                            if (reactions.isEmpty) return const SizedBox.shrink();
                            final grouped = <String, int>{};
                            final own = <String>{};
                            for (final r in reactions) {
                              if (r.emoji == null) continue;
                              grouped[r.emoji!] = (grouped[r.emoji!] ?? 0) + 1;
                              if (r.reactorPubkey == widget.authPubkey) own.add(r.emoji!);
                            }
                            return ReactionBar(
                              reactions: grouped,
                              ownReactions: own,
                              onToggle: widget.canAddReactions ? widget.onReaction : (_) {},
                              onAddReaction: widget.canAddReactions ? _showReactPicker : null,
                              colors: c,
                              customEmojis: widget.customEmojis,
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (_hovering || _reactPickerOverlay != null)
                Positioned(
                  top: widget.isGrouped ? -12 : 4,
                  right: 0,
                  child: _MessageActions(
                    key: _reactButtonKey,
                    colors: c,
                    isOwn: widget.isOwn,
                    isPinned: msg.pinned == true,
                    onReply: widget.onReply,
                    onPin: widget.onPin,
                    onEdit: widget.isOwn ? () => widget.onEdit?.call() : null,
                    onDelete: widget.onDelete,
                    onReact: widget.canAddReactions ? _showReactPicker : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageActions extends StatelessWidget {
  final InfernoColors colors;
  final bool isOwn;
  final bool isPinned;
  final VoidCallback? onReply;
  final VoidCallback? onPin;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onReact;

  const _MessageActions({
    super.key,
    required this.colors, required this.isOwn, required this.isPinned,
    this.onReply, this.onPin, this.onEdit, this.onDelete, this.onReact,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: colors.gray800, borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors.gray700),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (onReact != null) _ActionButton(icon: Icons.emoji_emotions_outlined, tooltip: 'React', colors: colors, onTap: onReact),
        _ActionButton(icon: Icons.reply, tooltip: 'Reply', colors: colors, onTap: onReply),
        _ActionButton(icon: isPinned ? Icons.push_pin : Icons.push_pin_outlined, tooltip: isPinned ? 'Unpin' : 'Pin', colors: colors, onTap: onPin),
        if (isOwn) _ActionButton(icon: Icons.edit_outlined, tooltip: 'Edit', colors: colors, onTap: onEdit),
        if (isOwn) _ActionButton(icon: Icons.delete_outline, tooltip: 'Delete', colors: colors, onTap: onDelete, hoverColor: colors.accent),
      ]),
    );
  }
}

class _ActionButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final InfernoColors colors;
  final Color? hoverColor;
  final VoidCallback? onTap;
  const _ActionButton({required this.icon, required this.tooltip, required this.colors, this.hoverColor, this.onTap});

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
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
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(widget.icon, size: 16,
              color: _hovering ? (widget.hoverColor ?? widget.colors.gray200) : widget.colors.gray400),
          ),
        ),
      ),
    );
  }
}

/// Flashing highlight wrapper for scroll-to-message — no layout shift
class _HighlightWrap extends StatefulWidget {
  final Widget child;
  final bool highlighted;
  final Color accentColor;
  const _HighlightWrap({super.key, required this.child, required this.highlighted, required this.accentColor});
  @override
  State<_HighlightWrap> createState() => _HighlightWrapState();
}

class _HighlightWrapState extends State<_HighlightWrap> with SingleTickerProviderStateMixin {
  AnimationController? _flashController;

  @override
  void initState() {
    super.initState();
    if (widget.highlighted) _startFlash();
  }

  @override
  void didUpdateWidget(_HighlightWrap old) {
    super.didUpdateWidget(old);
    if (widget.highlighted && !old.highlighted) {
      _startFlash();
    } else if (!widget.highlighted && old.highlighted) {
      _flashController?.stop();
      _flashController?.dispose();
      _flashController = null;
      if (mounted) setState(() {});
    }
  }

  void _startFlash() {
    _flashController?.dispose();
    _flashController = AnimationController(vsync: this, duration: const Duration(milliseconds: 500))
      ..addListener(() { if (mounted) setState(() {}); })
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _flashController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.highlighted || _flashController == null) return widget.child;

    return AnimatedBuilder(
      animation: _flashController!,
      builder: (context, child) {
        final opacity = _flashController!.value * 0.15;
        return Container(
          decoration: BoxDecoration(
            color: widget.accentColor.withValues(alpha: opacity),
            // No border — avoid layout shift. Use boxShadow for the left accent glow instead.
            boxShadow: [
              BoxShadow(
                color: widget.accentColor.withValues(alpha: _flashController!.value * 0.4),
                blurRadius: 4,
                offset: const Offset(-2, 0),
              ),
            ],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class _SystemMessage extends StatelessWidget {
  final Message message;
  final InfernoColors colors;
  const _SystemMessage({required this.message, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 16),
      child: Row(children: [
        Icon(Icons.arrow_forward, size: 16, color: colors.online),
        const SizedBox(width: 8),
        Expanded(child: Text(message.content ?? '', style: TextStyle(color: colors.gray400, fontSize: 14))),
        const SizedBox(width: 8),
        Text(DateFormat('MM/dd/yyyy h:mm a').format(message.createdAt.toLocal()), style: TextStyle(color: colors.gray500, fontSize: 12)),
      ]),
    );
  }
}

/// Small inline preview shown above a reply: parent author avatar + name +
/// a one-line snippet of the parent message. Tapping scrolls the list to
/// the parent and briefly highlights it.
class _ReplyIndicator extends StatefulWidget {
  final InfernoDatabase db;
  final int parentId;
  final InfernoColors colors;
  final Map<String, String> customEmojis;
  const _ReplyIndicator({
    required this.db,
    required this.parentId,
    required this.colors,
    this.customEmojis = const {},
  });

  @override
  State<_ReplyIndicator> createState() => _ReplyIndicatorState();
}

class _ReplyIndicatorState extends State<_ReplyIndicator> {
  Message? _parent;
  String? _authorName;
  String? _authorAvatarUrl;
  Color? _authorColor;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _ReplyIndicator old) {
    super.didUpdateWidget(old);
    if (old.parentId != widget.parentId) _load();
  }

  Future<void> _load() async {
    final parent = await (widget.db.select(widget.db.messages)
          ..where((m) => m.id.equals(widget.parentId)))
        .getSingleOrNull();
    if (!mounted) return;
    if (parent == null) {
      setState(() => _parent = null);
      return;
    }
    String? name;
    String? avatar;
    Color? color;
    final pubkey = parent.nostrAuthorPubkey;
    if (pubkey != null) {
      // Prefer a server-scoped remote_members row (gives role color) and fall
      // back to the contacts row.
      final members = await (widget.db.select(widget.db.remoteMembers)
            ..where((m) => m.pubkey.equals(pubkey)))
          .get();
      final rm = members.isEmpty
          ? null
          : members.reduce((best, m) {
              int score(RemoteMember r) => [r.displayName, r.avatarUrl, r.profileColor]
                  .where((v) => v != null && v.isNotEmpty)
                  .length;
              return score(m) > score(best) ? m : best;
            });
      final contact = await (widget.db.select(widget.db.contacts)
            ..where((c) => c.pubkey.equals(pubkey)))
          .getSingleOrNull();
      name = rm?.displayName ?? rm?.username ?? contact?.displayName ?? contact?.username;
      avatar = rm?.avatarUrl ?? contact?.avatarUrl;
      final colorHex = rm?.profileColor;
      if (colorHex != null && colorHex.isNotEmpty) {
        try {
          color = Color(int.parse(colorHex.replaceFirst('#', 'FF'), radix: 16));
        } catch (_) {}
      }
    }
    if (!mounted) return;
    setState(() {
      _parent = parent;
      _authorName = name ?? (pubkey != null ? '${pubkey.substring(0, 8)}…' : 'Unknown');
      _authorAvatarUrl = avatar;
      _authorColor = color;
    });
  }

  void _jumpToParent() {
    final eventId = _parent?.nostrEventId;
    if (eventId == null) return;
    MessageList.scrollToMessage(eventId);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    if (_parent == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          Icon(Icons.reply, size: 12, color: c.gray500),
          const SizedBox(width: 4),
          Text('Reply to a message', style: TextStyle(color: c.gray500, fontSize: 12, fontStyle: FontStyle.italic)),
        ]),
      );
    }
    final snippet = (_parent!.content ?? '').replaceAll('\n', ' ').trim();
    final nameColor = _authorColor ?? c.accent;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _jumpToParent,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Icon(Icons.reply, size: 12, color: c.gray500),
            const SizedBox(width: 4),
            CircleAvatar(
              radius: 9,
              backgroundColor: c.gray700,
              backgroundImage: _authorAvatarUrl != null && _authorAvatarUrl!.startsWith('http')
                  ? NetworkImage(_authorAvatarUrl!)
                  : null,
              child: (_authorAvatarUrl == null || !_authorAvatarUrl!.startsWith('http'))
                  ? Text((_authorName ?? '?')[0].toUpperCase(),
                      style: TextStyle(color: c.gray200, fontSize: 9, fontWeight: FontWeight.w600))
                  : null,
            ),
            const SizedBox(width: 6),
            Text('@${_authorName ?? 'Unknown'}',
                style: TextStyle(color: nameColor, fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                snippet.isEmpty ? '(attachment)' : snippet,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: c.gray400,
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
