import 'package:flutter/material.dart';

class TypingIndicator extends StatefulWidget {
  final List<String> typingUsers;

  const TypingIndicator({super.key, required this.typingUsers});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.typingUsers.isEmpty) return const SizedBox.shrink();

    final text = _buildText();

    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // Animated dots
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
      return '${_shortName(users[0])} is typing';
    } else if (users.length == 2) {
      return '${_shortName(users[0])} and ${_shortName(users[1])} are typing';
    } else {
      return 'Several people are typing';
    }
  }

  String _shortName(String pubkey) => '${pubkey.substring(0, 8)}...';
}
