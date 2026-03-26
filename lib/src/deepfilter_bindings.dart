/// Native FFI bindings for DeepFilterNet, auto-linked via Dart native assets.
///
/// The shared library is compiled from Rust/C source by `hook/build.dart`
/// and bundled automatically into the app on all platforms.
/// No manual DynamicLibrary.open() or path searching needed.
@DefaultAsset('package:inferno/src/deepfilter_bindings.dart')
library;

import 'dart:ffi';
import 'package:ffi/ffi.dart';

/// Create a new DeepFilterNet state.
///
/// [path] — path to the model directory (extracted .tar.gz contents)
/// [attenLim] — initial attenuation limit in dB (e.g. 40, 80, 95)
/// [logLevel] — logging level string (e.g. "error", "warn", "info", "debug")
///
/// Returns an opaque pointer (DFState*), or nullptr on failure.
@Native<Pointer<Void> Function(Pointer<Utf8>, Float, Pointer<Utf8>)>(
  symbol: 'df_create',
)
external Pointer<Void> dfCreate(
  Pointer<Utf8> path,
  double attenLim,
  Pointer<Utf8> logLevel,
);

/// Destroy a DeepFilterNet state and free all memory.
@Native<Void Function(Pointer<Void>)>(symbol: 'df_free')
external void dfFree(Pointer<Void> model);

/// Process one frame of audio through the full DeepFilterNet pipeline
/// (STFT -> DNN inference -> ISTFT).
///
/// [st] — opaque DFState* from [dfCreate]
/// [input] — input buffer of float samples (frame length from [dfGetFrameLength])
/// [output] — output buffer of float samples (same length as input)
///
/// Returns the estimated local SNR in dB.
@Native<Float Function(Pointer<Void>, Pointer<Float>, Pointer<Float>)>(
  symbol: 'df_process_frame',
)
external double dfProcessFrame(
  Pointer<Void> st,
  Pointer<Float> input,
  Pointer<Float> output,
);

/// Get the frame length in samples expected by this DeepFilterNet model.
///
/// Typically 480 samples (10ms at 48kHz), but depends on the model.
@Native<Size Function(Pointer<Void>)>(symbol: 'df_get_frame_length')
external int dfGetFrameLength(Pointer<Void> st);

/// Set the attenuation limit in dB for noise suppression.
///
/// Higher values = more aggressive suppression.
/// Can be called at any time without rebuilding the model.
@Native<Void Function(Pointer<Void>, Float)>(symbol: 'df_set_atten_lim')
external void dfSetAttenLim(Pointer<Void> st, double limDb);

/// Set the post-filter beta coefficient.
///
/// Controls the strength of the post-filter (0.0 = off, higher = stronger).
@Native<Void Function(Pointer<Void>, Float)>(symbol: 'df_set_post_filter_beta')
external void dfSetPostFilterBeta(Pointer<Void> st, double beta);
