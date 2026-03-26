import 'package:flutter/material.dart';
import '../theme/all_themes.dart';

/// Banner shown at the top of a DM conversation when the message is from a non-friend.
/// Matches Rails: message_request_for?(user) — shows Accept/Decline buttons.
class DmRequestBanner extends StatelessWidget {
  final String senderName;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const DmRequestBanner({
    super.key,
    required this.senderName,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<InfernoColors>()!;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: c.gray800,
        border: Border(bottom: BorderSide(color: c.gray700)),
      ),
      child: Row(
        children: [
          Icon(Icons.mark_email_unread_outlined, size: 20, color: c.idle),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Message Request', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('$senderName wants to send you a message.',
                  style: TextStyle(color: c.gray400, fontSize: 13)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _BannerButton(label: 'Decline', colors: c, danger: true, onTap: onDecline),
          const SizedBox(width: 8),
          _BannerButton(label: 'Accept', colors: c, onTap: onAccept),
        ],
      ),
    );
  }
}

class _BannerButton extends StatefulWidget {
  final String label;
  final InfernoColors colors;
  final bool danger;
  final VoidCallback onTap;
  const _BannerButton({required this.label, required this.colors, this.danger = false, required this.onTap});
  @override
  State<_BannerButton> createState() => _BannerButtonState();
}

class _BannerButtonState extends State<_BannerButton> {
  bool _hovering = false;
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: widget.danger
                ? (_hovering ? c.accent.withValues(alpha: 0.3) : Colors.transparent)
                : (_hovering ? c.accent : c.accent.withValues(alpha: 0.8)),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: widget.danger ? c.gray600 : c.accent),
          ),
          child: Text(widget.label,
            style: TextStyle(
              color: widget.danger ? c.gray200 : Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            )),
        ),
      ),
    );
  }
}
