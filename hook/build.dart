import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';

/// Build hook that compiles DeepFilterNet from Rust source into a shared library.
///
/// The resulting .so/.dylib/.dll is automatically bundled into the app
/// on all platforms (Linux, macOS, Windows, Android, iOS).
///
/// Prerequisites: clone https://github.com/Rikorose/DeepFilterNet.git
/// into native/deepfilter/DeepFilterNet/ (or set DEEPFILTER_SRC env var).
///
/// If Rust/cargo is not available or the source is missing, the build is
/// skipped and the app falls back to WebRTC built-in noise suppression.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final packageRoot = input.packageRoot;

    // Check for prebuilt library first (CI or manual build)
    final prebuilt = _findPrebuilt(packageRoot, input.config.code.targetOS);
    if (prebuilt != null) {
      _registerAsset(output, input, prebuilt);
      stderr.writeln('[hook/build.dart] Using prebuilt DeepFilterNet: $prebuilt');
      return;
    }

    // Try to build from source
    final srcDir = _findSource(packageRoot);
    if (srcDir == null) {
      stderr.writeln(
        '[hook/build.dart] DeepFilterNet source not found and no prebuilt lib.\n'
        'Falling back to WebRTC built-in noise suppression.\n'
        'To enable: place libdf.so in native/deepfilter/ or clone the repo.',
      );
      return;
    }

    stderr.writeln('[hook/build.dart] Building DeepFilterNet from $srcDir');

    final result = await Process.run(
      'cargo',
      [
        'build',
        '--release',
        '--lib',
        '--features',
        'capi',
        '-p',
        'deep_filter',
      ],
      workingDirectory: srcDir,
      environment: {'CARGO_TERM_COLOR': 'never'},
    );

    if (result.exitCode != 0) {
      stderr.writeln('[hook/build.dart] cargo build failed:\n${result.stderr}');
      return;
    }

    // Find the built library
    final targetDir = '$srcDir/target/release';
    final libName = _libName(input.config.code.targetOS);
    final builtLib = File('$targetDir/$libName');

    if (!builtLib.existsSync()) {
      stderr.writeln('[hook/build.dart] Built library not found: ${builtLib.path}');
      return;
    }

    // Copy to output directory
    final outFile = File.fromUri(
      input.outputDirectory.resolve(libName),
    );
    builtLib.copySync(outFile.path);

    // Strip if on Linux/macOS
    if (input.config.code.targetOS == OS.linux ||
        input.config.code.targetOS == OS.macOS) {
      await Process.run('strip', ['--strip-unneeded', outFile.path]);
    }

    _registerAsset(output, input, outFile);
    stderr.writeln('[hook/build.dart] DeepFilterNet built: ${outFile.path}');
  });
}

/// Register the native library as a code asset.
void _registerAsset(BuildOutputBuilder output, BuildInput input, File lib) {
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'src/deepfilter_bindings.dart',
      file: lib.uri,
      linkMode: DynamicLoadingBundled(),
    ),
  );
  output.addDependency(lib.uri);
}

/// Look for a prebuilt library in native/deepfilter/
File? _findPrebuilt(Uri packageRoot, OS os) {
  final name = _libName(os);
  final prebuilt = File.fromUri(packageRoot.resolve('native/deepfilter/$name'));
  return prebuilt.existsSync() ? prebuilt : null;
}

/// Look for DeepFilterNet source (Cargo.toml with libDF workspace)
String? _findSource(Uri packageRoot) {
  // Check native/deepfilter/DeepFilterNet/
  final localSrc =
      Directory.fromUri(packageRoot.resolve('native/deepfilter/DeepFilterNet/'));
  if (localSrc.existsSync() &&
      File('${localSrc.path}/libDF/Cargo.toml').existsSync()) {
    return localSrc.path;
  }
  // Check DEEPFILTER_SRC env var
  final envSrc = Platform.environment['DEEPFILTER_SRC'];
  if (envSrc != null && File('$envSrc/libDF/Cargo.toml').existsSync()) {
    return envSrc;
  }
  return null;
}

String _libName(OS os) => switch (os) {
  OS.linux   => 'libdf.so',
  OS.macOS   => 'libdf.dylib',
  OS.windows => 'df.dll',
  OS.android => 'libdf.so',
  OS.iOS     => 'libdf.dylib',
  _          => 'libdf.so',
};
