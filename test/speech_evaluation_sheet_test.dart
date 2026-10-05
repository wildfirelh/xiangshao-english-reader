import 'dart:async';

import 'package:english_point_reading/models/textbook.dart';
import 'package:english_point_reading/services/speech_evaluator.dart';
import 'package:english_point_reading/widgets/speech_evaluation_sheet.dart';
import 'package:english_point_reading/widgets/textbook_bottom_bar.dart';
import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _sentence = PointSentence(
  id: 'test-follow',
  text: 'Hello, I am Peter.',
  translation: '你好，我是彼得。',
  audioPath: 'assets/reference.mp3',
  rect: NormalizedRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.3),
);

const _result = EvaluationResult(
  score: 72,
  details: '再练习一下名字',
  recognizedText: 'hello i am teacher',
  recordingPath: '/private/follow-along.wav',
  words: [
    WordEvaluation(word: 'Hello,', status: ScoreStatus.correct, score: 100),
    WordEvaluation(word: 'I', status: ScoreStatus.correct, score: 100),
    WordEvaluation(word: 'am', status: ScoreStatus.warning, score: 72),
    WordEvaluation(word: 'Peter.', status: ScoreStatus.error, score: 0),
  ],
);

class _Evaluator extends SpeechEvaluator {
  final levels = StreamController<double>.broadcast(sync: true);
  final stops = StreamController<RecordingStopReason>.broadcast(sync: true);
  Completer<void>? prepareGate;
  Completer<void>? startGate;
  Completer<EvaluationResult>? resultGate;
  Object? startError;
  Object? evaluateError;
  Object? prepareError;
  EvaluationResult result = _result;
  int prepareCalls = 0;
  int startCalls = 0;
  int evaluateCalls = 0;
  int cancelCalls = 0;
  int settingsCalls = 0;
  String? recordedSentence;
  String? evaluatedText;
  String? _recordingPath;

  @override
  Stream<double> get amplitudes => levels.stream;

  @override
  Stream<RecordingStopReason> get recordingStops => stops.stream;

  @override
  String? get recordingPath => _recordingPath;

  @override
  Future<void> prepare() async {
    prepareCalls++;
    if (prepareError case final error?) throw error;
    await prepareGate?.future;
  }

  @override
  Future<void> startRecording(String sentenceId) async {
    startCalls++;
    recordedSentence = sentenceId;
    _recordingPath = null;
    if (startError case final error?) throw error;
    await startGate?.future;
  }

  @override
  Future<EvaluationResult> stopAndEvaluate(
    String sentenceId,
    String referenceText,
  ) async {
    evaluateCalls++;
    evaluatedText = referenceText;
    if (evaluateError case final error?) throw error;
    final evaluation = await (resultGate?.future ?? Future.value(result));
    _recordingPath = evaluation.recordingPath;
    return evaluation;
  }

  @override
  void cancel() => cancelCalls++;

  @override
  Future<bool> openPermissionSettings() async {
    settingsCalls++;
    return true;
  }

  Future<void> closeStreams() async {
    await levels.close();
    await stops.close();
  }
}

Future<void> _open(
  WidgetTester tester,
  _Evaluator evaluator, {
  Future<void> Function()? playReference,
  Future<void> Function(String)? playRecording,
  Future<void> Function()? stopPlayback,
  TextScaler textScaler = TextScaler.noScaling,
  Brightness brightness = Brightness.light,
  bool disableAnimations = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF356A58),
          brightness: brightness,
        ),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: textScaler,
          disableAnimations: disableAnimations,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (context) => SpeechEvaluationSheet(
                  sentence: _sentence,
                  evaluator: evaluator,
                  onPlayReference: playReference ?? () async {},
                  onPlayRecording: playRecording ?? (_) async {},
                  onStopPlayback: stopPlayback,
                ),
              ),
              child: const Text('打开跟读'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开跟读'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 30));
}

Future<void> _finishAttempt(WidgetTester tester) async {
  await _tap(tester, 'speech-record-button');
  await _tap(tester, 'speech-record-button');
}

void main() {
  late _Evaluator evaluator;

  setUp(() => evaluator = _Evaluator());
  tearDown(() async => evaluator.closeStreams());

  testWidgets('prepares offline model without starting microphone permission', (
    tester,
  ) async {
    await _open(tester, evaluator);
    expect(evaluator.prepareCalls, 1);
    expect(evaluator.startCalls, 0);
    expect(find.text(_sentence.text), findsOneWidget);
    expect(find.text('点击麦克风，开始跟读'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.byKey(const Key('speech-recording-button')),
    );
    expect(button.onPressed, isNull);
    await _tap(tester, 'speech-close');
  });

  testWidgets('permission denied is explained and can be requested again', (
    tester,
  ) async {
    evaluator.startError = const SpeechEvaluationException(
      '请允许麦克风权限后再开始跟读',
      permissionDenied: true,
    );
    await _open(tester, evaluator);
    await _tap(tester, 'speech-record-button');
    expect(find.text('请允许麦克风权限后再开始跟读'), findsOneWidget);
    expect(find.byKey(const Key('speech-waveform')), findsNothing);
    expect(evaluator.evaluateCalls, 0);
    evaluator.startError = null;
    await _tap(tester, 'speech-record-button');
    expect(evaluator.startCalls, 2);
    expect(find.byKey(const Key('speech-waveform')), findsOneWidget);
    await _tap(tester, 'speech-close');
  });

  testWidgets(
    'permanent permission denial offers settings without hidden retry',
    (tester) async {
      evaluator.startError = const SpeechEvaluationException(
        '麦克风权限已关闭，请在设置中开启',
        permissionDenied: true,
        permanentlyDenied: true,
      );
      await _open(tester, evaluator);
      await _tap(tester, 'speech-record-button');
      expect(find.byKey(const Key('speech-open-settings')), findsOneWidget);
      await _tap(tester, 'speech-open-settings');
      expect(evaluator.settingsCalls, 1);
      expect(evaluator.startCalls, 1);
      expect(evaluator.evaluateCalls, 0);
      await _tap(tester, 'speech-close');
    },
  );

  testWidgets('closing while preparing does not install late model state', (
    tester,
  ) async {
    evaluator.prepareGate = Completer<void>();
    await _open(tester, evaluator);
    expect(find.text('正在准备离线跟读…'), findsOneWidget);
    await _tap(tester, 'speech-close');
    evaluator.prepareGate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(SpeechEvaluationSheet), findsNothing);
    expect(evaluator.startCalls, 0);
    expect(evaluator.cancelCalls, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending start disables repeated recording taps', (tester) async {
    evaluator.startGate = Completer<void>();
    await _open(tester, evaluator);
    await _tap(tester, 'speech-record-button');
    await _tap(tester, 'speech-record-button');
    expect(evaluator.startCalls, 1);
    evaluator.startGate!.complete();
    await tester.pump();
    await _tap(tester, 'speech-close');
  });

  testWidgets(
    'recording follows actual microphone levels then shows word scores',
    (tester) async {
      var stopCalls = 0;
      await _open(tester, evaluator, stopPlayback: () async => stopCalls++);
      await _tap(tester, 'speech-record-button');
      expect(evaluator.startCalls, 1);
      expect(evaluator.recordedSentence, _sentence.id);
      expect(stopCalls, 1);
      expect(find.byKey(const Key('speech-waveform')), findsOneWidget);
      evaluator.levels.add(0.8);
      await tester.pump();
      final wave = tester.widget<Container>(
        find.byKey(const ValueKey('speech-wave-22')),
      );
      expect(wave.constraints?.maxHeight, closeTo(40.8, 0.01));
      await _tap(tester, 'speech-record-button');
      expect(evaluator.evaluatedText, _sentence.text);
      expect(evaluator.evaluateCalls, 1);
      expect(find.text('72 分'), findsOneWidget);
      expect(find.text('Good Job!'), findsOneWidget);
      expect(find.text('根据识别文本与完整度反馈'), findsOneWidget);
      expect(find.byKey(const Key('speech-word-0-correct')), findsOneWidget);
      expect(find.byKey(const Key('speech-word-2-warning')), findsOneWidget);
      expect(find.byKey(const Key('speech-word-3-error')), findsOneWidget);
      expect(find.byKey(const Key('speech-waveform')), findsNothing);
      expect(tester.takeException(), isNull);
      await _tap(tester, 'speech-finish-button');
    },
  );

  testWidgets(
    'reference, own recording and red word use exclusive audio callbacks',
    (tester) async {
      final playback = <String>[];
      await _open(
        tester,
        evaluator,
        stopPlayback: () async => playback.add('stop'),
        playReference: () async => playback.add('reference'),
        playRecording: (path) async => playback.add(path),
      );
      await _finishAttempt(tester);
      playback.clear();
      await _tap(tester, 'speech-reference-button');
      await _tap(tester, 'speech-recording-button');
      await _tap(tester, 'speech-word-3-error');
      expect(playback, [
        'stop',
        'reference',
        'stop',
        '/private/follow-along.wav',
        'stop',
        'reference',
      ]);
      await _tap(tester, 'speech-finish-button');
    },
  );

  for (final reason in RecordingStopReason.values) {
    testWidgets('automatically evaluates $reason exactly once', (tester) async {
      await _open(tester, evaluator);
      await _tap(tester, 'speech-record-button');
      evaluator.stops.add(reason);
      evaluator.stops.add(reason);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(evaluator.evaluateCalls, 1);
      expect(find.text('72 分'), findsOneWidget);
      await _tap(tester, 'speech-finish-button');
    });
  }

  testWidgets(
    '15 second UI protection stops recording even without stop signal',
    (tester) async {
      await _open(tester, evaluator);
      await _tap(tester, 'speech-record-button');
      await tester.pump(const Duration(seconds: 15));
      await tester.pump();
      expect(evaluator.evaluateCalls, 1);
      expect(find.text('72 分'), findsOneWidget);
      await _tap(tester, 'speech-finish-button');
    },
  );

  testWidgets('record stream failure cancels capture and allows retry', (
    tester,
  ) async {
    await _open(tester, evaluator);
    await _tap(tester, 'speech-record-button');
    evaluator.stops.addError(StateError('capture failed'));
    await tester.pump();
    expect(evaluator.cancelCalls, greaterThan(0));
    expect(evaluator.evaluateCalls, 0);
    expect(find.text('录音中断，请再读一次'), findsOneWidget);
    await _tap(tester, 'speech-record-button');
    expect(evaluator.startCalls, 2);
    await _tap(tester, 'speech-close');
  });

  testWidgets('no voice error is recoverable without displaying stale result', (
    tester,
  ) async {
    evaluator.evaluateError = StateError('no voice');
    await _open(tester, evaluator);
    await _finishAttempt(tester);
    expect(find.text('暂时无法完成跟读，请再试一次'), findsOneWidget);
    expect(find.byKey(const Key('speech-score')), findsNothing);
    evaluator.evaluateError = null;
    await _finishAttempt(tester);
    expect(find.text('72 分'), findsOneWidget);
    expect(find.byKey(const Key('speech-error')), findsNothing);
    await _tap(tester, 'speech-finish-button');
  });

  testWidgets('close during pending microphone start cancels late work', (
    tester,
  ) async {
    evaluator.startGate = Completer<void>();
    await _open(tester, evaluator);
    await _tap(tester, 'speech-record-button');
    expect(find.text('正在开启麦克风…'), findsOneWidget);
    await _tap(tester, 'speech-close');
    evaluator.startGate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(SpeechEvaluationSheet), findsNothing);
    expect(evaluator.cancelCalls, greaterThan(0));
    expect(evaluator.evaluateCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'system back immediately cancels microphone before close animation',
    (tester) async {
      await _open(tester, evaluator);
      await _tap(tester, 'speech-record-button');
      final context = tester.element(find.byType(SpeechEvaluationSheet));
      Navigator.of(context).pop();
      expect(evaluator.cancelCalls, greaterThan(0));
      await tester.pumpAndSettle();
      expect(find.byType(SpeechEvaluationSheet), findsNothing);
      expect(evaluator.evaluateCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('prepare error has explicit offline preparation retry', (
    tester,
  ) async {
    evaluator.prepareError = const SpeechEvaluationException('离线资源暂时无法打开');
    await _open(tester, evaluator);
    expect(find.text('离线资源暂时无法打开'), findsOneWidget);
    expect(find.byKey(const Key('speech-retry-prepare')), findsOneWidget);
    expect(evaluator.startCalls, 0);
    evaluator.prepareError = null;
    await _tap(tester, 'speech-retry-prepare');
    expect(evaluator.prepareCalls, 2);
    expect(find.text('点击麦克风，开始跟读'), findsOneWidget);
    expect(find.byKey(const Key('speech-error')), findsNothing);
    await _tap(tester, 'speech-close');
  });

  testWidgets('background cancels recording while permission dialog does not', (
    tester,
  ) async {
    evaluator.startGate = Completer<void>();
    await _open(tester, evaluator);
    await _tap(tester, 'speech-record-button');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(evaluator.cancelCalls, 0);
    evaluator.startGate!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.byKey(const Key('speech-waveform')), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(evaluator.cancelCalls, greaterThan(0));
    expect(find.text('录音已暂停，请再读一次'), findsOneWidget);
    expect(find.byKey(const Key('speech-waveform')), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _tap(tester, 'speech-close');
  });

  testWidgets('background during inference discards late word score', (
    tester,
  ) async {
    evaluator.resultGate = Completer<EvaluationResult>();
    await _open(tester, evaluator);
    await _finishAttempt(tester);
    expect(find.text('正在听你的发音…'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    evaluator.resultGate!.complete(_result);
    await tester.pump();
    expect(find.byKey(const Key('speech-score')), findsNothing);
    expect(find.text('录音已暂停，请再读一次'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _tap(tester, 'speech-close');
  });

  testWidgets('retry starts fresh capture and removes previous score', (
    tester,
  ) async {
    await _open(tester, evaluator);
    await _finishAttempt(tester);
    await _tap(tester, 'speech-retry');
    expect(evaluator.startCalls, 2);
    expect(find.byKey(const Key('speech-score')), findsNothing);
    expect(find.byKey(const Key('speech-waveform')), findsOneWidget);
    await _tap(tester, 'speech-close');
  });

  testWidgets(
    'narrow dark sheet with large text remains scrollable and closable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _open(
        tester,
        evaluator,
        textScaler: const TextScaler.linear(2),
        brightness: Brightness.dark,
      );
      await _finishAttempt(tester);
      expect(tester.takeException(), isNull);
      await _tap(tester, 'speech-recording-button');
      await _tap(tester, 'speech-finish-button');
      await tester.pumpAndSettle();
      expect(find.byType(SpeechEvaluationSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('bottom bar delegates follow-along to supplied callback', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: TextbookBottomBar(
            currentMode: PlayMode.single,
            onModeChanged: (_) {},
            isTranslationEnabled: false,
            onTranslationChanged: (_) {},
            activeSentence: _sentence,
            onFollowAlong: () => calls++,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('跟读评测'));
    await tester.pump();
    expect(calls, 1);
    expect(find.text('功能正在开发中，敬请期待'), findsNothing);
  });

  testWidgets('whole reader unmount defers playback notification safely', (
    tester,
  ) async {
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (readerContext, refreshReader) => MaterialApp(
          home: Scaffold(
            body: SpeechEvaluationSheet(
              sentence: _sentence,
              evaluator: evaluator,
              onPlayReference: () async {},
              onPlayRecording: (_) async {},
              onStopPlayback: () async {
                if (readerContext.mounted) refreshReader(() {});
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(evaluator.cancelCalls, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}
