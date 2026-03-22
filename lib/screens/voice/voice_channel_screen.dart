import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/database.dart';
import '../../providers/database_provider.dart';
import '../../widgets/participant_tile.dart';
import '../../widgets/voice_controls.dart';

class VoiceChannelScreen extends ConsumerStatefulWidget {
  final String channelPublicId;
  final String serverPublicId;

  const VoiceChannelScreen({
    super.key,
    required this.channelPublicId,
    required this.serverPublicId,
  });

  @override
  ConsumerState<VoiceChannelScreen> createState() => _VoiceChannelScreenState();
}

class _VoiceChannelScreenState extends ConsumerState<VoiceChannelScreen> {
  Channel? _channel;
  bool _joined = false;

  @override
  void initState() {
    super.initState();
    _loadChannel();
  }

  Future<void> _loadChannel() async {
    final db = ref.read(databaseProvider);
    final ch = await db.serversDao.getChannelByPublicId(widget.channelPublicId);
    if (mounted) setState(() => _channel = ch);
  }

  @override
  Widget build(BuildContext context) {
    if (_channel == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        // Channel header
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: const BoxDecoration(
            color: Color(0xFF1A1A2E),
            border: Border(bottom: BorderSide(color: Color(0xFF2A3A5C))),
          ),
          child: Row(
            children: [
              const Icon(Icons.volume_up, size: 20, color: Color(0xFF8899A6)),
              const SizedBox(width: 8),
              Text(_channel!.name,
                style: const TextStyle(color: Color(0xFFE0E0E0), fontWeight: FontWeight.bold, fontSize: 16)),
              const Spacer(),
              if (!_joined)
                ElevatedButton.icon(
                  onPressed: () => setState(() => _joined = true),
                  icon: const Icon(Icons.call, size: 16),
                  label: const Text('Join Voice'),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4CAF50)),
                ),
            ],
          ),
        ),
        // Participant grid or empty state
        Expanded(
          child: _joined
              ? _buildParticipantGrid()
              : const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.headset, size: 64, color: Color(0xFF5C6B77)),
                      SizedBox(height: 16),
                      Text('Click "Join Voice" to connect', style: TextStyle(color: Color(0xFF8899A6))),
                    ],
                  ),
                ),
        ),
        // Voice controls (only when joined)
        if (_joined)
          VoiceControls(
            onMuteToggle: () {},
            onDeafenToggle: () {},
            onVideoToggle: () {},
            onScreenShareToggle: () {},
            onDisconnect: () => setState(() => _joined = false),
          ),
      ],
    );
  }

  Widget _buildParticipantGrid() {
    // Placeholder — in production this streams from LiveKitService.participantsStream
    return GridView.count(
      crossAxisCount: 3,
      padding: const EdgeInsets.all(16),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [
        ParticipantTile(name: 'You', isMuted: false, isSpeaking: true),
      ],
    );
  }
}
