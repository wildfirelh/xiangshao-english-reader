import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:english_point_reading/services/speech_evaluator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

void main() {
  late Directory directory;
  late _Recorder recorder;
  late _Recognizer recognizer;
  late _Session session;
  late LocalSherpaSpeechEvaluator evaluator;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('speech-evaluator-test-');
    recorder = _Recorder();
    recognizer = _Recognizer();
    session = _Session();
    evaluator = LocalSherpaSpeechEvaluator(
      recorder: recorder,
      recognizer: recognizer,
      audioSession: session,
      temporaryDirectory: () async => directory,
    );
  });

  tearDown(() async {
    await evaluator.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('recorder delegates Android focus to the shared audio session', () {
    const config = DeviceSpeechRecordingBackend.config;
    expect(config.audioInterruption, AudioInterruptionMode.none);
    expect(config.encoder, AudioEncoder.pcm16bits);
    expect(config.sampleRate, 16000);
    expect(config.numChannels, 1);
  });

  test(
    'cancel pending audio focus activation never opens the microphone',
    () async {
      session.beginGate = Completer<void>();
      final start = evaluator.startRecording('s');
      final failure = expectLater(
        start,
        throwsA(isA<SpeechEvaluationException>()),
      );
      while (session.beginCalls == 0) {
        await _turn();
      }
      evaluator.cancel();
      session.beginGate!.complete();
      await failure;
      await _turn();
      expect(recorder.startCalls, 0);
      expect(session.active, false);
    },
  );

  test(
    'external focus loss during activation aborts before microphone startup',
    () async {
      session.beginGate = Completer<void>();
      final focusFailure = expectLater(
        evaluator.recordingStops.first,
        throwsA(isA<SpeechEvaluationException>()),
      );
      final start = evaluator.startRecording('s');
      final failure = expectLater(
        start,
        throwsA(isA<SpeechEvaluationException>()),
      );
      while (session.beginCalls == 0) {
        await _turn();
      }
      session.events.add(null);
      session.beginGate!.complete();
      await focusFailure;
      await failure;
      await _turn();
      expect(recorder.startCalls, 0);
      expect(session.active, false);
    },
  );

  test(
    'preparing is shared and never requests microphone permission',
    () async {
      final first = evaluator.prepare();
      final second = evaluator.prepare();
      await Future.wait([first, second]);
      expect(recognizer.prepareCalls, 1);
      expect(recorder.permissionCalls, 0);
      expect(recorder.startCalls, 0);
      expect(evaluator.maxRecordingDuration, const Duration(seconds: 15));
      expect(evaluator.silenceDuration, const Duration(milliseconds: 1500));
    },
  );

  for (final permission in [
    MicrophonePermission.denied,
    MicrophonePermission.permanentlyDenied,
  ]) {
    test('permission $permission does not load or open microphone', () async {
      recorder.permission = permission;
      await expectLater(
        evaluator.startRecording('sentence'),
        throwsA(
          isA<SpeechEvaluationException>()
              .having(
                (error) => error.permissionDenied,
                'permissionDenied',
                true,
              )
              .having(
                (error) => error.permanentlyDenied,
                'permanentlyDenied',
                permission == MicrophonePermission.permanentlyDenied,
              ),
        ),
      );
      expect(recorder.startCalls, 0);
      expect(recognizer.prepareCalls, 0);
      expect(await evaluator.openPermissionSettings(), true);
      expect(recorder.settingsCalls, 1);
    });
  }

  test(
    'retry after denied permission opens microphone only after grant',
    () async {
      recorder.permission = MicrophonePermission.denied;
      await expectLater(
        evaluator.startRecording('s'),
        throwsA(isA<SpeechEvaluationException>()),
      );
      recorder.permission = MicrophonePermission.granted;
      await evaluator.startRecording('s');
      expect(recorder.permissionCalls, 2);
      expect(recorder.startCalls, 1);
      expect(session.beginCalls, 1);
    },
  );

  test(
    'real PCM amplitude, WAV bytes and independent recognition result',
    () async {
      final amplitudes = <double>[];
      final subscription = evaluator.amplitudes.listen(amplitudes.add);
      await evaluator.startRecording('s');
      final first = _pcm(3200, 4096);
      final finalTail = _pcm(1600, -4096);
      recorder.emit(first);
      recorder.finalTail = finalTail;
      final result = await evaluator.stopAndEvaluate('s', 'Hello Peter');
      expect(result.recognizedText, 'hello peter');
      expect(result.score, 100);
      expect(result.words, hasLength(2));
      expect(result.hasNativeConfidence, false);
      expect(result.words.every((word) => word.confidence == null), true);
      expect(amplitudes.first, closeTo(0.5, 0.0001));
      expect(amplitudes.last, 0);
      expect(recognizer.received, [first, finalTail]);
      final file = File(result.recordingPath!);
      final bytes = await file.readAsBytes();
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
      final header = ByteData.sublistView(bytes);
      expect(header.getUint32(24, Endian.little), 16000);
      expect(header.getUint16(22, Endian.little), 1);
      expect(header.getUint16(34, Endian.little), 16);
      expect(
        header.getUint32(40, Endian.little),
        first.length + finalTail.length,
      );
      expect(bytes.sublist(44), [...first, ...finalTail]);
      expect(session.restoreCalls, greaterThanOrEqualTo(1));
      await subscription.cancel();
    },
  );

  test(
    'silence gives zero rather than an invented successful transcript',
    () async {
      recognizer.text = '';
      await evaluator.startRecording('s');
      recorder.emit(_pcm(3200, 0));
      final result = await evaluator.stopAndEvaluate('s', 'Hello Peter');
      expect(result.score, 0);
      expect(
        result.words.every((word) => word.status == ScoreStatus.error),
        true,
      );
    },
  );

  test('duplicate stop shares evaluation and native finish', () async {
    await evaluator.startRecording('s');
    recorder.emit(_pcm(3200, 4096));
    final first = evaluator.stopAndEvaluate('s', 'Hello Peter');
    final second = evaluator.stopAndEvaluate('s', 'Hello Peter');
    expect(identical(first, second), true);
    await Future.wait([first, second]);
    expect(recognizer.finishCalls, 1);
    expect(recorder.stopCalls, 1);
  });

  test('too short and wrong sentence are recoverable errors', () async {
    await expectLater(
      evaluator.stopAndEvaluate('other', 'Hi'),
      throwsA(isA<SpeechEvaluationException>()),
    );
    await evaluator.startRecording('s');
    recorder.emit(_pcm(100, 100));
    await expectLater(
      evaluator.stopAndEvaluate('s', 'Hi'),
      throwsA(
        isA<SpeechEvaluationException>().having(
          (error) => error.message,
          'message',
          contains('太短'),
        ),
      ),
    );
    expect(evaluator.recordingPath, null);
    expect(recognizer.finishCalls, 0);
  });

  test(
    'cancel while permission dialog awaits prevents microphone startup',
    () async {
      recorder.permissionGate = Completer<MicrophonePermission>();
      final start = evaluator.startRecording('s');
      final failure = expectLater(
        start,
        throwsA(isA<SpeechEvaluationException>()),
      );
      await _turn();
      evaluator.cancel();
      recorder.permissionGate!.complete(MicrophonePermission.granted);
      await failure;
      await _turn();
      expect(recorder.startCalls, 0);
      expect(recognizer.beginCalls, 0);
    },
  );

  test(
    'cancel pending model load and retry never starts canceled recording',
    () async {
      recognizer.prepareGate = Completer<void>();
      final oldStart = evaluator.startRecording('old');
      final failure = expectLater(
        oldStart,
        throwsA(isA<SpeechEvaluationException>()),
      );
      await _turn();
      evaluator.cancel();
      final restart = evaluator.startRecording('new');
      recognizer.prepareGate!.complete();
      await failure;
      await restart;
      expect(recorder.startCalls, 1);
      expect(recognizer.beginCalls, 1);
      recorder.emit(_pcm(3200, 2048));
      final result = await evaluator.stopAndEvaluate('new', 'Hello Peter');
      expect(result.score, 100);
    },
  );

  test(
    'cancel after asynchronous microphone start immediately releases it',
    () async {
      recorder.startGate = Completer<void>();
      final start = evaluator.startRecording('s');
      final failure = expectLater(
        start,
        throwsA(isA<SpeechEvaluationException>()),
      );
      await _turn();
      evaluator.cancel();
      recorder.startGate!.complete();
      await failure;
      await _turn();
      expect(recorder.isOpen, false);
      expect(session.active, false);
    },
  );

  test('failed preparation is typed and can be retried', () async {
    recognizer.failPreparation = true;
    await expectLater(
      evaluator.prepare(),
      throwsA(isA<SpeechEvaluationException>()),
    );
    recognizer.failPreparation = false;
    await evaluator.startRecording('s');
    expect(recognizer.prepareCalls, 2);
    expect(recorder.isOpen, true);
  });

  test(
    'cancel an in-flight inference prevents late result and deletes WAV',
    () async {
      recognizer.finishGate = Completer<SpeechRecognitionSnapshot>();
      await evaluator.startRecording('s');
      recorder.emit(_pcm(3200, 4096));
      final evaluation = evaluator.stopAndEvaluate('s', 'Hello Peter');
      final failure = expectLater(
        evaluation,
        throwsA(isA<SpeechEvaluationException>()),
      );
      while (recognizer.finishCalls == 0) {
        await _turn();
      }
      final unfinished = evaluator.recordingPath!;
      evaluator.cancel();
      recognizer.finishGate!.complete(
        const SpeechRecognitionSnapshot(text: 'hello peter'),
      );
      await failure;
      await _turn();
      expect(await File(unfinished).exists(), false);
    },
  );

  test(
    'final WAV survives cancel for AB and is removed on retry/dispose',
    () async {
      await evaluator.startRecording('s');
      recorder.emit(_pcm(3200, 4096));
      final result = await evaluator.stopAndEvaluate('s', 'Hello Peter');
      final oldFile = File(result.recordingPath!);
      evaluator.cancel();
      await _turn();
      expect(await oldFile.exists(), true);
      await evaluator.startRecording('s');
      expect(await oldFile.exists(), false);
      recorder.emit(_pcm(3200, 4096));
      final next = await evaluator.stopAndEvaluate('s', 'Hello Peter');
      await evaluator.dispose();
      expect(await File(next.recordingPath!).exists(), false);
      expect(recognizer.disposeCalls, 1);
      expect(recorder.disposeCalls, 1);
    },
  );

  test(
    'microphone error stops capture and reports a recoverable event',
    () async {
      final failureEvent = evaluator.recordingStops.first;
      final failure = expectLater(
        failureEvent,
        throwsA(isA<SpeechEvaluationException>()),
      );
      await evaluator.startRecording('s');
      recorder.errors(StateError('microphone disconnected'));
      await failure;
      await _turn();
      expect(recorder.isOpen, false);
      await expectLater(
        evaluator.stopAndEvaluate('s', 'Hello'),
        throwsA(isA<SpeechEvaluationException>()),
      );
    },
  );

  test(
    'audio focus loss cancels capture rather than scoring paused audio',
    () async {
      final failureEvent = evaluator.recordingStops.first;
      final failure = expectLater(
        failureEvent,
        throwsA(isA<SpeechEvaluationException>()),
      );
      await evaluator.startRecording('s');
      recorder.emit(_pcm(3200, 4096));
      session.events.add(null);
      await failure;
      await _turn();
      expect(recorder.isOpen, false);
      expect(session.active, false);
      await expectLater(
        evaluator.stopAndEvaluate('s', 'Hello Peter'),
        throwsA(isA<SpeechEvaluationException>()),
      );
    },
  );

  test(
    'maximum duration stops microphone even without a sheet subscriber',
    () async {
      await evaluator.dispose();
      evaluator = LocalSherpaSpeechEvaluator(
        recorder: recorder = _Recorder(),
        recognizer: recognizer = _Recognizer(),
        audioSession: session = _Session(),
        temporaryDirectory: () async => directory,
        maxRecordingDuration: const Duration(milliseconds: 30),
      );
      await evaluator.startRecording('s');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(recorder.isOpen, false);
      expect(recorder.stopCalls, 1);
    },
  );

  test(
    'initial silence waits; voice followed by silence stops exactly once',
    () async {
      await evaluator.dispose();
      evaluator = LocalSherpaSpeechEvaluator(
        recorder: recorder = _Recorder(),
        recognizer: recognizer = _Recognizer(),
        audioSession: session = _Session(),
        temporaryDirectory: () async => directory,
        silenceDuration: const Duration(milliseconds: 30),
      );
      final reasons = <RecordingStopReason>[];
      final subscription = evaluator.recordingStops.listen(reasons.add);
      await evaluator.startRecording('s');
      recorder.emit(_pcm(3200, 0));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(reasons, isEmpty);
      recorder.emit(_pcm(3200, 4096));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(reasons, [RecordingStopReason.silence]);
      expect(recorder.isOpen, false);
      final result = await evaluator.stopAndEvaluate('s', 'Hello Peter');
      expect(result.score, 100);
      expect(recorder.stopCalls, 1);
      await subscription.cancel();
    },
  );

  test(
    'PCM duration cap truncates excess input and emits max duration',
    () async {
      final stop = evaluator.recordingStops.first;
      await evaluator.startRecording('s');
      recorder.emit(_pcm(16 * 16000, 4096));
      expect(await stop, RecordingStopReason.maxDuration);
      final result = await evaluator.stopAndEvaluate('s', 'Hello Peter');
      final bytes = await File(result.recordingPath!).readAsBytes();
      expect(bytes.length, 44 + 15 * 16000 * 2);
    },
  );

  test(
    'dispose cancels pending start and makes all future starts typed errors',
    () async {
      recorder.permissionGate = Completer<MicrophonePermission>();
      final start = evaluator.startRecording('s');
      final failure = expectLater(
        start,
        throwsA(isA<SpeechEvaluationException>()),
      );
      await _turn();
      final disposal = evaluator.dispose();
      recorder.permissionGate!.complete(MicrophonePermission.granted);
      await failure;
      await disposal;
      await evaluator.dispose();
      expect(recorder.startCalls, 0);
      expect(recognizer.disposeCalls, 1);
      await expectLater(
        evaluator.startRecording('s'),
        throwsA(isA<SpeechEvaluationException>()),
      );
    },
  );

  test('WAV encoder rejects half a PCM16 sample', () {
    expect(() => encodePcm16Wav(Uint8List(3)), throwsArgumentError);
  });
}

Future<void> _turn() => Future<void>.delayed(const Duration(milliseconds: 5));

Uint8List _pcm(int samples, int value) {
  final bytes = Uint8List(samples * 2);
  final view = ByteData.sublistView(bytes);
  for (var sample = 0; sample < samples; sample++) {
    view.setInt16(sample * 2, value, Endian.little);
  }
  return bytes;
}

class _Recorder implements SpeechRecordingBackend {
  MicrophonePermission permission = MicrophonePermission.granted;
  Completer<MicrophonePermission>? permissionGate;
  Completer<void>? startGate;
  StreamController<Uint8List>? controller;
  Uint8List? finalTail;
  int permissionCalls = 0;
  int settingsCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  bool isOpen = false;

  void emit(Uint8List bytes) => controller!.add(bytes);
  void errors(Object error) => controller!.addError(error);

  @override
  Future<MicrophonePermission> requestPermission() async {
    permissionCalls++;
    return permissionGate == null ? permission : await permissionGate!.future;
  }

  @override
  Future<bool> openPermissionSettings() async {
    settingsCalls++;
    return true;
  }

  @override
  Future<Stream<Uint8List>> startPcmStream() async {
    startCalls++;
    await startGate?.future;
    isOpen = true;
    controller = StreamController<Uint8List>.broadcast(sync: true);
    return controller!.stream;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    if (!isOpen) return;
    final tail = finalTail;
    finalTail = null;
    if (tail != null) controller!.add(tail);
    isOpen = false;
    await controller?.close();
  }

  @override
  Future<void> cancel() async {
    isOpen = false;
    await controller?.close();
    controller = null;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await cancel();
  }
}

class _Recognizer implements SpeechRecognitionBackend {
  String text = 'hello peter';
  bool failPreparation = false;
  Completer<void>? prepareGate;
  Completer<SpeechRecognitionSnapshot>? finishGate;
  int prepareCalls = 0;
  int beginCalls = 0;
  int finishCalls = 0;
  int disposeCalls = 0;
  final received = <Uint8List>[];

  @override
  Future<void> prepare() async {
    prepareCalls++;
    if (failPreparation) throw StateError('missing model');
    await prepareGate?.future;
  }

  @override
  Future<void> begin() async {
    beginCalls++;
    received.clear();
  }

  @override
  void acceptPcm(Uint8List bytes) => received.add(Uint8List.fromList(bytes));

  @override
  Future<SpeechRecognitionSnapshot> finish() async {
    finishCalls++;
    return finishGate == null
        ? SpeechRecognitionSnapshot(text: text)
        : await finishGate!.future;
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async => disposeCalls++;
}

class _Session extends SpeechAudioSession {
  final events = StreamController<void>.broadcast(sync: true);
  bool active = false;
  int beginCalls = 0;
  int restoreCalls = 0;
  Completer<void>? beginGate;

  @override
  Stream<void> get interruptions => events.stream;

  @override
  Future<void> beginRecording() async {
    beginCalls++;
    await beginGate?.future;
    active = true;
  }

  @override
  Future<void> restorePlayback() async {
    restoreCalls++;
    active = false;
  }

  @override
  Future<void> dispose() async {
    await restorePlayback();
    await events.close();
  }
}
