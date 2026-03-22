import 'package:flutter/material.dart';
import '../services/presence_service.dart';

class PresenceDot extends StatelessWidget {
  final OnlineState state;
  final double size;

  const PresenceDot({
    super.key,
    required this.state,
    this.size = 10,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _colorForState(state),
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFF1A1A2E), width: 2),
      ),
    );
  }

  Color _colorForState(OnlineState state) {
    switch (state) {
      case OnlineState.online: return const Color(0xFF43B581);
      case OnlineState.idle: return const Color(0xFFFAA61A);
      case OnlineState.dnd: return const Color(0xFFF04747);
      case OnlineState.invisible:
      case OnlineState.offline: return const Color(0xFF747F8D);
    }
  }
}
