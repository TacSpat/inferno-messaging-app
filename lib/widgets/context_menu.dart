import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/all_themes.dart';
import '../theme/theme_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Styled context menu matching Rails UI — dark card, subtle border,
/// hover highlights, scale+opacity pop animation.
///
/// Usage:
/// ```dart
/// showStyledMenu(
///   context: context,
///   position: details.globalPosition,
///   items: [
///     CtxItem('Profile', Icons.person_outline, () => ...),
///     CtxItem('Mention', Icons.alternate_email, () => ...),
///     CtxDivider(),
///     CtxItem('Kick', Icons.logout, () => ..., danger: true),
///   ],
/// );
/// ```
Future<void> showStyledMenu({
  required BuildContext context,
  required Offset position,
  required List<CtxEntry> items,
}) async {
  final c = ProviderScope.containerOf(context).read(infernoColorsProvider);
  // Always use the root overlay so coordinates are in window-global space
  final overlay = Overlay.of(context, rootOverlay: true);
  late OverlayEntry entry;

  entry = OverlayEntry(builder: (ctx) => _StyledMenuOverlay(
    position: position,
    items: items,
    colors: c,
    onDismiss: () => entry.remove(),
  ));

  overlay.insert(entry);
}

// ── Data types ──

sealed class CtxEntry {}

class CtxItem extends CtxEntry {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final bool danger;
  final List<CtxEntry>? submenu;
  CtxItem(this.label, this.icon, this.onTap, {this.danger = false, this.submenu});
}

class CtxDivider extends CtxEntry {}

// ── Overlay widget ──

class _StyledMenuOverlay extends StatefulWidget {
  final Offset position;
  final List<CtxEntry> items;
  final InfernoColors colors;
  final VoidCallback onDismiss;
  const _StyledMenuOverlay({required this.position, required this.items, required this.colors, required this.onDismiss});
  @override
  State<_StyledMenuOverlay> createState() => _StyledMenuOverlayState();
}

class _StyledMenuOverlayState extends State<_StyledMenuOverlay> with SingleTickerProviderStateMixin {
  late AnimationController _anim;
  late Animation<double> _scale;
  late Animation<double> _opacity;
  int? _expandedSubmenu;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
    _scale = Tween(begin: 0.92, end: 1.0).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutBack));
    _opacity = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut));
    _anim.forward();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    await _anim.reverse();
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final screen = MediaQuery.of(context).size;

    // Position: prefer right+below the click, but clamp to screen
    const menuWidth = 200.0;
    const maxHeight = 400.0;
    double left = widget.position.dx;
    double top = widget.position.dy;
    if (left + menuWidth > screen.width - 8) left = screen.width - menuWidth - 8;
    if (left < 8) left = 8;
    if (top + maxHeight > screen.height - 8) top = screen.height - maxHeight - 8;
    if (top < 8) top = 8;

    return Stack(children: [
      // Dismiss background
      Positioned.fill(child: GestureDetector(
        onTap: _dismiss,
        onSecondaryTap: _dismiss,
        child: Container(color: Colors.transparent),
      )),
      // Menu card
      Positioned(
        left: left, top: top,
        child: AnimatedBuilder(
          animation: _anim,
          builder: (ctx, child) => Opacity(
            opacity: _opacity.value,
            child: Transform.scale(scale: _scale.value, alignment: Alignment.topLeft, child: child),
          ),
          child: Container(
            width: menuWidth,
            constraints: const BoxConstraints(maxHeight: maxHeight),
            decoration: BoxDecoration(
              color: c.gray900,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.gray700.withValues(alpha: 0.6)),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 16, offset: const Offset(0, 4)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: DefaultTextStyle(
                style: TextStyle(decoration: TextDecoration.none, fontFamily: 'Roboto', fontSize: 13, color: c.gray200),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    for (int i = 0; i < widget.items.length; i++)
                      _buildEntry(widget.items[i], c, i),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _buildEntry(CtxEntry entry, InfernoColors c, int index) {
    if (entry is CtxDivider) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Container(height: 1, color: c.gray700.withValues(alpha: 0.5)),
      );
    }
    if (entry is CtxItem) {
      return _CtxItemWidget(
        item: entry,
        colors: c,
        expanded: _expandedSubmenu == index,
        onTap: () {
          if (entry.submenu != null) {
            setState(() => _expandedSubmenu = _expandedSubmenu == index ? null : index);
          } else {
            _dismiss();
            entry.onTap();
          }
        },
      );
    }
    return const SizedBox.shrink();
  }
}

class _CtxItemWidget extends StatefulWidget {
  final CtxItem item;
  final InfernoColors colors;
  final bool expanded;
  final VoidCallback onTap;
  const _CtxItemWidget({required this.item, required this.colors, required this.expanded, required this.onTap});
  @override
  State<_CtxItemWidget> createState() => _CtxItemWidgetState();
}

class _CtxItemWidgetState extends State<_CtxItemWidget> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final item = widget.item;
    final textColor = item.danger ? c.accent : (_hovering ? Colors.white : c.gray200);
    final bgColor = _hovering
        ? (item.danger ? c.accent.withValues(alpha: 0.15) : c.gray700.withValues(alpha: 0.5))
        : Colors.transparent;

    return Column(mainAxisSize: MainAxisSize.min, children: [
      MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(children: [
              if (item.icon != null) ...[
                Icon(item.icon, size: 16, color: textColor.withValues(alpha: 0.7)),
                const SizedBox(width: 8),
              ],
              Expanded(child: Text(item.label, style: TextStyle(color: textColor, fontSize: 13, fontWeight: FontWeight.w500))),
              if (item.submenu != null)
                Icon(widget.expanded ? Icons.expand_less : Icons.chevron_right, size: 14, color: c.gray500),
            ]),
          ),
        ),
      ),
      // Inline submenu (expands below, like Rails roles submenu)
      if (widget.expanded && item.submenu != null)
        Container(
          margin: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          decoration: BoxDecoration(
            color: c.gray800,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c.gray700.withValues(alpha: 0.4)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final sub in item.submenu!)
              if (sub is CtxItem)
                _SubmenuItem(item: sub, colors: c),
          ]),
        ),
    ]);
  }
}

class _SubmenuItem extends StatefulWidget {
  final CtxItem item;
  final InfernoColors colors;
  const _SubmenuItem({required this.item, required this.colors});
  @override
  State<_SubmenuItem> createState() => _SubmenuItemState();
}

class _SubmenuItemState extends State<_SubmenuItem> {
  bool _hovering = false;
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.item.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: _hovering ? c.gray700.withValues(alpha: 0.5) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(children: [
            if (widget.item.icon != null) ...[
              Icon(widget.item.icon, size: 14, color: c.gray400),
              const SizedBox(width: 6),
            ],
            Expanded(child: Text(widget.item.label, style: TextStyle(color: c.gray200, fontSize: 12))),
          ]),
        ),
      ),
    );
  }
}
