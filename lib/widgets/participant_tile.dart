import 'package:flutter/material.dart';

class ParticipantTile extends StatelessWidget {
  final String name;
  final String? avatarUrl;
  final bool isMuted;
  final bool isDeafened;
  final bool isSpeaking;
  final bool isScreenSharing;
  final bool isVideoOn;

  const ParticipantTile({
    super.key,
    required this.name,
    this.avatarUrl,
    this.isMuted = false,
    this.isDeafened = false,
    this.isSpeaking = false,
    this.isScreenSharing = false,
    this.isVideoOn = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF16213E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSpeaking ? const Color(0xFF4CAF50) : const Color(0xFF2A3A5C),
          width: isSpeaking ? 2 : 1,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Avatar
          CircleAvatar(
            radius: 28,
            backgroundColor: const Color(0xFF2A3A5C),
            backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl!) : null,
            child: avatarUrl == null
                ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: const TextStyle(fontSize: 20, color: Color(0xFFE0E0E0)))
                : null,
          ),
          const SizedBox(height: 8),
          // Name
          Text(
            name,
            style: const TextStyle(color: Color(0xFFE0E0E0), fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          // Status icons
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isMuted)
                const Icon(Icons.mic_off, size: 14, color: Color(0xFFFF4D4D)),
              if (isDeafened)
                const Icon(Icons.headset_off, size: 14, color: Color(0xFFFF4D4D)),
              if (isScreenSharing)
                const Icon(Icons.screen_share, size: 14, color: Color(0xFF4CAF50)),
              if (isVideoOn)
                const Icon(Icons.videocam, size: 14, color: Color(0xFF4CAF50)),
            ],
          ),
        ],
      ),
    );
  }
}
