import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:livekit_client/livekit_client.dart' show Hardware, MediaDevice;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:record/record.dart';
import '../../services/noise_processor.dart';
import '../../theme/all_themes.dart';
import '../../theme/theme_provider.dart';

class VoiceVideoScreen extends ConsumerStatefulWidget {
  const VoiceVideoScreen({super.key});

  @override
  ConsumerState<VoiceVideoScreen> createState() => _VoiceVideoScreenState();
}

class _VoiceVideoScreenState extends ConsumerState<VoiceVideoScreen> {
  // Audio processing
  bool _noiseSuppression = true;
  bool _echoCancellation = true;
  bool _autoGainControl = true;

  // Input
  double _inputSensitivity = -50;
  bool _sensitivityAuto = true;
  String _inputMode = 'voice_activity';

  // Output
  double _outputVolume = 100;

  // Audio devices
  List<MediaDevice> _audioInputs = [];
  List<MediaDevice> _audioOutputs = [];
  List<MediaDevice> _videoInputs = [];
  String? _selectedInputId;
  String? _selectedOutputId;
  String? _selectedVideoId;
  StreamSubscription<List<MediaDevice>>? _deviceSub;

  // Single shared PCM stream for level meter + loopback. Only ONE capture
  // source so PulseAudio doesn't fight over the device.
  AudioRecorder? _sharedRecorder;
  Stream<Uint8List>? _sharedPcmStream;
  double _micLevel = 0.0;
  double _rawTarget = 0.0;
  Timer? _levelTimer;

  // LiveKit
  final _livekitUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _apiSecretController = TextEditingController();
  String? _livekitStatus;

  static const _storage = FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadDevices();
    // Re-enumerate when devices are plugged/unplugged.
    _deviceSub = Hardware.instance.onDeviceChange.stream.listen((_) => _loadDevices());
  }

  rtc.MediaStream? _probeStream;
  StreamSubscription<Uint8List>? _pcmSub;

  Future<void> _loadDevices() async {
    try {
      // Probe stream unlocks device enumeration on Linux (getUserMedia must
      // be called before enumerateDevices returns labels).
      _probeStream ??= await rtc.navigator.mediaDevices.getUserMedia({'audio': true});

      final inputs = await Hardware.instance.audioInputs();
      final outputs = await Hardware.instance.audioOutputs();
      final videos = await Hardware.instance.videoInputs();
      if (!mounted) return;
      setState(() {
        _audioInputs = inputs;
        _audioOutputs = outputs;
        _videoInputs = videos;
        _selectedInputId ??= Hardware.instance.selectedAudioInput?.deviceId;
        _selectedOutputId ??= Hardware.instance.selectedAudioOutput?.deviceId;
        _selectedVideoId ??= Hardware.instance.selectedVideoInput?.deviceId;
      });
    } catch (e) {
      debugPrint('[VoiceVideo] Device enumeration failed: $e');
    }

    // Start a single shared PCM capture for both level meter + loopback.
    await _startSharedCapture();
  }

  Future<void> _startSharedCapture() async {
    _pcmSub?.cancel();
    await _sharedRecorder?.stop();
    _sharedRecorder?.dispose();
    _levelTimer?.cancel();

    try {
      _sharedRecorder = AudioRecorder();
      if (!await _sharedRecorder!.hasPermission()) return;
      final stream = await _sharedRecorder!.startStream(
        const RecordConfig(encoder: AudioEncoder.pcm16bits, numChannels: 1, sampleRate: 48000),
      );
      _sharedPcmStream = stream.asBroadcastStream();
      // Feed level meter from the shared stream.
      _pcmSub = _sharedPcmStream!.listen((chunk) {
        if (chunk.length < 2) return;
        final samples = chunk.buffer.asInt16List(chunk.offsetInBytes, chunk.length ~/ 2);
        double sumSq = 0;
        for (final s in samples) { sumSq += s * s; }
        final rms = math.sqrt(sumSq / samples.length) / 32768.0;
        final db = rms > 0 ? 20 * math.log(rms) / math.ln10 : -100.0;
        _rawTarget = ((db + 50) / 45).clamp(0.0, 1.0);
      });
      _levelTimer = Timer.periodic(const Duration(milliseconds: 66), (_) {
        if (!mounted) return;
        final target = _rawTarget;
        final next = target > _micLevel ? target : _micLevel * 0.8 + target * 0.2;
        if ((next - _micLevel).abs() > 0.005) {
          setState(() => _micLevel = next);
        }
      });
    } catch (e) {
      debugPrint('[VoiceVideo] Shared capture failed: $e');
    }
  }

  Future<void> _selectAudioInput(String? deviceId) async {
    if (deviceId == null) {
      await _storage.delete(key: 'voice_input_device');
      setState(() => _selectedInputId = null);
      return;
    }
    final device = _audioInputs.firstWhere((d) => d.deviceId == deviceId, orElse: () => _audioInputs.first);
    await Hardware.instance.selectAudioInput(device);
    await _storage.write(key: 'voice_input_device', value: deviceId);
    setState(() => _selectedInputId = deviceId);
  }

  Future<void> _selectAudioOutput(String? deviceId) async {
    if (deviceId == null) {
      await _storage.delete(key: 'voice_output_device');
      setState(() => _selectedOutputId = null);
      return;
    }
    final device = _audioOutputs.firstWhere((d) => d.deviceId == deviceId, orElse: () => _audioOutputs.first);
    await Hardware.instance.selectAudioOutput(device);
    await _storage.write(key: 'voice_output_device', value: deviceId);
    setState(() => _selectedOutputId = deviceId);
  }

  Future<void> _loadSettings() async {
    // Audio processing
    _noiseSuppression = (await _storage.read(key: 'voice_noise_suppression')) != 'false';
    _echoCancellation = (await _storage.read(key: 'voice_echo_cancellation')) != 'false';
    _autoGainControl = (await _storage.read(key: 'voice_auto_gain_control')) != 'false';
    _inputMode = (await _storage.read(key: 'voice_input_mode')) ?? 'voice_activity';
    _sensitivityAuto = (await _storage.read(key: 'voice_sensitivity_auto')) != 'false';
    _selectedInputId = await _storage.read(key: 'voice_input_device');
    _selectedOutputId = await _storage.read(key: 'voice_output_device');
    final savedSens = await _storage.read(key: 'voice_input_sensitivity');
    if (savedSens != null) _inputSensitivity = double.tryParse(savedSens) ?? -50;
    final savedVol = await _storage.read(key: 'voice_output_volume');
    if (savedVol != null) _outputVolume = double.tryParse(savedVol) ?? 100;

    // LiveKit
    _livekitUrlController.text = await _storage.read(key: 'livekit_url') ?? '';
    _apiKeyController.text = await _storage.read(key: 'livekit_api_key') ?? '';
    final hasSecret = await _storage.read(key: 'livekit_api_secret');
    if (hasSecret != null) _livekitStatus = 'Configured';

    if (mounted) setState(() {});
  }



  @override
  void dispose() {
    _deviceSub?.cancel();
    _pcmSub?.cancel();
    _levelTimer?.cancel();
    _sharedRecorder?.stop();
    _sharedRecorder?.dispose();
    _probeStream?.dispose();
    _livekitUrlController.dispose();
    _apiKeyController.dispose();
    _apiSecretController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Voice & Video', style: TextStyle(color: c.gray50, fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 24),

        // ═══ Input Device ═══
        _label('INPUT DEVICE', c),
        const SizedBox(height: 8),
        _deviceDropdown(
          devices: _audioInputs,
          selectedId: _selectedInputId,
          placeholder: 'Microphone',
          colors: c,
          onChanged: _selectAudioInput,
        ),
        const SizedBox(height: 12),

        // Live mic test — loopback audio so you hear yourself through speakers.
        _MicLoopback(
          pcmStream: _sharedPcmStream,
          colors: c,
          noiseSuppression: _noiseSuppression,
          echoCancellation: _echoCancellation,
          autoGainControl: _autoGainControl,
        ),
        const SizedBox(height: 12),

        // Combined mic level + sensitivity bar.
        _label('INPUT SENSITIVITY', c),
        const SizedBox(height: 4),
        Row(children: [
          Text(_sensitivityAuto ? 'Automatic' : 'Manual', style: TextStyle(color: c.gray400, fontSize: 12)),
          const SizedBox(width: 8),
          Switch(value: _sensitivityAuto, onChanged: (v) {
            setState(() => _sensitivityAuto = v);
            _storage.write(key: 'voice_sensitivity_auto', value: v.toString());
          }, activeColor: c.accent),
        ]),
        const SizedBox(height: 8),
        _MicLevelMeter(
          level: _micLevel,
          active: _sharedRecorder != null,
          colors: c,
          showThreshold: !_sensitivityAuto,
          threshold: ((_inputSensitivity + 50) / 45).clamp(0.0, 1.0),
          onThresholdChanged: (t) {
            final db = (t * 45 - 50).clamp(-100.0, 0.0);
            setState(() => _inputSensitivity = db);
            _storage.write(key: 'voice_input_sensitivity', value: db.toString());
          },
        ),

        const SizedBox(height: 24),
        Container(height: 1, color: c.gray700),
        const SizedBox(height: 24),

        // ═══ Output Device ═══
        _label('OUTPUT DEVICE', c),
        const SizedBox(height: 8),
        _deviceDropdown(
          devices: _audioOutputs,
          selectedId: _selectedOutputId,
          placeholder: 'Speaker / Headphones',
          colors: c,
          onChanged: _selectAudioOutput,
        ),
        const SizedBox(height: 12),

        _label('OUTPUT VOLUME', c),
        const SizedBox(height: 4),
        Row(children: [
          Icon(Icons.volume_down, size: 16, color: c.gray500),
          Expanded(child: Slider(
            value: _outputVolume, min: 0, max: 200,
            onChanged: (v) { setState(() => _outputVolume = v); _storage.write(key: 'voice_output_volume', value: v.toString()); },
            activeColor: c.accent, inactiveColor: c.gray700,
          )),
          Icon(Icons.volume_up, size: 16, color: c.gray500),
          SizedBox(width: 40, child: Text('${_outputVolume.round()}%', style: TextStyle(color: c.gray400, fontSize: 12), textAlign: TextAlign.right)),
        ]),
        Text('Above 100% amplifies audio.', style: TextStyle(color: c.gray500, fontSize: 11)),

        // ═══ Video Device ═══
        const SizedBox(height: 24),
        Container(height: 1, color: c.gray700),
        const SizedBox(height: 24),
        _label('VIDEO DEVICE', c),
        const SizedBox(height: 8),
        _deviceDropdown(
          devices: _videoInputs,
          selectedId: _selectedVideoId,
          placeholder: 'Camera',
          colors: c,
          onChanged: (id) => setState(() => _selectedVideoId = id),
        ),
        const SizedBox(height: 12),
        _CameraPreview(colors: c),

        const SizedBox(height: 24),
        Container(height: 1, color: c.gray700),
        const SizedBox(height: 24),

        // ═══ Audio Processing ═══
        _label('AUDIO PROCESSING', c),
        const SizedBox(height: 12),

        _toggle('Noise Suppression', 'AI-powered noise removal (DeepFilterNet)', _noiseSuppression, c,
          (v) { setState(() => _noiseSuppression = v); _storage.write(key: 'voice_noise_suppression', value: v.toString()); }),
        const SizedBox(height: 8),
        _toggle('Echo Cancellation', 'Prevent speakers from being picked up by mic', _echoCancellation, c,
          (v) { setState(() => _echoCancellation = v); _storage.write(key: 'voice_echo_cancellation', value: v.toString()); }),
        const SizedBox(height: 8),
        _toggle('Automatic Gain Control', 'Automatically adjust microphone volume', _autoGainControl, c,
          (v) { setState(() => _autoGainControl = v); _storage.write(key: 'voice_auto_gain_control', value: v.toString()); }),

        const SizedBox(height: 24),
        Container(height: 1, color: c.gray700),
        const SizedBox(height: 24),

        // ═══ Input Mode ═══
        _label('INPUT MODE', c),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _modeCard('Voice Activity', 'Mic is always on when unmuted', 'voice_activity', c)),
          const SizedBox(width: 12),
          Expanded(child: _modeCard('Push to Talk', 'Hold a key to transmit audio', 'push_to_talk', c)),
        ]),

        const SizedBox(height: 32),
        Container(height: 2, color: c.gray600),
        const SizedBox(height: 24),

        // ═══ LiveKit Configuration ═══
        Text('LiveKit Credentials', style: TextStyle(color: c.gray50, fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text('Configure your LiveKit account to volunteer as a voice provider for servers.',
          style: TextStyle(color: c.gray500, fontSize: 12)),
        const SizedBox(height: 16),

        _label('LIVEKIT SERVER URL', c),
        const SizedBox(height: 6),
        _textField(_livekitUrlController, 'wss://your-project.livekit.cloud', c,
            onChanged: (v) => _storage.write(key: 'livekit_url', value: v.trim())),
        Text('Must use wss:// (secure WebSocket)', style: TextStyle(color: c.gray500, fontSize: 11)),
        const SizedBox(height: 12),

        _label('API KEY', c),
        const SizedBox(height: 6),
        _textField(_apiKeyController, 'APIxxxxxxxx', c,
            onChanged: (v) => _storage.write(key: 'livekit_api_key', value: v.trim())),
        const SizedBox(height: 12),

        _label('API SECRET', c),
        const SizedBox(height: 6),
        _textField(_apiSecretController, _livekitStatus != null ? '••••••••••••' : 'Enter API secret', c, obscure: true,
            onChanged: (v) { if (v.isNotEmpty) _storage.write(key: 'livekit_api_secret', value: v.trim()); }),
        Text('Encrypted at rest.', style: TextStyle(color: c.gray500, fontSize: 11)),
      ],
    );
  }

  Widget _label(String text, InfernoColors c) =>
    Text(text, style: TextStyle(color: c.gray400, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.5));

  Widget _deviceDropdown({
    required List<MediaDevice> devices,
    required String? selectedId,
    required String placeholder,
    required InfernoColors colors,
    required ValueChanged<String?> onChanged,
  }) {
    final c = colors;
    // Make sure selectedId matches an actual device; fall back to null (system default).
    final valid = devices.any((d) => d.deviceId == selectedId) ? selectedId : null;
    return DropdownButtonFormField<String?>(
      value: valid,
      dropdownColor: c.gray900,
      style: TextStyle(color: c.gray200, fontSize: 14),
      decoration: InputDecoration(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        fillColor: c.gray900,
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: c.gray700),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: c.gray700),
        ),
      ),
      hint: Text(placeholder, style: TextStyle(color: c.gray500)),
      items: [
        DropdownMenuItem<String?>(
          value: null,
          child: Text('Default (system)', style: TextStyle(color: c.gray400)),
        ),
        for (final d in devices)
          DropdownMenuItem<String?>(
            value: d.deviceId,
            child: Text(
              d.label.isNotEmpty ? d.label : d.deviceId,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }

  Widget _toggle(String label, String desc, bool value, InfernoColors c, ValueChanged<bool> onChanged) =>
    Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
        Text(desc, style: TextStyle(color: c.gray400, fontSize: 12)),
      ])),
      Switch(value: value, onChanged: onChanged, activeColor: c.accent),
    ]);

  Widget _modeCard(String title, String desc, String mode, InfernoColors c) {
    final selected = _inputMode == mode;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () { setState(() => _inputMode = mode); _storage.write(key: 'voice_input_mode', value: mode); },
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? c.accent.withValues(alpha: 0.6) : c.gray600, width: 2),
            boxShadow: selected ? [BoxShadow(color: c.accent.withValues(alpha: 0.2), blurRadius: 8)] : null,
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
            const SizedBox(height: 2),
            Text(desc, style: TextStyle(color: c.gray400, fontSize: 12)),
          ]),
        ),
      ),
    );
  }

  Widget _textField(TextEditingController ctrl, String hint, InfernoColors c, {bool obscure = false, ValueChanged<String>? onChanged}) =>
    TextField(
      controller: ctrl, obscureText: obscure,
      onChanged: onChanged,
      style: TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint, hintStyle: TextStyle(color: c.gray500),
        fillColor: c.gray900, filled: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.accent)),
      ),
    );
}

/// Pure display widget — reads level from parent, no recorder of its own.
class _MicLevelMeter extends StatelessWidget {
  final double level;
  final bool active;
  final InfernoColors colors;
  final bool showThreshold;
  final double threshold;
  final ValueChanged<double>? onThresholdChanged;
  const _MicLevelMeter({
    required this.level,
    required this.active,
    required this.colors,
    this.showThreshold = false,
    this.threshold = 0.0,
    this.onThresholdChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(active ? Icons.mic : Icons.mic_off, size: 14, color: active ? c.online : c.gray500),
          const SizedBox(width: 6),
          Text(active ? 'Mic active' : 'No microphone detected',
              style: TextStyle(color: active ? c.gray200 : c.gray500, fontSize: 11)),
        ]),
        const SizedBox(height: 6),
        SizedBox(
          height: 20,
          child: LayoutBuilder(builder: (context, constraints) {
            final maxW = constraints.maxWidth;
            final fillW = (maxW * level).clamp(0.0, maxW);
            final threshX = maxW * threshold;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: showThreshold && onThresholdChanged != null
                  ? (d) => onThresholdChanged!((d.localPosition.dx / maxW).clamp(0.0, 1.0))
                  : null,
              onTapDown: showThreshold && onThresholdChanged != null
                  ? (d) => onThresholdChanged!((d.localPosition.dx / maxW).clamp(0.0, 1.0))
                  : null,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Stack(children: [
                  Container(color: c.gray800),
                  if (showThreshold && level <= threshold && level > 0)
                    Container(width: fillW, decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [Colors.red.shade900, Colors.red.shade700])))
                  else
                    Container(width: fillW, decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [c.online, level > 0.8 ? Colors.red : c.accent]))),
                  if (showThreshold)
                    Positioned(left: threshX - 1, top: 0, bottom: 0,
                      child: Container(width: 2, color: Colors.white.withValues(alpha: 0.8))),
                  if (showThreshold)
                    Positioned(left: threshX + 4, top: 2,
                      child: Text('${(threshold * 45 - 50).round()} dB',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 9))),
                ]),
              ),
            );
          }),
        ),
        if (showThreshold)
          Padding(padding: const EdgeInsets.only(top: 4),
            child: Text('Drag the threshold line. Audio below it won\'t transmit.',
                style: TextStyle(color: c.gray500, fontSize: 11))),
      ],
    );
  }
}

/// Camera preview that starts paused — tap to enable. Shows the selected
/// video device's live feed in a 16:9 box with rounded corners.
class _CameraPreview extends StatefulWidget {
  final InfernoColors colors;
  const _CameraPreview({required this.colors});

  @override
  State<_CameraPreview> createState() => _CameraPreviewState();
}

class _CameraPreviewState extends State<_CameraPreview> {
  bool _active = false;
  rtc.RTCVideoRenderer? _renderer;
  rtc.MediaStream? _stream;

  Future<void> _toggle() async {
    if (_active) {
      await _stop();
    } else {
      await _start();
    }
  }

  Future<void> _start() async {
    try {
      _renderer = rtc.RTCVideoRenderer();
      await _renderer!.initialize();
      _stream = await rtc.navigator.mediaDevices.getUserMedia({'video': true, 'audio': false});
      _renderer!.srcObject = _stream;
      if (mounted) setState(() => _active = true);
    } catch (e) {
      debugPrint('[CameraPreview] Failed to start: $e');
      await _stop();
    }
  }

  Future<void> _stop() async {
    _stream?.getTracks().forEach((t) => t.stop());
    _stream?.dispose();
    _stream = null;
    _renderer?.srcObject = null;
    await _renderer?.dispose();
    _renderer = null;
    if (mounted) setState(() => _active = false);
  }

  @override
  void dispose() {
    _stream?.getTracks().forEach((t) => t.stop());
    _stream?.dispose();
    _renderer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          decoration: BoxDecoration(
            color: c.gray900,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.gray700),
          ),
        child: _active && _renderer != null
            ? Stack(
                fit: StackFit.expand,
                children: [
                  rtc.RTCVideoView(
                    _renderer!,
                    objectFit: rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    mirror: true,
                  ),
                  Positioned(
                    top: 8, right: 8,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: _toggle,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.videocam_off, size: 16, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ],
              )
            : MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: _toggle,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.videocam_outlined, size: 36, color: c.gray500),
                        const SizedBox(height: 8),
                        Text('Click to preview camera',
                            style: TextStyle(color: c.gray500, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ),
        ),
      ),
    );
  }
}

/// Live mic loopback with real DeepFilterNet processing. Captures raw PCM via
/// `record` (parecord on Linux), runs each 10ms frame through DeepFilterNet
/// when NS is enabled, then pipes the result to `pacat` for immediate speaker
/// output. Toggle NS on/off while listening to hear the difference in real time.
class _MicLoopback extends StatefulWidget {
  final Stream<Uint8List>? pcmStream;
  final InfernoColors colors;
  final bool noiseSuppression;
  final bool echoCancellation;
  final bool autoGainControl;
  const _MicLoopback({
    this.pcmStream,
    required this.colors,
    this.noiseSuppression = true,
    this.echoCancellation = true,
    this.autoGainControl = true,
  });

  @override
  State<_MicLoopback> createState() => _MicLoopbackState();
}

class _MicLoopbackState extends State<_MicLoopback> {
  bool _active = false;
  StreamSubscription<Uint8List>? _recSub;
  Process? _pacat;
  bool _dfAvailable = false;

  @override
  void didUpdateWidget(_MicLoopback old) {
    super.didUpdateWidget(old);
    if (_active &&
        (old.noiseSuppression != widget.noiseSuppression ||
         old.echoCancellation != widget.echoCancellation ||
         old.autoGainControl != widget.autoGainControl)) {
      _stop().then((_) => _start());
    }
  }

  Future<void> _start() async {
    if (widget.pcmStream == null) return;
    try {
      // Init DeepFilterNet if NS is on.
      if (widget.noiseSuppression) {
        try {
          final np = NoiseProcessor.instance;
          await np.init(level: 'moderate');
          _dfAvailable = np.activeProcessor == 'deepfilter';
        } catch (e) {
          debugPrint('[MicLoopback] DeepFilterNet init failed: $e');
          _dfAvailable = false;
        }
      } else {
        _dfAvailable = false;
      }

      // Shared capture is 48kHz — match for playback.
      _pacat = await Process.start('pacat', [
        '--playback',
        '--format=s16le',
        '--rate=48000',
        '--channels=1',
        '--latency-msec=50',
      ]);

      _recSub = widget.pcmStream!.listen((chunk) {
        if (chunk.length < 2) return;
        Uint8List output = chunk;

        if (_dfAvailable && widget.noiseSuppression) {
          final np = NoiseProcessor.instance;
          // s16le → float32
          final samples = chunk.buffer.asInt16List(chunk.offsetInBytes, chunk.length ~/ 2);
          final floats = Float32List(samples.length);
          for (int i = 0; i < samples.length; i++) {
            floats[i] = samples[i] / 32768.0;
          }
          // Process in 480-sample frames (10ms at 48kHz).
          const frameSize = 480;
          final processed = Float32List(floats.length);
          int off = 0;
          while (off + frameSize <= floats.length) {
            final frame = Float32List.sublistView(floats, off, off + frameSize);
            final out = np.processFrame(frame);
            processed.setAll(off, out);
            off += frameSize;
          }
          // Tail samples passthrough.
          if (off < floats.length) {
            processed.setRange(off, floats.length, floats, off);
          }
          // float32 → s16le
          final outSamples = Int16List(processed.length);
          for (int i = 0; i < processed.length; i++) {
            outSamples[i] = (processed[i] * 32767).round().clamp(-32768, 32767);
          }
          output = outSamples.buffer.asUint8List();
        }

        _pacat?.stdin.add(output);
      });

      if (mounted) setState(() => _active = true);
    } catch (e) {
      debugPrint('[MicLoopback] Failed: $e');
      await _stop();
    }
  }

  Future<void> _stop() async {
    _recSub?.cancel();
    _recSub = null;
    try { _pacat?.stdin.close(); } catch (_) {}
    _pacat?.kill();
    _pacat = null;
    _dfAvailable = false;
    if (mounted) setState(() => _active = false);
  }

  @override
  void dispose() {
    _recSub?.cancel();
    try { _pacat?.stdin.close(); } catch (_) {}
    _pacat?.kill();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    String label;
    if (_active) {
      if (_dfAvailable && widget.noiseSuppression) {
        label = 'Listening (DeepFilterNet active)';
      } else if (widget.noiseSuppression) {
        label = 'Listening (NS unavailable — raw mic)';
      } else {
        label = 'Listening (NS off — raw mic)';
      }
    } else {
      label = 'Mic playback off';
    }
    return Row(children: [
      Icon(_active ? Icons.hearing : Icons.hearing_disabled, size: 16,
          color: _active ? c.online : c.gray500),
      const SizedBox(width: 8),
      Expanded(
        child: Text(label,
          style: TextStyle(color: _active ? c.gray200 : c.gray500, fontSize: 12)),
      ),
      TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: _active ? Colors.red : c.online,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        ),
        icon: Icon(_active ? Icons.stop : Icons.play_arrow, size: 16),
        label: Text(_active ? 'Stop' : 'Let\'s Check', style: const TextStyle(fontSize: 13)),
        onPressed: _active ? _stop : _start,
      ),
    ]);
  }
}
