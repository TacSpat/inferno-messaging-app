import 'package:flutter/material.dart';

class ReactionBar extends StatelessWidget {
  final Map<String, int> reactions;
  final Set<String> ownReactions;
  final void Function(String emoji) onToggle;
  final VoidCallback? onAddReaction;

  const ReactionBar({
    super.key,
    required this.reactions,
    this.ownReactions = const {},
    required this.onToggle,
    this.onAddReaction,
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
            ),
          if (onAddReaction != null)
            InkWell(
              onTap: onAddReaction,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E2A4A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF2A3A5C)),
                ),
                child: const Icon(Icons.add, size: 16, color: Color(0xFF8899A6)),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReactionChip extends StatelessWidget {
  final String emoji;
  final int count;
  final bool isOwn;
  final VoidCallback onTap;

  const _ReactionChip({
    required this.emoji,
    required this.count,
    required this.isOwn,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isOwn ? const Color(0xFF2A1A0A) : const Color(0xFF1E2A4A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isOwn ? const Color(0xFFE85D3A) : const Color(0xFF2A3A5C),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 4),
            Text(
              count.toString(),
              style: TextStyle(
                color: isOwn ? const Color(0xFFE85D3A) : const Color(0xFF8899A6),
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
