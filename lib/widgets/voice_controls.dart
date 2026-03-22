import 'package:flutter/material.dart';

class VoiceControls extends StatefulWidget {
  final VoidCallback? onMuteToggle;
  final VoidCallback? onDeafenToggle;
  final VoidCallback? onVideoToggle;
  final VoidCallback? onScreenShareToggle;
  final VoidCallback? onDisconnect;

  const VoiceControls({
    super.key,
    this.onMuteToggle,
    this.onDeafenToggle,
    this.onVideoToggle,
    this.onScreenShareToggle,
    this.onDisconnect,
  });

  @override
  State<VoiceControls> createState() => _VoiceControlsState();
}

class _VoiceControlsState extends State<VoiceControls> {
  bool _muted = false;
  bool _deafened = false;
  bool _videoOn = false;
  bool _screenSharing = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF0F1629),
        border: Border(top: BorderSide(color: Color(0xFF2A3A5C))),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _ControlButton(
              icon: _muted ? Icons.mic_off : Icons.mic,
              label: _muted ? 'Unmute' : 'Mute',
              isActive: _muted,
              activeColor: const Color(0xFFFF4D4D),
              onPressed: () {
                setState(() => _muted = !_muted);
                widget.onMuteToggle?.call();
              },
            ),
            _ControlButton(
              icon: _deafened ? Icons.headset_off : Icons.headset,
              label: _deafened ? 'Undeafen' : 'Deafen',
              isActive: _deafened,
              activeColor: const Color(0xFFFF4D4D),
              onPressed: () {
                setState(() {
                  _deafened = !_deafened;
                  if (_deafened) _muted = true;
                });
                widget.onDeafenToggle?.call();
              },
            ),
            _ControlButton(
              icon: Icons.videocam,
              label: 'Video',
              isActive: _videoOn,
              activeColor: const Color(0xFF4CAF50),
              onPressed: () {
                setState(() => _videoOn = !_videoOn);
                widget.onVideoToggle?.call();
              },
            ),
            _ControlButton(
              icon: Icons.screen_share,
              label: 'Share',
              isActive: _screenSharing,
              activeColor: const Color(0xFF4CAF50),
              onPressed: () {
                setState(() => _screenSharing = !_screenSharing);
                widget.onScreenShareToggle?.call();
              },
            ),
            _ControlButton(
              icon: Icons.call_end,
              label: 'Leave',
              isActive: true,
              activeColor: const Color(0xFFFF4D4D),
              onPressed: widget.onDisconnect,
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final Color activeColor;
  final VoidCallback? onPressed;

  const _ControlButton({
    required this.icon,
    required this.label,
    this.isActive = false,
    this.activeColor = const Color(0xFFE85D3A),
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: onPressed,
          icon: Icon(icon),
          color: isActive ? activeColor : const Color(0xFFE0E0E0),
          style: IconButton.styleFrom(
            backgroundColor: isActive ? activeColor.withValues(alpha: 0.15) : const Color(0xFF2A3A5C),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: Color(0xFF8899A6), fontSize: 10)),
      ],
    );
  }
}
