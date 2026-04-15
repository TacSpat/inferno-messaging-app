import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:path_provider/path_provider.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
        fvp.registerWith();
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
    fvp.registerWith();
    runApp(const ProviderScope(child: InfernoApp()));
  }
}
