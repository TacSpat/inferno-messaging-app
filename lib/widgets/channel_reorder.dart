import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/servers_provider.dart';
import '../providers/realtime_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/unread_provider.dart';
import '../theme/all_themes.dart';
import 'context_menu.dart';
import 'package:livekit_client/livekit_client.dart' show LocalParticipant, Participant;

// Constants matching Rails channel_reorder_controller.js
const _kDragThreshold = 5.0;
const _kScrollEdge = 40.0;
const _kScrollSpeed = 8.0;
const _kNestHoverMs = 600;
const _kMaxDepth = 3;
const _kSaveDebounceMs = 800;

/// An item in the channel sidebar tree — either a category header or a channel.
class _TreeItem {
  final Category? category;
  final Channel? channel;
  final int depth; // 0 = root, 1+ = nested under voice
  final bool isLastInCategory;

  _TreeItem({this.category, this.channel, this.depth = 0, this.isLastInCategory = false});

  String get id => category != null ? 'cat-${category!.publicId}' : 'ch-${channel!.publicId}';
  bool get isCategory => category != null;
  bool get isVoice => channel?.channelType == 1;
  int get position => category?.position ?? channel?.position ?? 0;
}

/// Custom drag-and-drop channel list matching the Rails channel_reorder_controller.js
class ChannelReorderList extends ConsumerStatefulWidget {
  final Server server;
  final String? activeChannelId;
  final List<Channel> channels;
  final List<Category> categories;
  final InfernoColors colors;
  final Set<String> collapsedCategories;
  final void Function(String catId) onToggleCategory;
  final void Function(Channel)? onEditChannel;
  final void Function(Channel)? onDeleteChannel;
  final void Function(Category)? onEditCategory;
  final void Function(Category)? onDeleteCategory;
  final void Function(Category? category, {int? position})? onCreateChannel;
  final void Function({int? position})? onCreateCategory;

  const ChannelReorderList({
    super.key,
    required this.server,
    this.activeChannelId,
    required this.channels,
    required this.categories,
    required this.colors,
    required this.collapsedCategories,
    required this.onToggleCategory,
    this.onEditChannel,
    this.onDeleteChannel,
    this.onEditCategory,
    this.onDeleteCategory,
    this.onCreateChannel,
    this.onCreateCategory,
  });

  @override
  ConsumerState<ChannelReorderList> createState() => _ChannelReorderListState();
}

class _ChannelReorderListState extends ConsumerState<ChannelReorderList> {
  final ScrollController _scrollController = ScrollController();

  // Drag state (mirrors Rails _state: idle | pending | dragging)
  String _dragState = 'idle';
  _TreeItem? _draggedItem;
  Offset _startPos = Offset.zero;
  Offset _currentPos = Offset.zero;
  int? _dropIndex;
  Timer? _saveTimer;
  Timer? _scrollTimer;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _saveTimer?.cancel();
    _scrollTimer?.cancel();
    super.dispose();
  }

  List<_TreeItem> _buildFlatTree() {
    final items = <_TreeItem>[];

    // Interleave root channels and categories by position
    final rootChannels = widget.channels.where((ch) => ch.categoryId == null && ch.parentChannelId == null).toList();
    final sortable = <_TreeItem>[];

    for (final cat in widget.categories) {
      sortable.add(_TreeItem(category: cat));
    }
    for (final ch in rootChannels) {
      sortable.add(_TreeItem(channel: ch));
    }
    sortable.sort((a, b) => a.position.compareTo(b.position));

    for (final item in sortable) {
      if (item.isCategory) {
        items.add(item);
        final isCollapsed = widget.collapsedCategories.contains(item.category!.publicId);
        if (!isCollapsed) {
          final catChannels = widget.channels
              .where((ch) => ch.categoryId == item.category!.id && ch.parentChannelId == null)
              .toList()
            ..sort((a, b) => (a.position ?? 0).compareTo(b.position ?? 0));
          for (int i = 0; i < catChannels.length; i++) {
            final ch = catChannels[i];
            items.add(_TreeItem(channel: ch, isLastInCategory: i == catChannels.length - 1));
            // Add nested children for voice channels
            if (ch.channelType == 1) {
              _addChildren(items, ch, 1);
            }
          }
        }
      } else {
        items.add(item);
        // Add nested children for root voice channels
        if (item.isVoice) {
          _addChildren(items, item.channel!, 1);
        }
      }
    }

    return items;
  }

  void _addChildren(List<_TreeItem> items, Channel parent, int depth) {
    final children = widget.channels
        .where((ch) => ch.parentChannelId == parent.id)
        .toList()
      ..sort((a, b) => (a.position ?? 0).compareTo(b.position ?? 0));
    for (final child in children) {
      items.add(_TreeItem(channel: child, depth: depth));
      if (child.channelType == 1 && depth < _kMaxDepth - 1) {
        _addChildren(items, child, depth + 1);
      }
    }
  }

  void _onPointerDown(PointerDownEvent event, _TreeItem item) {
    if (_dragState != 'idle') return;
    _dragState = 'pending';
    _startPos = event.position;
    _draggedItem = item;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_dragState == 'pending') {
      final delta = event.position - _startPos;
      if (delta.distance < _kDragThreshold) return;
      setState(() {
        _dragState = 'dragging';
        _currentPos = event.position;
      });
    }
    if (_dragState != 'dragging') return;

    setState(() => _currentPos = event.position);

    // Find drop target
    final items = _buildFlatTree();
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final localPos = renderBox.globalToLocal(event.position);
    final scrollOffset = _scrollController.offset;
    final y = localPos.dy + scrollOffset;

    // Calculate which item index we're over
    const itemHeight = 34.0;
    const catHeight = 36.0;
    double accumulatedY = 8; // top padding
    int? newDropIndex;

    for (int i = 0; i < items.length; i++) {
      final h = items[i].isCategory ? catHeight : itemHeight;
      if (y < accumulatedY + h / 2) {
        newDropIndex = i;
        break;
      }
      accumulatedY += h;
    }
    newDropIndex ??= items.length;

    if (newDropIndex != _dropIndex) {
      setState(() => _dropIndex = newDropIndex);
    }

    // Auto-scroll
    _handleAutoScroll(localPos.dy, renderBox.size.height);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_dragState == 'pending') {
      _dragState = 'idle';
      _draggedItem = null;
      return;
    }
    if (_dragState == 'dragging' && _draggedItem != null && _dropIndex != null) {
      _performDrop();
    }
    setState(() {
      _dragState = 'idle';
      _draggedItem = null;
      _dropIndex = null;
    });
    _stopAutoScroll();
  }

  void _handleAutoScroll(double localY, double viewportHeight) {
    if (localY < _kScrollEdge) {
      final speed = _kScrollSpeed * (1 - localY / _kScrollEdge);
      _startAutoScroll(-speed);
    } else if (localY > viewportHeight - _kScrollEdge) {
      final speed = _kScrollSpeed * (1 - (viewportHeight - localY) / _kScrollEdge);
      _startAutoScroll(speed);
    } else {
      _stopAutoScroll();
    }
  }

  void _startAutoScroll(double speed) {
    _scrollTimer?.cancel();
    _scrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(
          (_scrollController.offset + speed).clamp(0.0, _scrollController.position.maxScrollExtent),
        );
      }
    });
  }

  void _stopAutoScroll() {
    _scrollTimer?.cancel();
    _scrollTimer = null;
  }

  Future<void> _performDrop() async {
    final items = _buildFlatTree();
    final draggedItem = _draggedItem;
    final dropIdx = _dropIndex;
    if (draggedItem == null || dropIdx == null) return;

    final currentIdx = items.indexWhere((i) => i.id == draggedItem.id);
    if (currentIdx == -1 || currentIdx == dropIdx) return;

    final db = ref.read(databaseProvider);
    final now = DateTime.now();

    if (draggedItem.isCategory) {
      // Reorder categories: remove from current position, insert at drop position
      final sortedCats = [...widget.categories]..sort((a, b) => (a.position ?? 0).compareTo(b.position ?? 0));
      final catIdx = sortedCats.indexWhere((c) => c.publicId == draggedItem.category!.publicId);
      if (catIdx == -1) return;

      final moved = sortedCats.removeAt(catIdx);

      // Calculate target index in category list from the flat tree drop index
      // Count how many category items appear before dropIdx in the flat tree
      int targetCatIdx = 0;
      for (int i = 0; i < dropIdx && i < items.length; i++) {
        if (items[i].isCategory && items[i].id != draggedItem.id) targetCatIdx++;
      }
      targetCatIdx = targetCatIdx.clamp(0, sortedCats.length);

      sortedCats.insert(targetCatIdx, moved);

      // Write new positions
      for (int i = 0; i < sortedCats.length; i++) {
        await (db.update(db.categories)..where((c) => c.id.equals(sortedCats[i].id)))
            .write(CategoriesCompanion(position: Value(i), updatedAt: Value(now)));
      }
    } else {
      // Reorder channels
      final ch = draggedItem.channel!;

      // Determine which category the channel is being dropped into
      // Walk backwards from dropIdx to find the nearest category header
      int? newCategoryId;
      for (int i = (dropIdx < items.length ? dropIdx : items.length) - 1; i >= 0; i--) {
        if (items[i].isCategory) {
          newCategoryId = items[i].category!.id;
          break;
        }
      }

      // Get all channels in the target category (or uncategorized), sorted
      final siblingsQuery = db.select(db.channels)
        ..where((c) => c.serverId.equals(widget.server.id) & c.parentChannelId.isNull());
      if (newCategoryId != null) {
        siblingsQuery.where((c) => c.categoryId.equals(newCategoryId!));
      } else {
        siblingsQuery.where((c) => c.categoryId.isNull());
      }
      final siblings = await (siblingsQuery..orderBy([(c) => OrderingTerm.asc(c.position)])).get();

      // Remove dragged channel from the list
      siblings.removeWhere((c) => c.id == ch.id);

      // Calculate target position within the siblings
      // Count non-category, non-dragged items before dropIdx that share the same category
      int targetPos = 0;
      for (int i = 0; i < dropIdx && i < items.length; i++) {
        final item = items[i];
        if (item.id == draggedItem.id) continue;
        if (!item.isCategory && item.channel != null && item.depth == 0) {
          final itemCatId = item.channel!.categoryId;
          if (itemCatId == newCategoryId) targetPos++;
        }
      }
      targetPos = targetPos.clamp(0, siblings.length);

      siblings.insert(targetPos, ch);

      // Update category assignment if it changed
      if (ch.categoryId != newCategoryId) {
        await (db.update(db.channels)..where((c) => c.id.equals(ch.id)))
            .write(ChannelsCompanion(categoryId: Value(newCategoryId), updatedAt: Value(now)));
      }

      // Write new positions for all siblings
      for (int i = 0; i < siblings.length; i++) {
        await (db.update(db.channels)..where((c) => c.id.equals(siblings[i].id)))
            .write(ChannelsCompanion(position: Value(i), updatedAt: Value(now)));
      }
    }

    // Debounced save to relays (800ms, matches Rails)
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: _kSaveDebounceMs), () {
      _publishStructure();
    });
  }

  Future<void> _publishStructure() async {
    final auth = ref.read(authServiceProvider);
    final serverPublish = ref.read(serverPublishServiceProvider);
    if (auth.privateKeyHex == null) return;
    await serverPublish.publishStructure(
      privateKeyHex: auth.privateKeyHex!,
      publicKeyHex: auth.publicKeyHex!,
      server: widget.server,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final items = _buildFlatTree();

    return Listener(
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      child: Stack(
        children: [
          GestureDetector(
            onSecondaryTapUp: (details) => _showSidebarContextMenu(details.globalPosition, details.localPosition, items),
            behavior: HitTestBehavior.translucent,
            child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final isDragged = _dragState == 'dragging' && _draggedItem?.id == item.id;

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Drop indicator line
                  if (_dragState == 'dragging' && _dropIndex == index)
                    Container(
                      height: 2,
                      margin: const EdgeInsets.symmetric(vertical: 1),
                      decoration: BoxDecoration(
                        color: c.accent,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  // Item
                  Opacity(
                    opacity: isDragged ? 0.3 : 1.0,
                    child: item.isCategory
                        ? _buildCategoryItem(item, c)
                        : _buildChannelItem(item, c),
                  ),
                ],
              );
            },
          )),
          // Drop line at end
          if (_dragState == 'dragging' && _dropIndex == items.length)
            Positioned(
              bottom: 0,
              left: 16,
              right: 16,
              child: Container(
                height: 2,
                decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(1)),
              ),
            ),
          // Ghost overlay — convert global _currentPos to local coordinates
          if (_dragState == 'dragging' && _draggedItem != null)
            Builder(builder: (ctx) {
              final renderBox = context.findRenderObject() as RenderBox?;
              final localPos = renderBox != null
                  ? renderBox.globalToLocal(_currentPos)
                  : _currentPos;
              return Positioned(
                left: 0, right: 0, top: 0, bottom: 0,
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _GhostPainter(
                      position: localPos,
                      label: _draggedItem!.isCategory
                          ? _draggedItem!.category!.name ?? ''
                          : _draggedItem!.channel!.name,
                      colors: c,
                    ),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  /// Right-click on sidebar blank space — "Create Channel" + "Create Category" with position context.
  /// Matches Rails channel_sidebar_controller.js _handleContextMenu().
  void _showSidebarContextMenu(Offset globalPos, Offset localPos, List<_TreeItem> items) {
    if (widget.onCreateChannel == null && widget.onCreateCategory == null) return;

    // Calculate insertion point from click position (matching Rails _getInsertionPoint)
    final scrollOffset = _scrollController.offset;
    final y = localPos.dy + scrollOffset;
    const itemHeight = 34.0;
    const catHeight = 36.0;
    double accumulatedY = 8; // top padding

    int? categoryId;
    int position = 0;
    int categoryPosition = 0;

    for (final item in items) {
      final h = item.isCategory ? catHeight : itemHeight;
      if (accumulatedY + h > y) break;
      accumulatedY += h;

      if (item.isCategory) {
        categoryId = item.category!.id;
        categoryPosition = (item.category!.position ?? 0) + 1;
        position = 0; // reset for channels within new category
      } else if (item.channel != null) {
        position = (item.channel!.position ?? 0) + 1;
        categoryId = item.channel!.categoryId;
      }
    }

    showStyledMenu(
      context: context,
      position: globalPos,
      items: [
        if (widget.onCreateChannel != null)
          CtxItem('Create Channel', Icons.add, () {
            final cat = categoryId != null
                ? widget.categories.cast<Category?>().firstWhere((c) => c!.id == categoryId, orElse: () => null)
                : null;
            widget.onCreateChannel!(cat, position: position);
          }),
        if (widget.onCreateCategory != null)
          CtxItem('Create Category', Icons.create_new_folder_outlined, () {
            widget.onCreateCategory!(position: categoryPosition);
          }),
      ],
    );
  }

  Widget _buildCategoryItem(_TreeItem item, InfernoColors c) {
    final cat = item.category!;
    final isCollapsed = widget.collapsedCategories.contains(cat.publicId);

    return Listener(
      onPointerDown: (e) => _onPointerDown(e, item),
      child: _CategoryHeaderWidget(
        name: cat.name ?? '',
        colors: c,
        isCollapsed: isCollapsed,
        onToggle: () => widget.onToggleCategory(cat.publicId),
        onEdit: widget.onEditCategory != null ? () => widget.onEditCategory!(cat) : null,
        onDelete: widget.onDeleteCategory != null ? () => widget.onDeleteCategory!(cat) : null,
        onCreateChannel: widget.onCreateChannel != null ? () => widget.onCreateChannel!(cat) : null,
        onCreateCategory: widget.onCreateCategory,
      ),
    );
  }

  Widget _buildChannelItem(_TreeItem item, InfernoColors c) {
    final ch = item.channel!;
    final isActive = ch.publicId == widget.activeChannelId;
    final isVoice = ch.channelType == 1;
    final isNested = item.depth > 0;
    final isAfk = widget.server.afkChannelId != null && ch.id == widget.server.afkChannelId;

    IconData icon;
    if (isAfk) {
      icon = Icons.nightlight_round;  // Moon for AFK
    } else if (isVoice) {
      icon = Icons.volume_up;  // Speaker for voice
    } else if (ch.encrypted) {
      icon = Icons.lock;
    } else {
      icon = Icons.tag;  // # for text
    }

    return Listener(
      onPointerDown: (e) => _onPointerDown(e, item),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ChannelItemWidget(
            channel: ch,
            serverId: widget.server.publicId,
            isActive: isActive,
            icon: icon,
            depth: item.depth,
            isVoice: isVoice,
            isAfk: isAfk,
            colors: c,
            onEdit: widget.onEditChannel != null ? () => widget.onEditChannel!(ch) : null,
            onDelete: widget.onDeleteChannel != null ? () => widget.onDeleteChannel!(ch) : null,
          ),
          // Voice channels show a "No one connected" placeholder or participants
          if (isVoice && !isNested)
            _VoiceParticipantsArea(channel: ch, colors: c),
        ],
      ),
    );
  }
}

/// Paints a semi-transparent ghost label following the cursor during drag.
/// Position is in global coordinates — paint relative to the canvas origin.
class _GhostPainter extends CustomPainter {
  final Offset position;
  final String label;
  final InfernoColors colors;

  _GhostPainter({required this.position, required this.label, required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = colors.gray800.withValues(alpha: 0.9)
      ..style = PaintingStyle.fill;

    // Position the ghost near the cursor, offset slightly right and centered vertically
    final ghostX = (position.dx + 12).clamp(0.0, size.width - 180);
    final ghostY = (position.dy - 16).clamp(0.0, size.height - 32);

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(ghostX, ghostY, 180, 32),
      const Radius.circular(6),
    );
    canvas.drawRRect(rect, paint);

    final borderPaint = Paint()
      ..color = colors.accent.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRRect(rect, borderPaint);

    final textSpan = TextSpan(
      text: label,
      style: TextStyle(color: colors.gray200, fontSize: 13, fontWeight: FontWeight.w500),
    );
    final textPainter = TextPainter(text: textSpan, textDirection: TextDirection.ltr)..layout(maxWidth: 160);
    textPainter.paint(canvas, Offset(ghostX + 10, ghostY + 8));
  }

  @override
  bool shouldRepaint(_GhostPainter old) => position != old.position || label != old.label;
}

/// Category header with collapse/expand
class _CategoryHeaderWidget extends StatefulWidget {
  final String name;
  final InfernoColors colors;
  final bool isCollapsed;
  final VoidCallback onToggle;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onCreateChannel;
  final void Function({int? position})? onCreateCategory;

  const _CategoryHeaderWidget({required this.name, required this.colors, required this.isCollapsed, required this.onToggle, this.onEdit, this.onDelete, this.onCreateChannel, this.onCreateCategory});

  @override
  State<_CategoryHeaderWidget> createState() => _CategoryHeaderWidgetState();
}

class _CategoryHeaderWidgetState extends State<_CategoryHeaderWidget> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onToggle,
        onSecondaryTapUp: (details) {
          if (widget.onEdit == null && widget.onDelete == null && widget.onCreateChannel == null && widget.onCreateCategory == null) return;
          showStyledMenu(
            context: context,
            position: details.globalPosition,
            items: [
              if (widget.onCreateChannel != null)
                CtxItem('Create Channel', Icons.add, widget.onCreateChannel!),
              if (widget.onCreateCategory != null)
                CtxItem('Create Category', Icons.create_new_folder_outlined, () => widget.onCreateCategory!()),
              if (widget.onEdit != null || widget.onDelete != null)
                CtxDivider(),
              if (widget.onEdit != null)
                CtxItem('Edit Category', Icons.edit_outlined, widget.onEdit!),
              if (widget.onDelete != null)
                CtxItem('Delete Category', Icons.delete_outline, widget.onDelete!, danger: true),
            ],
          );
        },
        child: Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 4, left: 4, right: 4),
          child: Row(
            children: [
              AnimatedRotation(
                turns: widget.isCollapsed ? -0.25 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(Icons.keyboard_arrow_down, color: widget.colors.gray500, size: 12),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  widget.name.toUpperCase(),
                  style: TextStyle(color: widget.colors.gray500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_hovering && widget.onCreateChannel != null)
                GestureDetector(
                  onTap: widget.onCreateChannel,
                  child: Icon(Icons.add, size: 14, color: widget.colors.gray500),
                ),
              if (_hovering && widget.onCreateChannel == null)
                Icon(Icons.add, size: 14, color: widget.colors.gray500),
            ],
          ),
        ),
      ),
    );
  }
}

/// Individual channel item in the sidebar
class _ChannelItemWidget extends ConsumerStatefulWidget {
  final Channel channel;
  final String serverId;
  final bool isActive;
  final IconData icon;
  final int depth;
  final bool isVoice;
  final bool isAfk;
  final InfernoColors colors;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _ChannelItemWidget({
    required this.channel,
    required this.serverId,
    required this.isActive,
    required this.icon,
    required this.depth,
    this.isVoice = false,
    this.isAfk = false,
    required this.colors,
    this.onEdit,
    this.onDelete,
  });

  @override
  ConsumerState<_ChannelItemWidget> createState() => _ChannelItemWidgetState();
}

class _ChannelItemWidgetState extends ConsumerState<_ChannelItemWidget> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final active = widget.isActive;
    final isNested = widget.depth > 0;

    // Reactive unread from provider (skip voice channels)
    final unreadAsync = widget.isVoice ? null : ref.watch(channelUnreadCountProvider(widget.channel.id));
    final hasUnread = !active && (unreadAsync?.valueOrNull ?? 0) > 0;

    // Build the channel row — matches Rails: solid left accent border + gradient fill
    final channelRow = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        gradient: active ? LinearGradient(
          colors: [c.accent.withValues(alpha: 0.12), c.accent.withValues(alpha: 0.03)],
          begin: Alignment.centerLeft, end: Alignment.centerRight,
        ) : (_hovering ? LinearGradient(
          colors: [c.accent.withValues(alpha: 0.06), Colors.transparent],
          begin: Alignment.centerLeft, end: Alignment.centerRight,
        ) : null),
        color: (!active && !_hovering) ? Colors.transparent : null,
        borderRadius: BorderRadius.circular(4),
        border: active ? Border(left: BorderSide(color: c.accent.withValues(alpha: 0.8), width: 2)) : null,
        boxShadow: active ? [
          BoxShadow(color: c.accent.withValues(alpha: 0.15), blurRadius: 6, offset: const Offset(2, 0)),
        ] : null,
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          // Unread pill on the left for non-active channels
          if (!active) Container(
            width: 3,
            height: hasUnread ? 8 : 0,
            decoration: BoxDecoration(
              color: hasUnread ? Colors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          SizedBox(width: active ? 5 : 8),
          Icon(widget.icon, size: 18, color: active ? c.gray200 : (hasUnread ? c.gray200 : c.gray500)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              widget.channel.name,
              style: TextStyle(
                color: active ? Colors.white : (hasUnread ? Colors.white : (_hovering ? c.gray200 : c.gray500)),
                fontSize: 14,
                fontWeight: (active || hasUnread) ? FontWeight.w600 : FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Typing indicators — show small avatar bubbles for users typing in this channel
          if (widget.channel.nostrGroupId != null && !widget.isVoice)
            _TypingAvatars(channelGroupId: widget.channel.nostrGroupId!, colors: c),
          // Chat button for voice channels (not AFK)
          if (widget.isVoice && !widget.isAfk && _hovering)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Tooltip(
                message: 'Open chat',
                child: Icon(Icons.chat_bubble_outline, size: 14, color: c.gray400),
              ),
            ),
        ],
      ),
    );

    // Wrap nested channels with L-connector aligned to parent icon
    Widget result;
    if (isNested) {
      result = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // L-shaped connector — vertical aligns with parent icon center
          SizedBox(
            width: 22,
            child: CustomPaint(
              size: const Size(22, 34),
              painter: _LConnectorPainter(color: c.accent.withValues(alpha: 0.3)),
            ),
          ),
          Expanded(child: channelRow),
        ],
      );
    } else {
      result = channelRow;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: () => context.go('/servers/${widget.serverId}/channels/${widget.channel.publicId}'),
        onSecondaryTapUp: (details) {
          showStyledMenu(
            context: context,
            position: details.globalPosition,
            items: [
              CtxItem('Mark as Read', Icons.done_all, () {
                final db = ref.read(databaseProvider);
                db.messagesDao.upsertChannelRead(widget.channel.id, 0);
              }),
              CtxItem('Copy Channel ID', Icons.copy, () {
                Clipboard.setData(ClipboardData(text: widget.channel.publicId));
              }),
              if (widget.onEdit != null || widget.onDelete != null)
                CtxDivider(),
              if (widget.onEdit != null)
                CtxItem('Edit Channel', Icons.edit_outlined, widget.onEdit!),
              if (widget.onDelete != null)
                CtxItem('Delete Channel', Icons.delete_outline, widget.onDelete!, danger: true),
            ],
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: result,
        ),
      ),
    );
  }
}

/// Shows participants connected to a voice channel in the sidebar
class _VoiceParticipantsArea extends ConsumerWidget {
  final Channel channel;
  final InfernoColors colors;
  const _VoiceParticipantsArea({required this.channel, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final livekit = ref.watch(livekitServiceProvider);
    ref.watch(livekitConnectionProvider);

    // Watch voice state stream so widget rebuilds on remote join/leave
    final dmService = ref.watch(dmServiceProvider);
    ref.watch(voiceStateChangeProvider);

    // Read remote voice states after stream subscription triggers rebuild
    final remoteStates = dmService.remoteVoiceStates[channel.publicId] ?? [];

    // Check if WE are in this channel's room
    final roomName = livekit.room?.name ?? '';
    final isOurRoom = livekit.isConnected && roomName.contains(channel.publicId);

    // No participants at all? Hide.
    if (!isOurRoom && remoteStates.isEmpty) return const SizedBox.shrink();

    // Merge LiveKit participants (when connected) with remote voice states
    final livekitParticipants = isOurRoom ? (livekit.participants) : <dynamic>[];

    // Build combined participant list
    final allParticipants = <_VoiceParticipantInfo>[];

    // From LiveKit (we're connected)
    for (final p in livekitParticipants) {
      final name = p.name?.isNotEmpty == true ? p.name : p.identity;
      String? avatarUrl;
      try {
        if (p.metadata != null && (p.metadata as String).isNotEmpty) {
          final meta = json.decode(p.metadata as String) as Map<String, dynamic>;
          avatarUrl = meta['avatar_url'] as String?;
        }
      } catch (_) {}
      bool isMuted;
      try { isMuted = !(p.isMicrophoneEnabled() as bool); } catch (_) { isMuted = false; }
      bool isSpeaking;
      try { isSpeaking = p.isSpeaking as bool; } catch (_) { isSpeaking = false; }
      allParticipants.add(_VoiceParticipantInfo(name: name ?? '?', avatarUrl: avatarUrl, isMuted: isMuted, isSpeaking: isSpeaking, userId: p.identity));
    }

    // From remote voice state sync (not in our LiveKit room)
    for (final rs in remoteStates) {
      final userId = rs['user_id'] as String? ?? '';
      // Don't duplicate if already in LiveKit participants
      if (allParticipants.any((p) => p.userId == userId)) continue;
      allParticipants.add(_VoiceParticipantInfo(
        name: rs['username'] as String? ?? userId,
        avatarUrl: rs['avatar_url'] as String?,
        isMuted: rs['self_mute'] == true,
        userId: userId,
      ));
    }

    if (allParticipants.isEmpty) return const SizedBox.shrink();

    return Padding(
          padding: const EdgeInsets.only(left: 28, bottom: 4),
          child: Column(
            children: allParticipants.map((p) {
              final hasAvatar = p.avatarUrl != null && p.avatarUrl!.startsWith('http');

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(children: [
                  // Avatar with speaking ring
                  Container(
                    width: 20, height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: p.isSpeaking ? [
                        BoxShadow(color: colors.accent.withValues(alpha: 0.6), blurRadius: 4, spreadRadius: 1),
                        BoxShadow(color: colors.accent, blurRadius: 0, spreadRadius: 1),
                      ] : null,
                    ),
                    child: hasAvatar
                        ? ClipOval(child: Image.network(p.avatarUrl!, width: 20, height: 20, fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Center(child: Text(p.name[0].toUpperCase(), style: TextStyle(color: colors.gray400, fontSize: 9, fontWeight: FontWeight.bold)))))
                        : Center(child: Text(p.name[0].toUpperCase(),
                            style: TextStyle(color: colors.gray400, fontSize: 9, fontWeight: FontWeight.bold))),
                  ),
                  const SizedBox(width: 6),
                  Expanded(child: Text(p.name, style: TextStyle(color: colors.gray200, fontSize: 12), overflow: TextOverflow.ellipsis)),
                  if (p.isMuted)
                    Padding(padding: const EdgeInsets.only(left: 2), child: Icon(Icons.mic_off, size: 12, color: colors.gray500)),
                ]),
              );
            }).toList(),
          ),
        );
  }

}

class _VoiceParticipantInfo {
  final String name;
  final String? avatarUrl;
  final bool isMuted;
  final bool isSpeaking;
  final String userId;
  _VoiceParticipantInfo({required this.name, this.avatarUrl, required this.isMuted, this.isSpeaking = false, required this.userId});
}

/// Paints an L-shaped connector line for nested voice channels
class _LConnectorPainter extends CustomPainter {
  final Color color;
  _LConnectorPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final midX = 19.0;
    final midY = size.height / 2 - 1;
    final r = 5.0;

    final path = Path();
    path.moveTo(midX, 0);
    path.lineTo(midX, midY - r);
    path.quadraticBezierTo(midX, midY, midX + r, midY);
    path.lineTo(size.width, midY);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_LConnectorPainter old) => color != old.color;
}

/// Shows small avatar bubbles for users currently typing in a channel.
/// Displayed in the channel sidebar next to the channel name.
class _TypingAvatars extends ConsumerWidget {
  final String channelGroupId;
  final InfernoColors colors;
  const _TypingAvatars({required this.channelGroupId, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typingAsync = ref.watch(typingUsersProvider(channelGroupId));
    return typingAsync.when(
      data: (users) {
        // Filter out own pubkey
        final auth = ref.read(authServiceProvider);
        final others = users.where((u) => u != auth.publicKeyHex).toList();
        if (others.isEmpty) return const SizedBox.shrink();

        final db = ref.read(databaseProvider);
        return FutureBuilder<List<_AvatarData>>(
          future: _resolveAvatars(db, others),
          builder: (context, snap) {
            final avatars = snap.data ?? [];
            if (avatars.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Stack overlapping avatars (max 3)
                  SizedBox(
                    width: avatars.length == 1 ? 18 : (avatars.length == 2 ? 28 : 36),
                    height: 18,
                    child: Stack(
                      children: [
                        for (int i = 0; i < avatars.length && i < 3; i++)
                          Positioned(
                            left: i * 10.0,
                            child: Container(
                              width: 18, height: 18,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: colors.gray800, width: 1.5),
                                color: colors.gray600,
                                image: avatars[i].avatarUrl != null
                                    ? DecorationImage(image: NetworkImage(avatars[i].avatarUrl!), fit: BoxFit.cover)
                                    : null,
                              ),
                              child: avatars[i].avatarUrl == null
                                  ? Center(child: Text(avatars[i].initial, style: TextStyle(color: colors.gray200, fontSize: 8, fontWeight: FontWeight.bold)))
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  static Future<List<_AvatarData>> _resolveAvatars(InfernoDatabase db, List<String> pubkeys) async {
    final result = <_AvatarData>[];
    for (final pk in pubkeys) {
      // Try contacts
      final contact = await (db.select(db.contacts)..where((c) => c.pubkey.equals(pk))).getSingleOrNull();
      if (contact != null) {
        final name = contact.displayName ?? contact.username ?? pk.substring(0, 2);
        final url = contact.avatarUrl;
        result.add(_AvatarData(initial: name[0].toUpperCase(), avatarUrl: url != null && url.startsWith('http') ? url : null));
        continue;
      }
      // Try remote members
      final members = await (db.select(db.remoteMembers)..where((m) => m.pubkey.equals(pk))..limit(1)).get();
      if (members.isNotEmpty) {
        final m = members.first;
        final name = m.displayName ?? m.username ?? pk.substring(0, 2);
        final url = m.avatarUrl;
        result.add(_AvatarData(initial: name[0].toUpperCase(), avatarUrl: url != null && url.startsWith('http') ? url : null));
        continue;
      }
      result.add(_AvatarData(initial: pk.substring(0, 1).toUpperCase(), avatarUrl: null));
    }
    return result;
  }
}

class _AvatarData {
  final String initial;
  final String? avatarUrl;
  _AvatarData({required this.initial, this.avatarUrl});
}
