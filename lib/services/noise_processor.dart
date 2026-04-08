import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../src/deepfilter_bindings.dart' as df;

/// Native noise suppression using DeepFilterNet3.
///
/// Pipeline: source audio -> DeepFilterNet ML denoiser -> clean audio
///
/// DeepFilterNet handles the full pipeline internally (STFT, DNN, ISTFT),
/// so no manual high-pass filter or noise gate is needed.
///
/// Suppression levels (attenuation limit in dB, matching Rails):
///   "low"        — 40 dB
///   "moderate"   — 80 dB
///   "aggressive" — 95 dB
///
/// Falls back to WebRTC built-in (handled by LiveKit) if DeepFilterNet
/// is unavailable.
class NoiseProcessor {
  static NoiseProcessor? _instance;
  _DeepFilterState? _dfState;
  String _activeProcessor = 'none'; // 'deepfilter', 'webrtc', 'none'
  String _level = 'moderate';

  NoiseProcessor._();

  static NoiseProcessor get instance {
    _instance ??= NoiseProcessor._();
    return _instance!;
  }

  String get activeProcessor => _activeProcessor;
  String get level => _level;

  /// Initialize the best available processor.
  /// DeepFilterNet model is extracted from bundled assets on first run.
  /// Falls back to WebRTC built-in (handled by LiveKit) if unavailable.
  Future<void> init({String level = 'moderate'}) async {
    _level = level;

    // Try DeepFilterNet
    try {
      _dfState = _DeepFilterState();
      await _dfState!.init(level);
      _activeProcessor = 'deepfilter';
      debugPrint('[NoiseProcessor] DeepFilterNet initialized (level=$level)');
      return;
    } catch (e) {
      debugPrint('[NoiseProcessor] DeepFilterNet not available: $e');
      _dfState = null;
    }

    // Fall back to WebRTC built-in (handled by LiveKit AudioCaptureOptions)
    _activeProcessor = 'webrtc';
    debugPrint('[NoiseProcessor] Using WebRTC built-in noise suppression');
  }

  /// Process a frame of audio samples (Float32, mono).
  /// Frame length depends on the model (typically 480 samples = 10ms at 48kHz).
  Float32List processFrame(Float32List input) {
    if (_activeProcessor == 'deepfilter' && _dfState != null) {
      return _dfState!.processFrame(input);
    }
    return input; // passthrough — WebRTC handles it at the track level
  }

  /// Update suppression level. DeepFilterNet supports live adjustment
  /// via df_set_atten_lim — no model rebuild needed.
  void setLevel(String level) {
    _level = level;
    _dfState?.setLevel(level);
  }

  void dispose() {
    _dfState?.dispose();
    _dfState = null;
    _activeProcessor = 'none';
  }
}

// ══════════════════════════════════════════
// DeepFilterNet state wrapper
// ══════════════════════════════════════════

/// Manages a DeepFilterNet DFState with model extraction and lifecycle.
class _DeepFilterState {
  Pointer<Void>? _state;
  int _frameLength = 480; // default, updated after init

  static const _modelAsset = 'assets/models/DeepFilterNet3_onnx.tar.gz';

  /// Attenuation limit in dB by suppression level (matching Rails).
  static double _attenLimForLevel(String level) => switch (level) {
    'low'        => 40.0,
    'moderate'   => 80.0,
    'aggressive' => 95.0,
    _            => 80.0,
  };

  /// Copy model asset to app support directory and initialize DeepFilterNet.
  /// df_create reads the .tar.gz directly — no extraction needed.
  Future<void> init(String level) async {
    final modelPath = await _ensureModelFile();
    final attenLim = _attenLimForLevel(level);

    final pathPtr = modelPath.toNativeUtf8();
    final logLevelPtr = 'warn'.toNativeUtf8();

    try {
      _state = df.dfCreate(pathPtr, attenLim, logLevelPtr);
      if (_state == null || _state == nullptr) {
        throw Exception('df_create returned null');
      }
      _frameLength = df.dfGetFrameLength(_state!);
      debugPrint('[DeepFilter] Frame length: $_frameLength samples');
    } finally {
      calloc.free(pathPtr);
      calloc.free(logLevelPtr);
    }
  }

  /// Process one frame through DeepFilterNet.
  /// DeepFilterNet handles STFT, DNN inference, and ISTFT internally.
  Float32List processFrame(Float32List input) {
    if (_state == null) return input;

    final length = input.length;
    final inPtr = calloc<Float>(length);
    final outPtr = calloc<Float>(length);

    try {
      // Copy input samples to native buffer
      for (int i = 0; i < length; i++) {
        inPtr[i] = input[i];
      }

      // DeepFilterNet processes the full pipeline in one call
      df.dfProcessFrame(_state!, inPtr, outPtr);

      // Copy output back to Dart
      final output = Float32List(length);
      for (int i = 0; i < length; i++) {
        output[i] = outPtr[i];
      }
      return output;
    } finally {
      calloc.free(inPtr);
      calloc.free(outPtr);
    }
  }

  /// Update attenuation limit live — no model rebuild needed.
  void setLevel(String level) {
    if (_state != null) {
      df.dfSetAttenLim(_state!, _attenLimForLevel(level));
    }
  }

  void dispose() {
    if (_state != null) {
      df.dfFree(_state!);
      _state = null;
    }
  }

  /// Copy the bundled .tar.gz model to app support directory.
  /// df_create reads the tar.gz directly — no extraction needed.
  /// Returns the file path to pass to df_create.
  Future<String> _ensureModelFile() async {
    final appSupport = await getApplicationSupportDirectory();
    final modelFile = File(p.join(appSupport.path, 'DeepFilterNet3_onnx.tar.gz'));

    // Clean up old extracted directory from previous versions
    final oldDir = Directory(p.join(appSupport.path, 'deepfilter_model'));
    if (await oldDir.exists()) {
      await oldDir.delete(recursive: true);
    }

    if (await modelFile.exists()) {
      return modelFile.path;
    }

    debugPrint('[DeepFilter] Copying model to ${modelFile.path}');
    final data = await rootBundle.load(_modelAsset);
    await modelFile.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );

    debugPrint('[DeepFilter] Model ready (${await modelFile.length()} bytes)');
    return modelFile.path;
  }
}
