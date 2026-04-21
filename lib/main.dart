import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:path_provider/path_provider.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // scrollable_positioned_list has a known semantics-layout race on Flutter
  // 3.4x where `flushSemantics` visits child render objects before layout
  // completes. In debug mode this is a fatal assertion; in release it's
  // silently ignored. We install an error handler that swallows ONLY this
  // specific assertion so the app survives in debug while keeping all other
  // errors loud.
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    final msg = details.exceptionAsString();
    if (msg.contains('childSemantics.renderObject._needsLayout') ||
        msg.contains('semantics.parentDataDirty')) {
      // Swallow — package bug, harmless in practice.
      return;
    }
    defaultOnError?.call(details);
  };

  // Log to file on Windows for debugging (no console available)
  if (Platform.isWindows && !kDebugMode) {
    try {
      final appSupport = await getApplicationSupportDirectory();
      final logFile = File('${appSupport.path}/inferno.log');
      final sink = logFile.openWrite(mode: FileMode.write);
      sink.writeln('[${DateTime.now()}] Inferno starting...');
      sink.writeln('[${DateTime.now()}] Exe: ${Platform.resolvedExecutable}');
      sink.writeln('[${DateTime.now()}] Working dir: ${Directory.current.path}');

      // Redirect debugPrint to log file
      debugPrint = (String? message, {int? wrapWidth}) {
        sink.writeln('[${DateTime.now()}] $message');
      };

      try {
        sink.writeln('[${DateTime.now()}] Initializing fvp...');
        fvp.registerWith(options: {
          // Quiet fvp/mdk's native logs. By default it calls
          // `setGlobalOption("log", "all")` which spams messages like
          // "texture and fbo are not created yet" into stderr during the
          // brief window between controller creation and texture allocation.
          'global': {'log': 'error'},
        });
        sink.writeln('[${DateTime.now()}] fvp OK');
      } catch (e, st) {
        sink.writeln('[${DateTime.now()}] fvp FAILED: $e\n$st');
      }

      sink.writeln('[${DateTime.now()}] Running app...');
      await sink.flush();

      runApp(const ProviderScope(child: InfernoApp()));
    } catch (e, st) {
      final crashFile = File('${Platform.resolvedExecutable}.crash.log');
      crashFile.writeAsStringSync('[${DateTime.now()}] CRASH: $e\n$st');
    }
  } else {
    fvp.registerWith(options: {
          // Quiet fvp/mdk's native logs. By default it calls
          // `setGlobalOption("log", "all")` which spams messages like
          // "texture and fbo are not created yet" into stderr during the
          // brief window between controller creation and texture allocation.
          'global': {'log': 'error'},
        });
    runApp(const ProviderScope(child: InfernoApp()));
  }
}
