import 'package:flutter/material.dart';
import '../database/database.dart';

class ContactListItem extends StatelessWidget {
  final Contact contact;
  final bool showActions;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;
  final VoidCallback? onTap;

  const ContactListItem({
    super.key,
    required this.contact,
    this.showActions = false,
    this.onAccept,
    this.onDecline,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final name = contact.displayName ?? contact.username ?? '${contact.pubkey.substring(0, 12)}...';
    final statusText = _friendshipStatusText(contact.friendshipStatus);

    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: const Color(0xFF2A3A5C),
        backgroundImage: contact.avatarUrl != null ? NetworkImage(contact.avatarUrl!) : null,
        child: contact.avatarUrl == null
            ? Text(name[0].toUpperCase(), style: const TextStyle(color: Color(0xFFE0E0E0)))
            : null,
      ),
      title: Text(name, style: const TextStyle(color: Color(0xFFE0E0E0))),
      subtitle: Text(
        statusText,
        style: const TextStyle(color: Color(0xFF8899A6), fontSize: 13),
      ),
      trailing: showActions
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.check, color: Color(0xFF4CAF50)),
                  onPressed: onAccept,
                  tooltip: 'Accept',
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Color(0xFFFF4D4D)),
                  onPressed: onDecline,
                  tooltip: 'Decline',
                ),
              ],
            )
          : null,
    );
  }

  String _friendshipStatusText(int status) {
    switch (status) {
      case 0: return 'Not a friend';
      case 1: return 'Request sent';
      case 2: return 'Wants to be friends';
      case 3: return 'Friend';
      case 4: return 'Declined';
      case 5: return 'Blocked';
      default: return '';
    }
  }
}
