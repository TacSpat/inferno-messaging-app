import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';

class TypingIndicator extends ConsumerStatefulWidget {
  final List<String> typingUsers;

  const TypingIndicator({super.key, required this.typingUsers});

  @override
  ConsumerState<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends ConsumerState<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final Map<String, String> _nameCache = {};

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
  }

  InfernoDatabase? _db;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _db = ref.read(databaseProvider);
  }

  Future<void> _resolveName(String pubkey) async {
    final db = _db;
    if (db == null) return;

    // Try contacts first
    final contact = await (db.select(db.contacts)
          ..where((c) => c.pubkey.equals(pubkey)))
        .getSingleOrNull();
    if (contact != null) {
      final name = contact.displayName ?? contact.username;
      if (name != null && name.isNotEmpty) {
        if (mounted) setState(() => _nameCache[pubkey] = name);
        return;
      }
    }

    // Try remote members
    final members = await (db.select(db.remoteMembers)
          ..where((m) => m.pubkey.equals(pubkey))
          ..limit(1))
        .get();
    if (members.isNotEmpty) {
      final m = members.first;
      final name = m.displayName ?? m.username;
      if (name != null && name.isNotEmpty) {
        if (mounted) setState(() => _nameCache[pubkey] = name);
        return;
      }
    }

    // Fallback
    if (mounted) setState(() => _nameCache[pubkey] = '${pubkey.substring(0, 8)}...');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.typingUsers.isEmpty) return const SizedBox.shrink();

    // Resolve names on first build
    for (final pubkey in widget.typingUsers) {
      if (!_nameCache.containsKey(pubkey)) {
        _resolveName(pubkey);
      }
    }

    final text = _buildText();

    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(3, (i) {
                  final delay = i * 0.2;
                  final value = (_controller.value + delay) % 1.0;
                  final opacity = value < 0.5 ? value * 2 : (1 - value) * 2;
                  return Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Opacity(
                      opacity: opacity.clamp(0.3, 1.0),
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: Color(0xFF8899A6),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  );
                }),
              );
            },
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(color: Color(0xFF8899A6), fontSize: 12),
          ),
        ],
      ),
    );
  }

  String _buildText() {
    final users = widget.typingUsers;
    if (users.length == 1) {
      return '${_nameFor(users[0])} is typing';
    } else if (users.length == 2) {
      return '${_nameFor(users[0])} and ${_nameFor(users[1])} are typing';
    } else {
      return 'Several people are typing';
    }
  }

  String _nameFor(String pubkey) => _nameCache[pubkey] ?? '${pubkey.substring(0, 8)}...';
}
