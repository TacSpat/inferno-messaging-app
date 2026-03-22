import 'dart:async';
import 'package:livekit_client/livekit_client.dart';

class LiveKitService {
  Room? _room;
  EventsListener<RoomEvent>? _listener;

  final _participantsController = StreamController<List<Participant>>.broadcast();
  Stream<List<Participant>> get participantsStream => _participantsController.stream;

  Room? get room => _room;
  bool get isConnected => _room?.connectionState == ConnectionState.connected;
  LocalParticipant? get localParticipant => _room?.localParticipant;

  /// Connect to a LiveKit room
  Future<void> connect({
    required String url,
    required String token,
    bool autoSubscribe = true,
  }) async {
    _room = Room();

    _listener = _room!.createListener();
    _listener!
      ..on<ParticipantConnectedEvent>((e) => _emitParticipants())
      ..on<ParticipantDisconnectedEvent>((e) => _emitParticipants())
      ..on<TrackPublishedEvent>((e) => _emitParticipants())
      ..on<TrackUnpublishedEvent>((e) => _emitParticipants())
      ..on<TrackMutedEvent>((e) => _emitParticipants())
      ..on<TrackUnmutedEvent>((e) => _emitParticipants());

    await _room!.connect(url, token);

    _emitParticipants();
  }

  /// Disconnect from the room
  Future<void> disconnect() async {
    _listener?.dispose();
    _listener = null;
    await _room?.disconnect();
    _room = null;
    _emitParticipants();
  }

  /// Toggle microphone mute
  Future<void> toggleMicrophone() async {
    if (_room == null) return;
    final enabled = _room!.localParticipant?.isMicrophoneEnabled() ?? false;
    await _room!.localParticipant?.setMicrophoneEnabled(!enabled);
  }

  /// Toggle camera
  Future<void> toggleCamera() async {
    if (_room == null) return;
    final enabled = _room!.localParticipant?.isCameraEnabled() ?? false;
    await _room!.localParticipant?.setCameraEnabled(!enabled);
  }

  /// Toggle screen share
  Future<void> toggleScreenShare() async {
    if (_room == null) return;
    final enabled = _room!.localParticipant?.isScreenShareEnabled() ?? false;
    await _room!.localParticipant?.setScreenShareEnabled(!enabled);
  }

  /// Set microphone enabled/disabled
  Future<void> setMicrophoneEnabled(bool enabled) async {
    await _room?.localParticipant?.setMicrophoneEnabled(enabled);
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
  }
}
