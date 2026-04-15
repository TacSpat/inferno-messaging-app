import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'noise_processor.dart';

class LiveKitService {
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  Timer? _tokenRefreshTimer;
  String? _connectedUrl;
  String? _currentToken;
  DateTime? _tokenExpiresAt;

  /// Set by the voice channel screen — called when the token needs renewal.
  /// Should request a new token from the voice provider and return it.
  Future<String?> Function()? onTokenRefreshNeeded;

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
    // Try DeepFilterNet first — if it's available we DON'T want WebRTC's
    // built-in noise suppression doing the same job, otherwise the signal is
    // processed twice and the WebRTC APM (AGC + AEC) leaves the audio session
    // in a quieter state that persists past the call.
    bool useWebRtcNs = noiseSuppression;
    if (noiseSuppression) {
      try {
        final processor = NoiseProcessor.instance;
        // Single fixed level — chosen for balanced voice clarity vs. noise removal.
        await processor.init(level: 'moderate');
        if (processor.activeProcessor == 'deepfilter') {
          useWebRtcNs = false;
          debugPrint('[LiveKit] Using DeepFilterNet — disabling WebRTC NS to avoid double processing');
        }
        debugPrint('[LiveKit] Noise processor active: ${processor.activeProcessor}');
      } catch (e) {
        debugPrint('[LiveKit] Noise processor init failed: $e (using WebRTC built-in)');
      }
    }

    _room = Room(
      roomOptions: RoomOptions(
        defaultAudioCaptureOptions: AudioCaptureOptions(
          noiseSuppression: useWebRtcNs,
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
    _connectedUrl = url;
    _currentToken = token;

    // Schedule token renewal before expiry
    _scheduleTokenRefresh(token);

    _emitParticipants();
    _connectionController.add(true);
  }

  /// Parse JWT expiry and schedule renewal 30 minutes before it expires.
  void _scheduleTokenRefresh(String token) {
    _tokenRefreshTimer?.cancel();
    try {
      final parts = token.split('.');
      if (parts.length != 3) return;
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final claims = json.decode(payload) as Map<String, dynamic>;
      final exp = claims['exp'] as int?;
      if (exp == null) return;

      _tokenExpiresAt = DateTime.fromMillisecondsSinceEpoch(exp * 1000);
      final renewAt = _tokenExpiresAt!.subtract(const Duration(minutes: 30));
      final delay = renewAt.difference(DateTime.now());

      if (delay.isNegative) {
        debugPrint('[LiveKit] Token already near expiry, renewing now');
        _renewToken();
        return;
      }

      debugPrint('[LiveKit] Token expires at $_tokenExpiresAt, renewal in ${delay.inMinutes}m');
      _tokenRefreshTimer = Timer(delay, _renewToken);
    } catch (e) {
      debugPrint('[LiveKit] Could not parse token expiry: $e');
    }
  }

  /// Whether the current token still has more than 30 minutes of life.
  bool get _tokenStillValid {
    if (_tokenExpiresAt == null) return false;
    return _tokenExpiresAt!.difference(DateTime.now()) > const Duration(minutes: 30);
  }

  /// Request a new token and reconnect only if the current token is near expiry.
  Future<void> _renewToken() async {
    if (_room == null || onTokenRefreshNeeded == null) return;

    // Don't renew if token still has plenty of time
    if (_tokenStillValid) {
      debugPrint('[LiveKit] Token still valid until $_tokenExpiresAt, skipping renewal');
      _scheduleTokenRefresh(_currentToken!);
      return;
    }

    debugPrint('[LiveKit] Token expiring, requesting renewal...');
    try {
      final newToken = await onTokenRefreshNeeded!();
      if (newToken == null || _room == null) {
        debugPrint('[LiveKit] Token renewal failed — no token returned');
        return;
      }

      // Reconnect with the new token
      final url = _connectedUrl ?? '';
      final roomOptions = _room!.roomOptions;
      final wasMuted = isMuted;
      _listener?.dispose();
      try { await _room!.disconnect(); } catch (_) {}

      _room = Room(roomOptions: roomOptions);
      _listener = _room!.createListener();
      _listener!
        ..on<ParticipantConnectedEvent>((e) => _emitParticipants())
        ..on<ParticipantDisconnectedEvent>((e) => _emitParticipants())
        ..on<TrackPublishedEvent>((e) => _emitParticipants())
        ..on<TrackUnpublishedEvent>((e) => _emitParticipants())
        ..on<TrackMutedEvent>((e) => _emitParticipants())
        ..on<TrackUnmutedEvent>((e) => _emitParticipants())
        ..on<RoomDisconnectedEvent>((e) => _onDisconnected());

      await _room!.connect(url, newToken);
      _currentToken = newToken;
      await _room!.localParticipant?.setMicrophoneEnabled(!wasMuted);

      _scheduleTokenRefresh(newToken);
      _emitParticipants();
      _connectionController.add(true);
      debugPrint('[LiveKit] Token renewed, reconnected');
    } catch (e) {
      debugPrint('[LiveKit] Token renewal failed: $e');
    }
  }

  void _onDisconnected() {
    _tokenRefreshTimer?.cancel();
    _room = null;
    _listener?.dispose();
    _listener = null;
    // Release native FFI state — leaving it loaded means PulseAudio / the
    // platform audio session keeps the WebRTC processing graph alive, which
    // can leave system audio levels lowered until the app exits.
    try { NoiseProcessor.instance.dispose(); } catch (_) {}
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

    _tokenRefreshTimer?.cancel();
    _listener?.dispose();
    _listener = null;
    final room = _room!;
    _room = null;
    _deafened = false;
    onTokenRefreshNeeded = null;

    try {
      await room.disconnect();
    } catch (_) {}

    // Release native FFI state — see _onDisconnected for rationale.
    try { NoiseProcessor.instance.dispose(); } catch (_) {}

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
