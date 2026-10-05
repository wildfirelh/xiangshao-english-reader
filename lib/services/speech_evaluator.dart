import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../models/speech_evaluation.dart';
import 'sherpa_model_assets.dart';
import 'sherpa_recognition_worker.dart';
import 'speech_alignment.dart';

export '../models/speech_evaluation.dart';
export 'sherpa_recognition_worker.dart'
    show SpeechRecognitionBackend, SpeechRecognitionSnapshot;

enum RecordingStopReason { maxDuration, silence }

class SpeechEvaluationException implements Exception {
  const SpeechEvaluationException(
    this.message, {
    this.permissionDenied = false,
    this.permanentlyDenied = false,
  });

  final String message;
  final bool permissionDenied;
  final bool permanentlyDenied;

  @override
  String toString() => message;
}

abstract class SpeechEvaluator {
  Future<void> startRecording(String sentenceId);
  Future<EvaluationResult> stopAndEvaluate(
    String sentenceId,
    String referenceText,
  );
  void cancel();

  // Concrete defaults retain the original three-method test/mock contract.
  Future<void> prepare() async {}
  Stream<double> get amplitudes => const Stream.empty();
  Stream<RecordingStopReason> get recordingStops => const Stream.empty();
  String? get recordingPath => null;
  Future<bool> openPermissionSettings() async => false;
  Future<void> dispose() async => cancel();
}

class MockSpeechEvaluator extends SpeechEvaluator {
  @override
  Future<void> startRecording(String sentenceId) async {
    debugPrint('MockSpeechEvaluator: startRecording($sentenceId)');
  }

  @override
  Future<EvaluationResult> stopAndEvaluate(
    String sentenceId,
    String referenceText,
  ) async {
    debugPrint('MockSpeechEvaluator: evaluate($sentenceId, $referenceText)');
    return const EvaluationResult(score: 0, details: '测试评测占位');
  }

  @override
  void cancel() => debugPrint('MockSpeechEvaluator: cancel()');
}

enum MicrophonePermission { granted, denied, permanentlyDenied }

abstract class SpeechRecordingBackend {
  Future<MicrophonePermission> requestPermission();
  Future<bool> openPermissionSettings();
  Future<Stream<Uint8List>> startPcmStream();
  Future<void> stop();
  Future<void> cancel();
  Future<void> dispose();
}

class DeviceSpeechRecordingBackend implements SpeechRecordingBackend {
  /// audio_session owns focus. A second recorder focus request would interrupt
  /// our own session immediately on Android, before the child can start reading.
  static const config = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 16000,
    numChannels: 1,
    audioInterruption: AudioInterruptionMode.none,
    autoGain: false,
    echoCancel: true,
    noiseSuppress: true,
    androidConfig: AndroidRecordConfig(
      audioSource: AndroidAudioSource.voiceRecognition,
      manageBluetooth: false,
    ),
  );

  AudioRecorder? _recorder;
  StreamController<Uint8List>? _output;
  StreamSubscription<Uint8List>? _data;
  StreamSubscription<RecordState>? _states;
  bool _deliberateStop = false;

  @override
  Future<MicrophonePermission> requestPermission() async {
    final permission = await Permission.microphone.request();
    if (permission.isGranted) return MicrophonePermission.granted;
    if (permission.isPermanentlyDenied || permission.isRestricted) {
      return MicrophonePermission.permanentlyDenied;
    }
    return MicrophonePermission.denied;
  }

  @override
  Future<bool> openPermissionSettings() => openAppSettings();

  @override
  Future<Stream<Uint8List>> startPcmStream() async {
    final recorder = _recorder ??= AudioRecorder();
    _deliberateStop = false;
    final input = await recorder.startStream(config);
    final output = _output = StreamController<Uint8List>.broadcast(sync: true);
    _data = input.listen(
      output.add,
      onError: output.addError,
      onDone: () {
        if (!output.isClosed) unawaited(output.close());
      },
    );
    _states = recorder.onStateChanged().listen((state) {
      if (!_deliberateStop &&
          (state == RecordState.pause || state == RecordState.stop) &&
          !output.isClosed) {
        output.addError(StateError('Microphone capture interrupted'));
      }
    });
    return output.stream;
  }

  @override
  Future<void> stop() async {
    _deliberateStop = true;
    await _recorder?.stop();
    await _closeStream();
  }

  @override
  Future<void> cancel() async {
    _deliberateStop = true;
    await _recorder?.cancel();
    await _closeStream();
  }

  Future<void> _closeStream() async {
    await _states?.cancel();
    _states = null;
    await _data?.cancel();
    _data = null;
    final output = _output;
    _output = null;
    if (output != null && !output.isClosed) await output.close();
  }

  @override
  Future<void> dispose() async {
    _deliberateStop = true;
    await _recorder?.dispose();
    await _closeStream();
    _recorder = null;
  }
}

abstract class SpeechAudioSession {
  Stream<void> get interruptions => const Stream.empty();
  Future<void> beginRecording();
  Future<void> restorePlayback();
  Future<void> dispose() => restorePlayback();
}

class DeviceSpeechAudioSession implements SpeechAudioSession {
  AudioSession? _session;
  AudioSessionConfiguration? _previousConfiguration;
  final _events = StreamController<void>.broadcast(sync: true);
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;

  @override
  Stream<void> get interruptions => _events.stream;

  @override
  Future<void> beginRecording() async {
    final session = _session = await AudioSession.instance;
    _previousConfiguration ??= session.configuration;
    _interruptionSubscription = session.interruptionEventStream.listen((event) {
      if (event.begin && event.type != AudioInterruptionType.duck) {
        _events.add(null);
      }
    });
    await session.configure(
      const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionMode: AVAudioSessionMode.measurement,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransient,
        androidWillPauseWhenDucked: true,
      ),
    );
    if (!await session.setActive(true)) {
      throw const SpeechEvaluationException('当前无法使用麦克风，请稍后再试');
    }
  }

  @override
  Future<void> restorePlayback() async {
    final session = _session;
    if (session == null) return;
    await _interruptionSubscription?.cancel();
    _interruptionSubscription = null;
    await session.setActive(false);
    await session.configure(
      _previousConfiguration ??
          const AudioSessionConfiguration.speech().copyWith(
            androidWillPauseWhenDucked: false,
          ),
    );
    _previousConfiguration = null;
    _session = null;
  }

  @override
  Future<void> dispose() async {
    await restorePlayback();
    await _events.close();
  }
}

/// Local PCM capture, independent streaming ASR and word sequence assessment.
/// Native inference never runs on the Flutter UI isolate.
class LocalSherpaSpeechEvaluator extends SpeechEvaluator {
  LocalSherpaSpeechEvaluator({
    SpeechRecordingBackend? recorder,
    SpeechRecognitionBackend? recognizer,
    SpeechAudioSession? audioSession,
    Future<Directory> Function()? temporaryDirectory,
    this.maxRecordingDuration = const Duration(seconds: 15),
    this.silenceDuration = const Duration(milliseconds: 1500),
    this.silenceThreshold = 0.0126,
  }) : _recorder = recorder ?? DeviceSpeechRecordingBackend(),
       _recognizer =
           recognizer ??
           SherpaRecognitionWorker(modelProvider: _copyModelAssets),
       _audioSession = audioSession ?? DeviceSpeechAudioSession(),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory {
    _focusSubscription = _audioSession.interruptions.listen((_) {
      if ((_capturing || _startingCapture) && !_disposed) {
        _captureError(StateError('录音被其他音频打断'), _generation);
      }
    });
  }

  final SpeechRecordingBackend _recorder;
  final SpeechRecognitionBackend _recognizer;
  final SpeechAudioSession _audioSession;
  final Future<Directory> Function() _temporaryDirectory;
  final Duration maxRecordingDuration;
  final Duration silenceDuration;
  final double silenceThreshold;
  final _amplitudeEvents = StreamController<double>.broadcast(sync: true);
  final _stopEvents = StreamController<RecordingStopReason>.broadcast(
    sync: true,
  );
  Future<void> _operations = Future.value();
  Future<void>? _preparation;
  Future<void>? _disposal;
  Future<EvaluationResult>? _evaluation;
  StreamSubscription<Uint8List>? _pcmSubscription;
  late final StreamSubscription<void> _focusSubscription;
  Future<void>? _halting;
  Timer? _maximumTimer;
  Timer? _silenceTimer;
  BytesBuilder _pcm = BytesBuilder(copy: false);
  int _generation = 0;
  int _voiceSamples = 0;
  bool _heardVoice = false;
  bool _capturing = false;
  bool _startingCapture = false;
  bool _acceptingPcm = false;
  bool _stopRequested = false;
  bool _disposed = false;
  String? _sentenceId;
  String? _recordingPath;
  bool _recordingFinalized = false;
  Object? _captureFailure;

  @override
  Stream<double> get amplitudes => _amplitudeEvents.stream;
  @override
  Stream<RecordingStopReason> get recordingStops => _stopEvents.stream;
  @override
  String? get recordingPath => _recordingPath;

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  @override
  Future<void> prepare() {
    if (_disposed) {
      return Future.error(const SpeechEvaluationException('跟读页面已关闭'));
    }
    return _preparation ??= _recognizer.prepare().catchError((Object error) {
      _preparation = null;
      throw SpeechEvaluationException('离线语音模型加载失败，请重新打开跟读：$error');
    });
  }

  void _checkCurrent(int generation) {
    if (_disposed || generation != _generation) {
      throw const SpeechEvaluationException('本次录音已取消');
    }
  }

  @override
  Future<void> startRecording(String sentenceId) {
    if (_disposed) {
      return Future.error(const SpeechEvaluationException('跟读页面已关闭'));
    }
    final generation = ++_generation;
    _cancelTimers();
    _capturing = false;
    return _serialize(() async {
      _checkCurrent(generation);
      await _clearCapture(deleteFinalRecording: true);
      _checkCurrent(generation);
      try {
        final permission = await _recorder.requestPermission();
        _checkCurrent(generation);
        if (permission != MicrophonePermission.granted) {
          throw SpeechEvaluationException(
            permission == MicrophonePermission.permanentlyDenied
                ? '麦克风权限已关闭，请在系统设置中允许后重试'
                : '需要麦克风权限才能跟读，请允许后重试',
            permissionDenied: true,
            permanentlyDenied:
                permission == MicrophonePermission.permanentlyDenied,
          );
        }
        await prepare();
        _checkCurrent(generation);
        await _recognizer.begin();
        _checkCurrent(generation);
        _captureFailure = null;
        _startingCapture = true;
        await _audioSession.beginRecording();
        _checkCurrent(generation);
        final stream = await _recorder.startPcmStream();
        _checkCurrent(generation);
        _startingCapture = false;
        _pcm = BytesBuilder(copy: false);
        _voiceSamples = 0;
        _heardVoice = false;
        _stopRequested = false;
        _evaluation = null;
        _sentenceId = sentenceId;
        _capturing = true;
        _acceptingPcm = true;
        _halting = null;
        _pcmSubscription = stream.listen(
          (bytes) => _acceptPcm(bytes, generation),
          onError: (Object error) => _captureError(error, generation),
          onDone: () {
            if (_capturing && generation == _generation) {
              _captureError(StateError('录音意外结束'), generation);
            }
          },
        );
        _maximumTimer = Timer(
          maxRecordingDuration,
          () => _requestAutomaticStop(
            RecordingStopReason.maxDuration,
            generation,
          ),
        );
      } catch (error) {
        await _clearCapture(deleteFinalRecording: false);
        if (error is SpeechEvaluationException) rethrow;
        throw SpeechEvaluationException('无法开始录音，请重试：$error');
      }
    });
  }

  void _acceptPcm(Uint8List bytes, int generation) {
    if (!_acceptingPcm || generation != _generation || bytes.isEmpty) return;
    final maximumBytes = maxRecordingDuration.inMicroseconds * 32000 ~/ 1000000;
    final remaining = maximumBytes - _pcm.length;
    if (remaining <= 0) {
      _requestAutomaticStop(RecordingStopReason.maxDuration, generation);
      return;
    }
    final captured = Uint8List.fromList(
      bytes.length <= remaining ? bytes : bytes.sublist(0, remaining),
    );
    _pcm.add(captured);
    _recognizer.acceptPcm(captured);
    final sampleCount = captured.length ~/ 2;
    var squareSum = 0.0;
    final view = ByteData.sublistView(captured);
    for (var sample = 0; sample < sampleCount; sample++) {
      final normalized = view.getInt16(sample * 2, Endian.little) / 32768.0;
      squareSum += normalized * normalized;
    }
    final rms = sampleCount == 0 ? 0.0 : math.sqrt(squareSum / sampleCount);
    // A fixed visual gain helps quiet children see actual microphone RMS.
    _amplitudeEvents.add((rms * 4).clamp(0.0, 1.0));
    if (rms >= silenceThreshold) {
      _voiceSamples += sampleCount;
      if (_voiceSamples >= 1920) _heardVoice = true;
      _silenceTimer?.cancel();
      if (_heardVoice) {
        _silenceTimer = Timer(
          silenceDuration,
          () => _requestAutomaticStop(RecordingStopReason.silence, generation),
        );
      }
    } else if (!_heardVoice) {
      _voiceSamples = 0;
    }
    if (_pcm.length >= maximumBytes) {
      _requestAutomaticStop(RecordingStopReason.maxDuration, generation);
    }
  }

  void _requestAutomaticStop(RecordingStopReason reason, int generation) {
    if (!_capturing ||
        _stopRequested ||
        generation != _generation ||
        _disposed) {
      return;
    }
    _stopRequested = true;
    _cancelTimers();
    // Enqueue native stop even if the sheet has no subscriber.
    final halt = _serialize(_haltCapture);
    unawaited(
      halt.catchError((Object error) => _captureError(error, generation)),
    );
    _stopEvents.add(reason);
  }

  void _captureError(Object error, int generation) {
    if (_disposed || generation != _generation || _captureFailure != null) {
      return;
    }
    _captureFailure = error;
    if (_startingCapture) ++_generation;
    _startingCapture = false;
    _stopRequested = true;
    _capturing = false;
    _acceptingPcm = false;
    _cancelTimers();
    _stopEvents.addError(const SpeechEvaluationException('录音中断，请再读一次'));
    unawaited(_serialize(_haltCapture).catchError((Object _) {}));
  }

  Future<void> _haltCapture() => _halting ??= _haltCaptureOnce();

  Future<void> _haltCaptureOnce() async {
    _capturing = false;
    _startingCapture = false;
    _cancelTimers();
    try {
      await _recorder.stop();
    } finally {
      _acceptingPcm = false;
      await _pcmSubscription?.cancel();
      _pcmSubscription = null;
      await _audioSession.restorePlayback();
      if (!_disposed) _amplitudeEvents.add(0);
    }
  }

  @override
  Future<EvaluationResult> stopAndEvaluate(
    String sentenceId,
    String referenceText,
  ) {
    if (_disposed || _sentenceId != sentenceId) {
      return Future.error(const SpeechEvaluationException('没有可评测的录音，请先跟读'));
    }
    final generation = _generation;
    return _evaluation ??= _serialize(() async {
      _checkCurrent(generation);
      final latency = Stopwatch()..start();
      await _haltCapture();
      _checkCurrent(generation);
      if (_captureFailure != null) {
        throw const SpeechEvaluationException('录音中断，请再读一次');
      }
      final raw = _pcm.takeBytes();
      if (raw.length < 3200) {
        await _recognizer.cancel();
        throw const SpeechEvaluationException('录音太短，请读完句子再评分');
      }
      final pcm = raw.length.isOdd ? raw.sublist(0, raw.length - 1) : raw;
      final directory = await _temporaryDirectory();
      _checkCurrent(generation);
      final recordings = Directory('${directory.path}/speech-practice');
      await recordings.create(recursive: true);
      _checkCurrent(generation);
      final file = File(
        '${recordings.path}/recording-${DateTime.now().microsecondsSinceEpoch}-$generation.wav',
      );
      _recordingPath = file.path;
      _recordingFinalized = false;
      await file.writeAsBytes(encodePcm16Wav(pcm), flush: true);
      _checkCurrent(generation);
      final recognized = await _recognizer.finish();
      _checkCurrent(generation);
      latency.stop();
      _recordingFinalized = true;
      return evaluateSpeech(
        referenceText,
        recognized.text,
        recordingPath: _recordingPath,
        inferenceDuration: latency.elapsed,
      );
    });
  }

  void _cancelTimers() {
    _maximumTimer?.cancel();
    _silenceTimer?.cancel();
    _maximumTimer = null;
    _silenceTimer = null;
  }

  Future<void> _clearCapture({required bool deleteFinalRecording}) async {
    _cancelTimers();
    _capturing = false;
    _startingCapture = false;
    _acceptingPcm = false;
    _halting = null;
    _sentenceId = null;
    _evaluation = null;
    _pcm = BytesBuilder(copy: false);
    await _pcmSubscription?.cancel();
    _pcmSubscription = null;
    try {
      await _recorder.cancel();
    } finally {
      try {
        await _recognizer.cancel();
      } finally {
        await _audioSession.restorePlayback();
      }
    }
    if (deleteFinalRecording || !_recordingFinalized) {
      final path = _recordingPath;
      _recordingPath = null;
      _recordingFinalized = false;
      if (path != null) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    }
  }

  @override
  void cancel() {
    if (_disposed) return;
    ++_generation;
    _capturing = false;
    _startingCapture = false;
    _acceptingPcm = false;
    _cancelTimers();
    unawaited(
      _serialize(() => _clearCapture(deleteFinalRecording: false)).catchError(
        (Object error) => debugPrint('SpeechEvaluator: cancel failed: $error'),
      ),
    );
  }

  @override
  Future<bool> openPermissionSettings() => _recorder.openPermissionSettings();

  @override
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    ++_generation;
    _capturing = false;
    _startingCapture = false;
    _acceptingPcm = false;
    _cancelTimers();
    try {
      await _serialize(() => _clearCapture(deleteFinalRecording: true));
    } finally {
      await _focusSubscription.cancel();
      try {
        await _recorder.dispose();
      } finally {
        try {
          await _recognizer.dispose();
        } finally {
          try {
            await _audioSession.dispose();
          } finally {
            await _amplitudeEvents.close();
            await _stopEvents.close();
          }
        }
      }
    }
  }
}

/// Standard uncompressed WAV playable by just_audio and readable offline.
Uint8List encodePcm16Wav(Uint8List pcm, {int sampleRate = 16000}) {
  if (pcm.length.isOdd) throw ArgumentError('PCM16 requires complete samples');
  final result = Uint8List(44 + pcm.length);
  final data = ByteData.sublistView(result);
  result.setRange(0, 4, 'RIFF'.codeUnits);
  data.setUint32(4, 36 + pcm.length, Endian.little);
  result.setRange(8, 12, 'WAVE'.codeUnits);
  result.setRange(12, 16, 'fmt '.codeUnits);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  result.setRange(36, 40, 'data'.codeUnits);
  data.setUint32(40, pcm.length, Endian.little);
  result.setRange(44, result.length, pcm);
  return result;
}

Future<SherpaModelPaths>? _modelAssetPreparation;

Future<SherpaModelPaths> _copyModelAssets() => _modelAssetPreparation ??=
    _copyModelAssetsOnce().catchError((Object error) {
      _modelAssetPreparation = null;
      throw error;
    });

Future<SherpaModelPaths> _copyModelAssetsOnce() async {
  final manifest = jsonDecode(
    await rootBundle.loadString('assets/models/sherpa/model.json'),
  ) as Map<String, dynamic>;
  final fileMetadata = manifest['files'] as Map<String, dynamic>;
  final support = await getApplicationSupportDirectory();
  final directory = Directory('${support.path}/sherpa-en-2023-06-26-int8');
  await directory.create(recursive: true);
  Future<String> copy(String name) async {
    final metadata = fileMetadata[name] as Map<String, dynamic>;
    return materializeSherpaModelAsset(
      name: name,
      metadata: metadata,
      directory: directory,
      loadAsset: (assetName) async {
        final bytes = await rootBundle.load('assets/models/sherpa/$assetName');
        return bytes.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        );
      },
    );
  }

  final encoder = await copy('encoder.int8.onnx');
  final decoder = await copy('decoder.onnx');
  final joiner = await copy('joiner.int8.onnx');
  final tokens = await copy('tokens.txt');
  return SherpaModelPaths(
    encoder: encoder,
    decoder: decoder,
    joiner: joiner,
    tokens: tokens,
  );
}
