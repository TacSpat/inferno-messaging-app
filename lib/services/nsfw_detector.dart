import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../src/onnxruntime_bindings.dart' as ort;

/// Two-stage NSFW detection pipeline using ONNX Runtime.
///
/// Stage 1 (pre-filter): Marqo ViT-Tiny (384x384)
///   Very sensitive — catches drawn NSFW but has false positives.
///   If score < 0.5 → safe, skip stage 2.
///
/// Stage 2 (confirmation): TostAI FocalNet-Base (224x224)
///   5-class: drawings, hentai, neutral, porn, sexy.
///   Confirms the pre-filter's suspicion.
///
/// Decision logic matches Rails nsfw_detector.rb exactly.
class NsfwDetector {
  static NsfwDetector? _instance;

  Pointer<ort.NsfwHandle>? _handle;
  bool _available = false;

  NsfwDetector._();

  static NsfwDetector get instance {
    _instance ??= NsfwDetector._();
    return _instance!;
  }

  bool get available => _available;

  // ViT normalization only (prefilter-only mode)

  /// Initialize the NSFW detector by extracting models and loading ONNX sessions.
  /// Falls back gracefully if ONNX Runtime is not available.
  Future<void> init() async {
    try {
      final prefilterPath = await _ensureModelFile(
        'assets/models/nsfw_marqo.onnx',
        'nsfw_marqo.onnx',
        dataFile: 'assets/models/nsfw_marqo.onnx.data',
        dataName: 'nsfw_marqo.onnx.data',
      );

      // nsfwInit is a synchronous FFI call that makes ONNX Runtime parse a
      // 22 MB model. Run on the main isolate it blocks the UI thread for the
      // whole load and the app appears frozen at startup.
      //
      // This only started mattering once the models were actually bundled:
      // before that the extraction above threw, so init never reached the FFI
      // call and the cost was invisible. Inference was already offloaded via
      // compute(); init was the one path that never had to be.
      //
      // The handle crosses the isolate boundary as an integer address, exactly
      // as _runInference already does — same process, same address space.
      final handleAddress = await compute(_initNative, prefilterPath);
      if (handleAddress == 0) {
        throw Exception('nsfw_init returned null');
      }
      _handle = Pointer<ort.NsfwHandle>.fromAddress(handleAddress);
      _available = true;
      debugPrint('[NsfwDetector] Initialized (prefilter-only mode)');
    } catch (e) {
      debugPrint('[NsfwDetector] Not available: $e');
      _available = false;
    }
  }

  /// Classify a single image. Returns NsfwClassification.
  Future<NsfwClassification> classify(Uint8List imageBytes) async {
    if (!_available || _handle == null) {
      return NsfwClassification.safe();
    }

    try {
      // Decode image
      final decoded = img.decodeImage(imageBytes);
      if (decoded == null) return NsfwClassification.safe();

      // Preprocess for prefilter (384x384, ViT normalization)
      final pfData = _preprocessImage(decoded, 384, _vitNormalize);

      // Run inference (on isolate to avoid blocking UI)
      // Prefilter-only mode: pass empty confirm data
      return await compute(_runInference, _InferenceRequest(
        handleAddress: _handle!.address,
        prefilterData: pfData,
      ));
    } catch (e) {
      debugPrint('[NsfwDetector] Classification failed: $e');
      return NsfwClassification.safe();
    }
  }

  /// Check if any image attachment in a message's fileUrls is explicit.
  Future<bool> anyExplicit(String? fileUrlsJson, {double threshold = 0.7}) async {
    if (!_available || fileUrlsJson == null || fileUrlsJson.isEmpty) return false;

    final List<dynamic> urls;
    try {
      urls = jsonDecode(fileUrlsJson) as List<dynamic>;
    } catch (_) {
      return false;
    }

    for (final url in urls) {
      final urlStr = url.toString();
      final lower = urlStr.toLowerCase();
      if (!_isImageUrl(lower)) continue;

      try {
        final response = await http.get(Uri.parse(urlStr));
        if (response.statusCode == 200) {
          final result = await classify(response.bodyBytes);
          if (result.isExplicit) return true;
        }
      } catch (e) {
        debugPrint('[NsfwDetector] Failed to check $urlStr: $e');
      }
    }
    return false;
  }

  void dispose() {
    if (_handle != null && _handle != nullptr) {
      ort.nsfwFree(_handle!);
      _handle = null;
    }
    _available = false;
  }

  // ── Image preprocessing ──

  /// Preprocess image: resize to targetSize×targetSize, convert to CHW float array.
  Float32List _preprocessImage(img.Image image, int targetSize,
      double Function(double val, int channel) normalize) {
    // Center-crop resize
    final scale = targetSize / (image.width < image.height ? image.width : image.height);
    final resized = img.copyResize(image,
        width: (image.width * scale).ceil(),
        height: (image.height * scale).ceil(),
        interpolation: img.Interpolation.linear);

    final cropX = (resized.width - targetSize) ~/ 2;
    final cropY = (resized.height - targetSize) ~/ 2;
    final cropped = img.copyCrop(resized,
        x: cropX, y: cropY, width: targetSize, height: targetSize);

    // Convert to CHW float array with normalization
    final data = Float32List(3 * targetSize * targetSize);
    for (int y = 0; y < targetSize; y++) {
      for (int x = 0; x < targetSize; x++) {
        final pixel = cropped.getPixel(x, y);
        final r = pixel.r / 255.0;
        final g = pixel.g / 255.0;
        final b = pixel.b / 255.0;
        final idx = y * targetSize + x;
        data[0 * targetSize * targetSize + idx] = normalize(r, 0);
        data[1 * targetSize * targetSize + idx] = normalize(g, 1);
        data[2 * targetSize * targetSize + idx] = normalize(b, 2);
      }
    }
    return data;
  }

  /// ViT normalization: (val - 0.5) / 0.5
  static double _vitNormalize(double val, int channel) => (val - 0.5) / 0.5;


  bool _isImageUrl(String lower) {
    return lower.endsWith('.jpg') || lower.endsWith('.jpeg') ||
        lower.endsWith('.png') || lower.endsWith('.gif') ||
        lower.endsWith('.webp') || lower.endsWith('.bmp') ||
        lower.contains('image');
  }

  /// Copy a bundled asset model file to app support directory.
  /// ONNX models with external data need both .onnx and .onnx.data files
  /// in the same directory.
  Future<String> _ensureModelFile(String assetPath, String fileName,
      {String? dataFile, String? dataName}) async {
    final appSupport = await getApplicationSupportDirectory();
    final modelDir = Directory(p.join(appSupport.path, 'nsfw_models'));
    if (!await modelDir.exists()) {
      await modelDir.create(recursive: true);
    }

    final modelFile = File(p.join(modelDir.path, fileName));
    if (!await modelFile.exists()) {
      debugPrint('[NsfwDetector] Copying $fileName to ${modelFile.path}');
      final data = await rootBundle.load(assetPath);
      await modelFile.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }

    // Also copy the external data file if present
    if (dataFile != null && dataName != null) {
      final dataFileObj = File(p.join(modelDir.path, dataName));
      if (!await dataFileObj.exists()) {
        debugPrint('[NsfwDetector] Copying $dataName to ${dataFileObj.path}');
        final data = await rootBundle.load(dataFile);
        await dataFileObj.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      }
    }

    return modelFile.path;
  }
}

/// Run ONNX inference on a separate isolate.
/// Loads the ONNX session on a background isolate and returns the handle
/// address, or 0 on failure. Top-level so it can be passed to compute().
///
/// Only needs a file path, so it does not touch rootBundle or path_provider
/// and needs no BackgroundIsolateBinaryMessenger setup.
int _initNative(String modelPath) {
  final pathPtr = modelPath.toNativeUtf8();
  try {
    final handle = ort.nsfwInit(pathPtr, nullptr);
    return handle == nullptr ? 0 : handle.address;
  } catch (_) {
    return 0;
  } finally {
    calloc.free(pathPtr);
  }
}

NsfwClassification _runInference(_InferenceRequest req) {
  final handle = Pointer<ort.NsfwHandle>.fromAddress(req.handleAddress);

  // Allocate native memory for prefilter input tensor
  final pfSize = req.prefilterData.length;
  final pfPtr = calloc<Float>(pfSize);

  try {
    for (int i = 0; i < pfSize; i++) {
      pfPtr[i] = req.prefilterData[i];
    }

    // Prefilter-only: pass nullptr for confirmation data
    final result = ort.nsfwClassify(handle, pfPtr, nullptr);

    return NsfwClassification(
      nsfwScore: result.nsfwScore,
      safeScore: result.safeScore,
      questionable: result.questionable,
      unsafeScore: result.unsafeScore,
      stage: _stageFromInt(result.stage),
    );
  } finally {
    calloc.free(pfPtr);
  }
}

class _InferenceRequest {
  final int handleAddress;
  final Float32List prefilterData;

  _InferenceRequest({
    required this.handleAddress,
    required this.prefilterData,
  });
}

NsfwStage _stageFromInt(int stage) => switch (stage) {
  1 => NsfwStage.prefilterPass,
  2 => NsfwStage.confirmed,
  3 => NsfwStage.overridden,
  4 => NsfwStage.prefilterStrong,
  5 => NsfwStage.prefilterOnly,
  _ => NsfwStage.error,
};

enum NsfwStage {
  error,
  prefilterPass,
  confirmed,
  overridden,
  prefilterStrong,
  prefilterOnly,
}

class NsfwClassification {
  final double nsfwScore;
  final double safeScore;
  final double questionable;
  final double unsafeScore;
  final NsfwStage stage;

  NsfwClassification({
    required this.nsfwScore,
    required this.safeScore,
    required this.questionable,
    required this.unsafeScore,
    required this.stage,
  });

  factory NsfwClassification.safe() => NsfwClassification(
    nsfwScore: 0.0,
    safeScore: 1.0,
    questionable: 0.0,
    unsafeScore: 0.0,
    stage: NsfwStage.prefilterPass,
  );

  /// Whether this classification indicates explicit content.
  bool get isExplicit => stage == NsfwStage.confirmed || stage == NsfwStage.prefilterStrong;

  /// Category string for the hidden reason.
  String? get category {
    if (!isExplicit) return null;
    if (unsafeScore > questionable) return 'nsfw';
    return 'nsfw_questionable';
  }

  double get confidence => switch (stage) {
    NsfwStage.confirmed => unsafeScore + questionable,
    NsfwStage.prefilterStrong => nsfwScore,
    _ => 0.0,
  };
}
