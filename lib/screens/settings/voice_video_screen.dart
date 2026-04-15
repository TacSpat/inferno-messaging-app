import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

  // LiveKit
  final _livekitUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _apiSecretController = TextEditingController();
  bool _livekitSaving = false;
  String? _livekitStatus;

  static const _storage = FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    // Audio processing
    _noiseSuppression = (await _storage.read(key: 'voice_noise_suppression')) != 'false';
    _echoCancellation = (await _storage.read(key: 'voice_echo_cancellation')) != 'false';
    _autoGainControl = (await _storage.read(key: 'voice_auto_gain_control')) != 'false';
    _inputMode = (await _storage.read(key: 'voice_input_mode')) ?? 'voice_activity';

    // LiveKit
    _livekitUrlController.text = await _storage.read(key: 'livekit_url') ?? '';
    _apiKeyController.text = await _storage.read(key: 'livekit_api_key') ?? '';
    final hasSecret = await _storage.read(key: 'livekit_api_secret');
    if (hasSecret != null) _livekitStatus = 'Configured';

    if (mounted) setState(() {});
  }

  Future<void> _saveLiveKit() async {
    setState(() => _livekitSaving = true);
    await _storage.write(key: 'livekit_url', value: _livekitUrlController.text.trim());
    await _storage.write(key: 'livekit_api_key', value: _apiKeyController.text.trim());
    if (_apiSecretController.text.isNotEmpty) {
      await _storage.write(key: 'livekit_api_secret', value: _apiSecretController.text.trim());
    }
    if (mounted) setState(() { _livekitSaving = false; _livekitStatus = 'Saved'; });
  }

  @override
  void dispose() {
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
        _dropdown('Microphone', 'Default', c),
        const SizedBox(height: 12),

        // Input sensitivity
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _label('INPUT SENSITIVITY', c),
          Row(children: [
            Text(_sensitivityAuto ? 'Automatic' : 'Manual', style: TextStyle(color: c.gray400, fontSize: 12)),
            const SizedBox(width: 8),
            Switch(value: _sensitivityAuto, onChanged: (v) => setState(() => _sensitivityAuto = v), activeColor: c.accent),
          ]),
        ]),
        if (!_sensitivityAuto) ...[
          const SizedBox(height: 4),
          Row(children: [
            Text('-100', style: TextStyle(color: c.gray500, fontSize: 11)),
            Expanded(child: Slider(
              value: _inputSensitivity, min: -100, max: 0,
              onChanged: (v) => setState(() => _inputSensitivity = v),
              activeColor: c.accent, inactiveColor: c.gray700,
            )),
            Text('0', style: TextStyle(color: c.gray500, fontSize: 11)),
          ]),
          Text('Sound below the threshold won\'t be transmitted.', style: TextStyle(color: c.gray500, fontSize: 11)),
        ],

        const SizedBox(height: 24),
        Container(height: 1, color: c.gray700),
        const SizedBox(height: 24),

        // ═══ Output Device ═══
        _label('OUTPUT DEVICE', c),
        const SizedBox(height: 8),
        _dropdown('Speaker / Headphones', 'Default', c),
        const SizedBox(height: 12),

        _label('OUTPUT VOLUME', c),
        const SizedBox(height: 4),
        Row(children: [
          Icon(Icons.volume_down, size: 16, color: c.gray500),
          Expanded(child: Slider(
            value: _outputVolume, min: 0, max: 200,
            onChanged: (v) => setState(() => _outputVolume = v),
            activeColor: c.accent, inactiveColor: c.gray700,
          )),
          Icon(Icons.volume_up, size: 16, color: c.gray500),
          SizedBox(width: 40, child: Text('${_outputVolume.round()}%', style: TextStyle(color: c.gray400, fontSize: 12), textAlign: TextAlign.right)),
        ]),
        Text('Above 100% amplifies audio.', style: TextStyle(color: c.gray500, fontSize: 11)),

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
        _textField(_livekitUrlController, 'wss://your-project.livekit.cloud', c),
        Text('Must use wss:// (secure WebSocket)', style: TextStyle(color: c.gray500, fontSize: 11)),
        const SizedBox(height: 12),

        _label('API KEY', c),
        const SizedBox(height: 6),
        _textField(_apiKeyController, 'APIxxxxxxxx', c),
        const SizedBox(height: 12),

        _label('API SECRET', c),
        const SizedBox(height: 6),
        _textField(_apiSecretController, _livekitStatus != null ? '••••••••••••' : 'Enter API secret', c, obscure: true),
        Text('Encrypted at rest. Leave blank to keep current secret.', style: TextStyle(color: c.gray500, fontSize: 11)),

        if (_livekitStatus != null) ...[
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.check_circle, size: 16, color: c.online),
            const SizedBox(width: 6),
            Text(_livekitStatus!, style: TextStyle(color: c.online, fontSize: 13)),
          ]),
        ],

        const SizedBox(height: 16),
        SizedBox(width: double.infinity, child: ElevatedButton(
          onPressed: _livekitSaving ? null : _saveLiveKit,
          style: ElevatedButton.styleFrom(backgroundColor: c.accent, padding: const EdgeInsets.symmetric(vertical: 12)),
          child: Text(_livekitSaving ? 'Saving...' : 'Save Changes', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        )),
      ],
    );
  }

  Widget _label(String text, InfernoColors c) =>
    Text(text, style: TextStyle(color: c.gray400, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.5));

  Widget _dropdown(String label, String defaultVal, InfernoColors c) =>
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(6), border: Border.all(color: c.gray700)),
      child: Row(children: [
        Expanded(child: Text(defaultVal, style: TextStyle(color: c.gray200, fontSize: 14))),
        Icon(Icons.keyboard_arrow_down, size: 16, color: c.gray400),
      ]),
    );

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
        onTap: () => setState(() => _inputMode = mode),
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

  Widget _textField(TextEditingController ctrl, String hint, InfernoColors c, {bool obscure = false}) =>
    TextField(
      controller: ctrl, obscureText: obscure,
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
