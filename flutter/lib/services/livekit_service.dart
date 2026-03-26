import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'noise_processor.dart';

class LiveKitService {
  Room? _room;
  EventsListener<RoomEvent>? _listener;

  final _participantsController = StreamController<List<Participant>>.broadcast();
  Stream<List<Participant>> get participantsStream => _participantsController.stream;

  /// Stream that emits on every connection state change (connect/disconnect)
  final _connectionController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connectionController.stream;

  Room? get room => _room;
  bool get isConnected => _room?.connectionState == ConnectionState.connected;
  LocalParticipant? get localParticipant => _room?.localParticipant;

  /// Callback to publish voice state leave before disconnecting
  /// Set by the voice channel screen when connecting
  Future<void> Function()? onLeaveCallback;

  /// Connect to a LiveKit room with audio processing options
  Future<void> connect({
    required String url,
    required String token,
    bool autoSubscribe = true,
    bool noiseSuppression = true,
    bool echoCancellation = true,
    bool autoGainControl = true,
  }) async {
    _room = Room(
      roomOptions: RoomOptions(
        defaultAudioCaptureOptions: AudioCaptureOptions(
          noiseSuppression: noiseSuppression,
          echoCancellation: echoCancellation,
          autoGainControl: autoGainControl,
        ),
      ),
    );

    _listener = _room!.createListener();
    _listener!
      ..on<ParticipantConnectedEvent>((e) => _emitParticipants())
      ..on<ParticipantDisconnectedEvent>((e) => _emitParticipants())
      ..on<TrackPublishedEvent>((e) => _emitParticipants())
      ..on<TrackUnpublishedEvent>((e) => _emitParticipants())
      ..on<TrackMutedEvent>((e) => _emitParticipants())
      ..on<TrackUnmutedEvent>((e) => _emitParticipants())
      ..on<RoomDisconnectedEvent>((e) => _onDisconnected());

    await _room!.connect(url, token);

    // Initialize noise processor (DeepFilterNet → RNNoise → WebRTC fallback)
    if (noiseSuppression) {
      try {
        final processor = NoiseProcessor.instance;
        await processor.init(level: 'moderate');
        debugPrint('[LiveKit] Noise processor active: ${processor.activeProcessor}');
      } catch (e) {
        debugPrint('[LiveKit] Noise processor init failed: $e (using WebRTC built-in)');
      }
    }

    _emitParticipants();
    _connectionController.add(true);
  }

  void _onDisconnected() {
    _room = null;
    _listener?.dispose();
    _listener = null;
    _emitParticipants();
    _connectionController.add(false);
  }

  /// Disconnect from the room — publishes leave state if callback is set
  Future<void> disconnect() async {
    if (_room == null) return;

    // Publish leave state via Nostr before disconnecting
    if (onLeaveCallback != null) {
      try { await onLeaveCallback!(); } catch (_) {}
      onLeaveCallback = null;
    }

    _listener?.dispose();
    _listener = null;
    final room = _room!;
    _room = null;
    _deafened = false;

    try {
      await room.disconnect();
    } catch (_) {}

    _emitParticipants();
    _connectionController.add(false);
  }

  bool _deafened = false;
  bool get isDeafened => _deafened;
  bool get isMuted => !(_room?.localParticipant?.isMicrophoneEnabled() ?? true);

  /// Toggle mute — stops/starts publishing our audio track to the room
  Future<void> toggleMicrophone() async {
    if (_room == null) return;
    final enabled = _room!.localParticipant?.isMicrophoneEnabled() ?? false;
    await _room!.localParticipant?.setMicrophoneEnabled(!enabled);
    _emitParticipants();
    _connectionController.add(true); // trigger UI rebuild for mute state
  }

  /// Toggle deafen — stops/starts subscribing to all remote audio tracks
  Future<void> toggleDeafen() async {
    if (_room == null) return;
    _deafened = !_deafened;
    for (final participant in _room!.remoteParticipants.values) {
      for (final pub in participant.audioTrackPublications) {
        if (pub.subscribed) {
          pub.track?.mediaStreamTrack.enabled = !_deafened;
        }
      }
    }
    // Also mute ourselves when deafened (can't talk if you can't hear)
    if (_deafened) {
      await _room!.localParticipant?.setMicrophoneEnabled(false);
    }
    _emitParticipants();
    _connectionController.add(true);
  }

  /// Toggle camera
  Future<void> toggleCamera() async {
    if (_room == null) return;
    final enabled = _room!.localParticipant?.isCameraEnabled() ?? false;
    await _room!.localParticipant?.setCameraEnabled(!enabled);
    _emitParticipants();
  }

  /// Toggle screen share
  Future<void> toggleScreenShare() async {
    if (_room == null) return;
    final enabled = _room!.localParticipant?.isScreenShareEnabled() ?? false;
    await _room!.localParticipant?.setScreenShareEnabled(!enabled);
    _emitParticipants();
  }

  /// Set microphone enabled/disabled
  Future<void> setMicrophoneEnabled(bool enabled) async {
    await _room?.localParticipant?.setMicrophoneEnabled(enabled);
    _emitParticipants();
  }

  /// Get all participants (local + remote)
  List<Participant> get participants {
    if (_room == null) return [];
    return [
      if (_room!.localParticipant != null) _room!.localParticipant!,
      ..._room!.remoteParticipants.values,
    ];
  }

  void _emitParticipants() {
    _participantsController.add(participants);
  }

  void dispose() {
    disconnect();
    _participantsController.close();
    _connectionController.close();
  }
}
