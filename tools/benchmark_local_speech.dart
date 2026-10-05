// Native, network-free benchmark. SHERPA_NATIVE_DIR is optional on mobile.
// dart run tools/benchmark_local_speech.dart sample.wav "Hello!"
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:english_point_reading/services/speech_alignment.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('Usage: benchmark_local_speech.dart sample.wav "reference"');
    exitCode = 2;
    return;
  }
  // No downloading or HTTP access is allowed during this local benchmark.
  HttpOverrides.global = _NoNetworkHttpOverrides();
  final nativeDirectory = Platform.environment['SHERPA_NATIVE_DIR'];
  if (Platform.isWindows && nativeDirectory != null) {
    // Windows System32 may contain its own older onnxruntime.dll. A PATH
    // change does not override System32, so preload the matching packaged DLL
    // by absolute path before opening Sherpa and resolving its dependency.
    final runtime = File('$nativeDirectory/onnxruntime.dll');
    if (!runtime.existsSync()) {
      throw StateError('Missing matching ONNX Runtime DLL: ${runtime.path}');
    }
    DynamicLibrary.open(runtime.absolute.path);
  }
  sherpa.initBindings(nativeDirectory);
  const model = 'assets/models/sherpa';
  final timer = Stopwatch()..start();
  final recognizer = sherpa.OnlineRecognizer(
    sherpa.OnlineRecognizerConfig(
      model: sherpa.OnlineModelConfig(
        transducer: const sherpa.OnlineTransducerModelConfig(
          encoder: '$model/encoder.int8.onnx',
          decoder: '$model/decoder.onnx',
          joiner: '$model/joiner.int8.onnx',
        ),
        tokens: '$model/tokens.txt',
        modelType: 'zipformer2',
        numThreads: 2,
        debug: false,
      ),
      enableEndpoint: false,
    ),
  );
  final initializationMs = timer.elapsedMicroseconds / 1000;
  final wave = sherpa.readWave(args[0]);
  final measurements = <Map<String, Object>>[];
  try {
    for (var run = 0; run < 5; run++) {
      final stream = recognizer.createStream();
      try {
        timer.reset();
        // The App decodes while recording; finalization is measured separately.
        for (var offset = 0; offset < wave.samples.length; offset += 1600) {
          final end = math.min(offset + 1600, wave.samples.length);
          stream.acceptWaveform(
            samples: Float32List.sublistView(wave.samples, offset, end),
            sampleRate: wave.sampleRate,
          );
          while (recognizer.isReady(stream)) {
            recognizer.decode(stream);
          }
        }
        final streamingDecodeMs = timer.elapsedMicroseconds / 1000;
        timer.reset();
        stream.acceptWaveform(samples: Float32List(8000), sampleRate: 16000);
        stream.inputFinished();
        while (recognizer.isReady(stream)) {
          recognizer.decode(stream);
        }
        final transcript = recognizer.getResult(stream).text.trim();
        final result = evaluateSpeech(args[1], transcript);
        measurements.add({
          'run': run + 1,
          'streamingDecodeMs': streamingDecodeMs,
          'stopToScoreMs': timer.elapsedMicroseconds / 1000,
          'recognizedText': transcript,
          'score': result.score,
          'nativeWordConfidenceAvailable': result.hasNativeConfidence,
        });
      } finally {
        stream.free();
      }
    }
  } finally {
    recognizer.free();
  }
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'platform': Platform.operatingSystem,
      'sherpaNativeVersion': sherpa.getVersion(),
      'onnxRuntimeVersion': sherpa.getOnnxruntimeVersion(),
      'initializationMs': initializationMs,
      'audioSeconds': wave.samples.length / wave.sampleRate,
      'referenceText': args[1],
      'networkUsedDuringRecognition': false,
      'dartHttpAccessDisabled': true,
      'measurements': measurements,
      'allStopToScoreUnder300Ms': measurements.every(
        (item) => (item['stopToScoreMs'] as double) < 300,
      ),
      'physicalAndroidDeviceTested': false,
    }),
  );
}

class _NoNetworkHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw UnsupportedError('Network access is disabled during recognition.');
}
