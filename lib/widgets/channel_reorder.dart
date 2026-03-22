import 'dart:async';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/servers_provider.dart';
import '../theme/all_themes.dart';

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

  const ChannelReorderList({
    super.key,
    required this.server,
    this.activeChannelId,
    required this.channels,
    required this.categories,
    required this.colors,
    required this.collapsedCategories,
    required this.onToggleCategory,
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

    // Find current index of dragged item
    final currentIdx = items.indexWhere((i) => i.id == draggedItem.id);
    if (currentIdx == -1 || currentIdx == dropIdx) return;

    // Determine what the new position should be
    final db = ref.read(databaseProvider);
    final now = DateTime.now();

    if (draggedItem.isCategory) {
      // Reorder categories
      final sortedCats = [...widget.categories]..sort((a, b) => (a.position ?? 0).compareTo(b.position ?? 0));
      final catIdx = sortedCats.indexWhere((c) => c.publicId == draggedItem.category!.publicId);
      if (catIdx == -1) return;

      // Simple position update
      for (int i = 0; i < sortedCats.length; i++) {
        await (db.update(db.categories)..where((c) => c.id.equals(sortedCats[i].id)))
            .write(CategoriesCompanion(position: Value(i), updatedAt: Value(now)));
      }
    } else {
      // Reorder channels — update position based on new visual order
      final allChannels = widget.channels.where((ch) => ch.parentChannelId == null).toList()
        ..sort((a, b) => (a.position ?? 0).compareTo(b.position ?? 0));

      for (int i = 0; i < allChannels.length; i++) {
        await (db.update(db.channels)..where((c) => c.id.equals(allChannels[i].id)))
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
          ListView.builder(
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
          ),
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
          // Ghost overlay
          if (_dragState == 'dragging' && _draggedItem != null)
            Positioned(
              left: 0, right: 0, top: 0, bottom: 0,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _GhostPainter(
                    position: _currentPos,
                    label: _draggedItem!.isCategory
                        ? _draggedItem!.category!.name ?? ''
                        : _draggedItem!.channel!.name,
                    colors: c,
                  ),
                ),
              ),
            ),
        ],
      ),
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
      icon = Icons.nightlight_round;
    } else if (isNested && isVoice) {
      icon = Icons.phone;
    } else if (isVoice) {
      icon = Icons.cell_tower;
    } else if (ch.encrypted) {
      icon = Icons.lock;
    } else {
      icon = Icons.tag;
    }

    return Listener(
      onPointerDown: (e) => _onPointerDown(e, item),
      child: _ChannelItemWidget(
        channel: ch,
        serverId: widget.server.publicId,
        isActive: isActive,
        icon: icon,
        depth: item.depth,
        colors: c,
      ),
    );
  }
}

/// Paints a semi-transparent ghost label following the cursor during drag
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

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(position.dx - size.width / 2 + 8, position.dy - 16, 180, 32),
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
    textPainter.paint(canvas, Offset(position.dx - size.width / 2 + 18, position.dy - 8));
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

  const _CategoryHeaderWidget({required this.name, required this.colors, required this.isCollapsed, required this.onToggle});

  @override
  State<_CategoryHeaderWidget> createState() => _CategoryHeaderWidgetState();
}

class _CategoryHeaderWidgetState extends State<_CategoryHeaderWidget> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onToggle,
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
              if (_hovering)
                Icon(Icons.add, size: 14, color: widget.colors.gray500),
            ],
          ),
        ),
      ),
    );
  }
}

/// Individual channel item in the sidebar
class _ChannelItemWidget extends StatefulWidget {
  final Channel channel;
  final String serverId;
  final bool isActive;
  final IconData icon;
  final int depth;
  final InfernoColors colors;

  const _ChannelItemWidget({
    required this.channel,
    required this.serverId,
    required this.isActive,
    required this.icon,
    required this.depth,
    required this.colors,
  });

  @override
  State<_ChannelItemWidget> createState() => _ChannelItemWidgetState();
}

class _ChannelItemWidgetState extends State<_ChannelItemWidget> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final active = widget.isActive;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: () => context.go('/servers/${widget.serverId}/channels/${widget.channel.publicId}'),
        child: Container(
          margin: EdgeInsets.only(left: widget.depth * 12.0, top: 1, bottom: 1),
          decoration: BoxDecoration(
            color: active ? c.gray600 : (_hovering ? c.gray700 : Colors.transparent),
            borderRadius: BorderRadius.circular(4),
          ),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 28,
                decoration: BoxDecoration(
                  color: active ? c.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              SizedBox(width: active ? 5 : 8),
              Icon(widget.icon, size: 18, color: active ? c.gray200 : c.gray500),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.channel.name,
                  style: TextStyle(
                    color: active ? Colors.white : (_hovering ? c.gray200 : c.gray500),
                    fontSize: 14,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
