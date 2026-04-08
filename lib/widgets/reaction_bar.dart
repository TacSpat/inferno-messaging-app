import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme/all_themes.dart';

class ReactionBar extends StatelessWidget {
  final Map<String, int> reactions;
  final Set<String> ownReactions;
  final void Function(String emoji) onToggle;
  final VoidCallback? onAddReaction;
  final InfernoColors colors;
  /// Custom emoji map: shortcode (without colons) -> image URL
  final Map<String, String> customEmojis;

  const ReactionBar({
    super.key,
    required this.reactions,
    this.ownReactions = const {},
    required this.onToggle,
    this.onAddReaction,
    required this.colors,
    this.customEmojis = const {},
  });

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final entry in reactions.entries)
            _ReactionChip(
              emoji: entry.key,
              count: entry.value,
              isOwn: ownReactions.contains(entry.key),
              onTap: () => onToggle(entry.key),
              colors: colors,
              customEmojis: customEmojis,
            ),
          if (onAddReaction != null)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: onAddReaction,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: colors.gray900,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: colors.gray700),
                  ),
                  child: Icon(Icons.add, size: 16, color: colors.gray500),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReactionChip extends StatefulWidget {
  final String emoji;
  final int count;
  final bool isOwn;
  final VoidCallback onTap;
  final InfernoColors colors;
  final Map<String, String> customEmojis;

  const _ReactionChip({
    required this.emoji,
    required this.count,
    required this.isOwn,
    required this.onTap,
    required this.colors,
    this.customEmojis = const {},
  });

  @override
  State<_ReactionChip> createState() => _ReactionChipState();
}

class _ReactionChipState extends State<_ReactionChip> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final isOwn = widget.isOwn;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isOwn
                ? c.accent.withValues(alpha: 0.15)
                : (_hovering ? c.gray800 : c.gray900),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isOwn ? c.accent : (_hovering ? c.gray600 : c.gray700),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildEmoji(),
              const SizedBox(width: 4),
              Text(
                widget.count.toString(),
                style: TextStyle(
                  color: isOwn ? c.accent : c.gray400,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmoji() {
    final emoji = widget.emoji;
    // Custom server emoji: :shortcode: format
    if (emoji.length > 2 && emoji.startsWith(':') && emoji.endsWith(':')) {
      final shortcode = emoji.substring(1, emoji.length - 1);
      final url = widget.customEmojis[shortcode];
      if (url != null) {
        return CachedNetworkImage(
          imageUrl: url,
          width: 18,
          height: 18,
          fit: BoxFit.contain,
          errorWidget: (_, __, ___) => Text(emoji, style: const TextStyle(fontSize: 14, fontFamilyFallback: ['NotoColorEmoji'])),
        );
      }
      return Text(emoji, style: const TextStyle(fontSize: 14, fontFamilyFallback: ['NotoColorEmoji']));
    }
    return Text(emoji, style: const TextStyle(fontSize: 16, fontFamilyFallback: ['NotoColorEmoji']));
  }
}
