import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../database/database.dart';
import '../theme/theme_provider.dart';

class MessageBubble extends ConsumerWidget {
  final Message message;
  final bool isOwn;

  const MessageBubble({super.key, required this.message, required this.isOwn});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(infernoColorsProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Align(
        alignment: isOwn ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.65),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isOwn ? c.accent : c.gray600,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: isOwn ? const Radius.circular(16) : const Radius.circular(4),
              bottomRight: isOwn ? const Radius.circular(4) : const Radius.circular(16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message.content != null && message.content!.isNotEmpty)
                Text(
                  message.content!,
                  style: TextStyle(
                    color: isOwn ? Colors.white : c.gray200,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                _formatTime(message.createdAt),
                style: TextStyle(
                  color: isOwn ? Colors.white70 : c.gray500,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    final now = DateTime.now();
    if (now.difference(local).inDays > 0) {
      return DateFormat('MMM d, h:mm a').format(local);
    }
    return DateFormat('h:mm a').format(local);
  }
}
