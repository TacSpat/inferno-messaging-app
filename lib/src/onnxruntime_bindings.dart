/// Native FFI bindings for the NSFW bridge (thin C wrapper around ONNX Runtime).
///
/// The bridge exposes three simple functions:
///   nsfw_init()     — load both ONNX models
///   nsfw_classify() — run two-stage pipeline on preprocessed CHW float data
///   nsfw_free()     — release all resources
///
/// The shared library (libnsfw_bridge.so / .dylib / .dll) is bundled
/// via hook/build.dart using the same native assets pattern as DeepFilterNet.
@DefaultAsset('package:inferno/src/onnxruntime_bindings.dart')
library;

import 'dart:ffi';
import 'package:ffi/ffi.dart';

/// Opaque handle for the NSFW detector state (sessions, env, memory info).
final class NsfwHandle extends Opaque {}

/// Result from nsfw_classify().
///
/// Layout must match the C struct exactly:
///   float nsfw_score, safe_score, questionable, unsafe_score;
///   int   stage;
///
/// Stage values:
///   0 = error/uncertain
///   1 = prefilter_pass (safe)
///   2 = confirmed (NSFW)
///   3 = overridden (false positive)
///   4 = prefilter_strong (NSFW, high-confidence prefilter)
///   5 = prefilter_only (NSFW, no confirmation model)
final class NsfwResult extends Struct {
  @Float()
  external double nsfwScore;

  @Float()
  external double safeScore;

  @Float()
  external double questionable;

  @Float()
  external double unsafeScore;

  @Int32()
  external int stage;
}

/// Initialize NSFW detector with paths to the ONNX model files.
/// [confirmPath] may be nullptr for prefilter-only mode.
/// Returns an opaque handle, or nullptr on failure.
@Native<Pointer<NsfwHandle> Function(Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'nsfw_init',
)
external Pointer<NsfwHandle> nsfwInit(
  Pointer<Utf8> prefilterPath,
  Pointer<Utf8> confirmPath,
);

/// Run two-stage NSFW classification on preprocessed image data.
///
/// [prefilterData] — float[1][3][384][384], ViT-normalized CHW
/// [confirmData]   — float[1][3][224][224], ImageNet-normalized CHW (may be nullptr)
@Native<NsfwResult Function(Pointer<NsfwHandle>, Pointer<Float>, Pointer<Float>)>(
  symbol: 'nsfw_classify',
)
external NsfwResult nsfwClassify(
  Pointer<NsfwHandle> handle,
  Pointer<Float> prefilterData,
  Pointer<Float> confirmData,
);

/// Release all ONNX Runtime resources.
@Native<Void Function(Pointer<NsfwHandle>)>(symbol: 'nsfw_free')
external void nsfwFree(Pointer<NsfwHandle> handle);
