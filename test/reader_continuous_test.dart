import 'dart:async';

import 'package:english_point_reading/models/textbook.dart';
import 'package:english_point_reading/screens/textbook_reader_screen.dart';
import 'package:english_point_reading/services/audio_interruption_source.dart';
import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:english_point_reading/services/speech_evaluator.dart';
import 'package:english_point_reading/widgets/interactive_textbook_page.dart';
import 'package:english_point_reading/widgets/speech_evaluation_sheet.dart';
import 'package:english_point_reading/widgets/textbook_bottom_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_player_service_test.dart' show FakeAudioBackend;
import 'audio_interruptions_test.dart' show FakeInterruptions;
import 'helpers/memory_reading_progress_store.dart';

const _one = PointSentence(
  id: 'one',
  bubbleId: 'bubble-one',
  text: 'Hello!',
  translation: '你好！',
  audioPath: 'assets/one.mp3',
  rect: NormalizedRect(left: 0.2, top: 0.32, right: 0.8, bottom: 0.4),
);
const _two = PointSentence(
  id: 'two',
  bubbleId: 'bubble-one',
  text: 'My name is Lingling.',
  translation: '我叫玲玲。',
  audioPath: 'assets/two.mp3',
  rect: NormalizedRect(left: 0.2, top: 0.48, right: 0.8, bottom: 0.56),
);
const _three = PointSentence(
  id: 'three',
  bubbleId: 'bubble-two',
  text: 'How old are you?',
  audioPath: 'assets/three.mp3',
  rect: NormalizedRect(left: 0.2, top: 0.32, right: 0.8, bottom: 0.4),
);
const _four = PointSentence(
  id: 'four',
  bubbleId: 'bubble-three',
  text: "I'm nine.",
  audioPath: 'assets/four.mp3',
  rect: NormalizedRect(left: 0.2, top: 0.48, right: 0.8, bottom: 0.56),
);
const _firstBubble = DialogueBubble(
  id: 'bubble-one',
  text: 'Hello! My name is Lingling.',
  translation: '你好！我叫玲玲。',
  audioPath: 'assets/bubble-one.mp3',
  rect: NormalizedRect(left: 0.15, top: 0.3, right: 0.85, bottom: 0.62),
  sentenceIds: ['one', 'two'],
);
const _secondBubble = DialogueBubble(
  id: 'bubble-two',
  text: 'How old are you?',
  audioPath: 'assets/bubble-two.mp3',
  rect: NormalizedRect(left: 0.15, top: 0.3, right: 0.85, bottom: 0.42),
  sentenceIds: ['three'],
);
const _thirdBubble = DialogueBubble(
  id: 'bubble-three',
  text: "I'm nine.",
  audioPath: 'assets/bubble-three.mp3',
  rect: NormalizedRect(left: 0.15, top: 0.46, right: 0.85, bottom: 0.62),
  sentenceIds: ['four'],
);
const _firstPage = TextbookPage(
  pageIndex: 8,
  imagePath: '',
  // The flat sentence list does not determine continuous bubble order.
  sentences: [_two, _one],
  bubbles: [_firstBubble],
);

Future<void> tapPageAt(WidgetTester tester, Offset normalized) async {
  final finder = find.byType(InteractiveTextbookPage).first;
  final bounds = tester.getRect(finder);
  final image = containedImageRect(bounds.size, const Size(3, 4));
  await tester.tapAt(
    bounds.topLeft +
        image.topLeft +
        Offset(image.width * normalized.dx, image.height * normalized.dy),
  );
}

void main() {
  Future<AudioPlayerService> open(
    WidgetTester tester,
    FakeAudioBackend backend, {
    bool emptyPage = false,
    bool reduceMotion = false,
    bool startPlayback = true,
    PlayMode mode = PlayMode.fullPage,
    TextbookPage firstPage = _firstPage,
    AudioInterruptionSource? interruptions,
    MemoryReadingProgressStore? progress,
  }) async {
    final service = AudioPlayerService(
      backend: backend,
      interruptionSource: interruptions,
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: reduceMotion),
            child: TextbookReaderScreen(
              speechEvaluatorFactory: () => MockSpeechEvaluator(),
              audioPlayerService: service,
              progressStore: progress ?? MemoryReadingProgressStore(),
              book: Textbook(
                bookId: 'test',
                title: 'Test',
                pages: [
                  firstPage,
                  if (emptyPage)
                    const TextbookPage(
                      pageIndex: 9,
                      imagePath: '',
                      sentences: [],
                    ),
                  const TextbookPage(
                    pageIndex: 10,
                    imagePath: '',
                    sentences: [_four, _three],
                    bubbles: [_secondBubble, _thirdBubble],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (startPlayback) {
      await tester.tap(find.byKey(const Key('playback-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('mode-option-${mode.name}')));
      await tester.pumpAndSettle();
      if (mode == PlayMode.sequential) {
        // Start at the last child so one completion begins the page turn.
        await tapPageAt(tester, const Offset(0.5, 0.52));
        await tester.pumpAndSettle();
      }
    }
    return service;
  }

  Future<void> chooseMode(WidgetTester tester, PlayMode mode) async {
    await tester.tap(find.byKey(const Key('playback-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('mode-option-${mode.name}')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'long press during automatic animation opens exact follow along',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = await open(tester, backend, mode: PlayMode.sequential);
      backend.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final canvas = find.byType(InteractiveTextbookPage).first;
      final bounds = tester.getRect(canvas);
      final image = containedImageRect(bounds.size, const Size(3, 4));
      final location =
          bounds.topLeft +
          image.topLeft +
          Offset(image.width * 0.75, image.height * 0.36);
      await tester.longPressAt(location);
      await tester.pumpAndSettle();
      final sheet = tester.widget<SpeechEvaluationSheet>(
        find.byType(SpeechEvaluationSheet),
      );
      expect(sheet.sentence.id, 'one');
      expect(service.isPlaying, isFalse);
      expect(find.text('第 1 / 2 页'), findsOneWidget);
      await tester.tap(find.byKey(const Key('speech-close')));
      await tester.pumpAndSettle();
      expect(service.isPlaying, isFalse);
      expect(backend.playedAssets.last, 'assets/two.mp3');
    },
  );

  testWidgets('sequential mode waits for a sentence with the requested hint', (
    tester,
  ) async {
    final backend = FakeAudioBackend();
    final service = await open(tester, backend, startPlayback: false);
    await chooseMode(tester, PlayMode.sequential);
    expect(service.currentMode, PlayMode.sequential);
    expect(service.isPlaying, isFalse);
    expect(backend.playedAssets, isEmpty);
    expect(find.text('请点击任意文本，从此处开始顺序连读'), findsOneWidget);
    await tester.tap(find.byKey(const Key('playback-toggle')));
    await tester.pump();
    expect(backend.playedAssets, isEmpty);
    await tapPageAt(tester, const Offset(0.5, 0.52));
    await tester.pumpAndSettle();
    expect(service.currentMode, PlayMode.sequential);
    expect(service.currentSentenceId, 'two');
    expect(backend.playedAssets, ['assets/two.mp3']);
  });

  testWidgets(
    'full-page mode starts at the first bubble and stops at page end',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = await open(tester, backend, startPlayback: false);
      await tapPageAt(tester, const Offset(0.5, 0.52));
      await tester.pumpAndSettle();
      expect(service.currentSentenceId, 'two');
      await chooseMode(tester, PlayMode.fullPage);
      expect(service.currentBubbleId, 'bubble-one');
      expect(backend.playedAssets, ['assets/two.mp3', 'assets/bubble-one.mp3']);
      backend.complete();
      await tester.pumpAndSettle();
      expect(find.text('第 1 / 2 页'), findsOneWidget);
      expect(service.currentMode, PlayMode.fullPage);
      expect(service.isPlaying, isFalse);
      expect(find.byKey(const Key('bubble-highlight')), findsNothing);
      await tester.tap(find.byKey(const Key('playback-toggle')));
      await tester.pumpAndSettle();
      expect(service.currentBubbleId, 'bubble-one');
      expect(backend.playedAssets.last, 'assets/bubble-one.mp3');
    },
  );

  testWidgets('switching playing bubble to sequential starts its first child', (
    tester,
  ) async {
    final backend = FakeAudioBackend();
    final service = await open(tester, backend);
    await chooseMode(tester, PlayMode.sequential);
    expect(service.currentMode, PlayMode.sequential);
    expect(service.currentSentenceId, 'one');
    expect(backend.playedAssets, ['assets/bubble-one.mp3', 'assets/one.mp3']);
    backend.complete();
    await tester.pumpAndSettle();
    expect(service.currentSentenceId, 'two');
    expect(backend.playedAssets.last, 'assets/two.mp3');
  });

  testWidgets('switching a ducked bubble to sequential keeps the child quiet', (
    tester,
  ) async {
    final backend = FakeAudioBackend()..volume = 0.6;
    final interruptions = FakeInterruptions();
    final service = await open(tester, backend, interruptions: interruptions);
    interruptions.beginDuck();
    await tester.pump();
    expect(backend.volume, 0.25);
    await chooseMode(tester, PlayMode.sequential);
    expect(service.currentMode, PlayMode.sequential);
    expect(service.currentSentenceId, 'one');
    expect(find.text('顺序连读'), findsOneWidget);
    expect(backend.playedAssets, ['assets/bubble-one.mp3', 'assets/one.mp3']);
    expect(backend.playedVolumes, [0.6, 0.25]);
    expect(backend.volume, 0.25);
    interruptions.endDuck();
    for (var step = 0; step < 6; step++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(backend.volume, closeTo(0.6, 0.0001));
  });

  testWidgets('sequential replay and choosing a new sentence keep the mode', (
    tester,
  ) async {
    final backend = FakeAudioBackend();
    final service = await open(tester, backend, mode: PlayMode.sequential);
    await tester.tap(find.byTooltip('重听'));
    await tester.pumpAndSettle();
    expect(service.currentMode, PlayMode.sequential);
    expect(service.currentSentenceId, 'two');
    await tapPageAt(tester, const Offset(0.5, 0.36));
    await tester.pumpAndSettle();
    expect(service.currentMode, PlayMode.sequential);
    expect(service.currentSentenceId, 'one');
    backend.complete();
    await tester.pumpAndSettle();
    expect(service.currentSentenceId, 'two');
    expect(backend.playedAssets, [
      'assets/two.mp3',
      'assets/two.mp3',
      'assets/one.mp3',
      'assets/two.mp3',
    ]);
  });

  for (final mode in PlayMode.values) {
    testWidgets('finger drag stops ${mode.name} before the page midpoint', (
      tester,
    ) async {
      final backend = FakeAudioBackend();
      final service = await open(
        tester,
        backend,
        startPlayback: mode != PlayMode.single,
        mode: mode,
      );
      if (mode == PlayMode.single) {
        await tapPageAt(tester, const Offset(0.5, 0.36));
        await tester.pumpAndSettle();
      }
      expect(service.isPlaying, isTrue);
      final played = List<String>.of(backend.playedAssets);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PageView)),
      );
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      expect(find.text('第 1 / 2 页'), findsOneWidget);
      expect(service.isPlaying, isFalse);
      expect(service.currentSentenceId, isNull);
      expect(service.currentBubbleId, isNull);
      expect(find.byKey(const Key('sentence-highlight')), findsNothing);
      expect(find.byKey(const Key('bubble-highlight')), findsNothing);
      backend.complete();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(backend.playedAssets, played);
      expect(service.isPlaying, isFalse);
    });
  }

  testWidgets('drag cancels loading so late load and completion cannot play', (
    tester,
  ) async {
    final backend = FakeAudioBackend()..delayFirstLoad = Completer<void>();
    final service = await open(tester, backend, startPlayback: false);
    await tester.tap(find.byKey(const Key('playback-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mode-option-fullPage')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(service.isLoading, isTrue);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(service.isLoading, isFalse);
    expect(service.currentBubbleId, isNull);
    backend.delayFirstLoad!.complete();
    backend.complete();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(backend.playedAssets, isEmpty);
    expect(service.isPlaying, isFalse);
    expect(find.text('第 1 / 2 页'), findsOneWidget);
  });

  for (final mode in [PlayMode.fullPage, PlayMode.sequential]) {
    testWidgets('${mode.name} pause keeps selection and resume reuses clip', (
      tester,
    ) async {
      final backend = FakeAudioBackend();
      final service = await open(tester, backend, mode: mode);
      final assets = List<String>.of(backend.loadedAssets);
      final sentence = service.currentSentenceId;
      final bubble = service.currentBubbleId;
      await tester.tap(find.byKey(const Key('playback-toggle')));
      await tester.pumpAndSettle();
      expect(service.isPlaying, isFalse);
      expect(service.canResume, isTrue);
      expect(service.currentSentenceId, sentence);
      expect(service.currentBubbleId, bubble);
      backend.complete();
      await tester.pumpAndSettle();
      expect(find.text('第 1 / 2 页'), findsOneWidget);
      await tester.tap(find.byKey(const Key('playback-toggle')));
      await tester.pumpAndSettle();
      expect(service.isPlaying, isTrue);
      expect(backend.loadedAssets, assets);
      expect(service.currentSentenceId, sentence);
      expect(service.currentBubbleId, bubble);
    });
  }

  testWidgets('pause during auto-turn preserves the next page for resume', (
    tester,
  ) async {
    final backend = FakeAudioBackend();
    final service = await open(tester, backend, mode: PlayMode.sequential);
    backend.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.byKey(const Key('playback-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('第 1 / 2 页'), findsOneWidget);
    expect(service.isPlaying, isFalse);
    expect(backend.playedAssets, ['assets/two.mp3']);
    backend.complete();
    await tester.pumpAndSettle();
    expect(backend.playedAssets, ['assets/two.mp3']);
    await tester.tap(find.byKey(const Key('playback-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('第 2 / 2 页'), findsOneWidget);
    expect(service.currentSentenceId, 'three');
    expect(backend.playedAssets, ['assets/two.mp3', 'assets/three.mp3']);
  });

  testWidgets(
    'backgrounding auto-turn waits for explicit resume at next page',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = await open(tester, backend, mode: PlayMode.sequential);
      backend.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(find.text('第 1 / 2 页'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(service.isPlaying, isFalse);
      expect(backend.playedAssets, ['assets/two.mp3']);
      await tester.tap(find.byKey(const Key('playback-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('第 2 / 2 页'), findsOneWidget);
      expect(service.currentSentenceId, 'three');
      expect(backend.playedAssets, ['assets/two.mp3', 'assets/three.mp3']);
    },
  );

  testWidgets(
    'focus pause during auto-turn waits for explicit next-page resume',
    (tester) async {
      final backend = FakeAudioBackend();
      final interruptions = FakeInterruptions();
      final service = await open(
        tester,
        backend,
        mode: PlayMode.sequential,
        interruptions: interruptions,
      );
      backend.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      interruptions.beginPause();
      await tester.pumpAndSettle();
      expect(find.text('第 1 / 2 页'), findsOneWidget);
      expect(service.isPlaying, isFalse);
      expect(backend.playedAssets, ['assets/two.mp3']);
      interruptions.endPause();
      await tester.pumpAndSettle();
      expect(backend.playedAssets, ['assets/two.mp3']);
      await tester.tap(find.byKey(const Key('playback-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('第 2 / 2 页'), findsOneWidget);
      expect(service.currentSentenceId, 'three');
      expect(backend.playedAssets, ['assets/two.mp3', 'assets/three.mp3']);
    },
  );

  testWidgets('choosing sequential while an asset loads cancels it and waits', (
    tester,
  ) async {
    final backend = FakeAudioBackend()..delayFirstLoad = Completer<void>();
    final service = await open(tester, backend, startPlayback: false);
    await tester.tap(find.byKey(const Key('playback-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mode-option-fullPage')));
    await tester.pumpAndSettle();
    expect(service.isLoading, isTrue);
    await chooseMode(tester, PlayMode.sequential);
    expect(service.currentMode, PlayMode.sequential);
    expect(service.isLoading, isFalse);
    expect(service.currentBubbleId, isNull);
    expect(service.currentSentenceId, isNull);
    expect(find.text('请点击任意文本，从此处开始顺序连读'), findsOneWidget);
    backend.delayFirstLoad!.complete();
    await tester.pumpAndSettle();
    expect(backend.playedAssets, isEmpty);
    await tapPageAt(tester, const Offset(0.5, 0.52));
    await tester.pumpAndSettle();
    expect(service.currentSentenceId, 'two');
    expect(backend.playedAssets, ['assets/two.mp3']);
  });

  testWidgets(
    'full-page selection starts complete first bubble audio and translation',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = await open(tester, backend);
      expect(service.currentMode, PlayMode.fullPage);
      expect(service.currentBubbleId, 'bubble-one');
      expect(service.currentSentenceId, isNull);
      expect(backend.playedAssets, ['assets/bubble-one.mp3']);
      expect(find.text('整页连读'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(TextbookBottomBar),
          matching: find.text('Hello! My name is Lingling.'),
        ),
        findsOneWidget,
      );
      expect(find.text('你好！我叫玲玲。'), findsOneWidget);
      expect(find.byKey(const Key('bubble-highlight')), findsOneWidget);
      expect(find.byKey(const Key('sentence-highlight')), findsNothing);
    },
  );

  testWidgets(
    'precise second sentence tap immediately switches to single and cancels continuation',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = await open(tester, backend);
      final stops = backend.stopCount;
      await tapPageAt(tester, const Offset(0.5, 0.52));
      expect(service.currentMode, PlayMode.single);
      expect(backend.stopCount, greaterThan(stops));
      await tester.pumpAndSettle();
      expect(find.text('单句点读'), findsOneWidget);
      expect(service.currentSentenceId, 'two');
      expect(service.currentBubbleId, isNull);
      expect(backend.playedAssets, ['assets/bubble-one.mp3', 'assets/two.mp3']);
      expect(find.byKey(const Key('bubble-highlight')), findsNothing);
      expect(find.byKey(const Key('sentence-highlight')), findsOneWidget);
      backend.complete();
      await tester.pumpAndSettle();
      expect(find.text('第 1 / 2 页'), findsOneWidget);
      expect(service.isPlaying, isFalse);
      expect(service.currentSentenceId, isNull);
      expect(backend.playedAssets, ['assets/bubble-one.mp3', 'assets/two.mp3']);
    },
  );

  testWidgets(
    'bubble whitespace tap selects first child as a single sentence',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = await open(tester, backend);
      await tapPageAt(tester, const Offset(0.5, 0.44));
      await tester.pumpAndSettle();
      expect(service.currentMode, PlayMode.single);
      expect(service.currentSentenceId, 'one');
      expect(backend.playedAssets.last, 'assets/one.mp3');
    },
  );

  testWidgets('a tap during bubble loading cancels it before it can start', (
    tester,
  ) async {
    final backend = FakeAudioBackend()..delayFirstLoad = Completer<void>();
    final service = await open(tester, backend, startPlayback: false);
    await tester.tap(find.byKey(const Key('playback-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mode-option-fullPage')));
    await tester.pump();
    expect(backend.loadedAssets, ['assets/bubble-one.mp3']);
    await tapPageAt(tester, const Offset(0.5, 0.52));
    expect(service.currentMode, PlayMode.single);
    expect(service.currentSentenceId, 'two');
    backend.delayFirstLoad!.complete();
    await tester.pumpAndSettle();
    expect(backend.playedAssets, ['assets/two.mp3']);
    backend.complete();
    await tester.pumpAndSettle();
    expect(find.text('第 1 / 2 页'), findsOneWidget);
  });

  testWidgets(
    'a missing sentence audio still cancels continuous mode immediately',
    (tester) async {
      const unavailableSentence = PointSentence(
        id: 'one',
        text: 'Hello!',
        audioPath: '',
        rect: NormalizedRect(left: 0.2, top: 0.32, right: 0.8, bottom: 0.4),
      );
      final backend = FakeAudioBackend();
      final service = await open(
        tester,
        backend,
        firstPage: const TextbookPage(
          pageIndex: 8,
          imagePath: '',
          sentences: [unavailableSentence, _two],
          bubbles: [_firstBubble],
        ),
      );
      await tapPageAt(tester, const Offset(0.5, 0.36));
      expect(service.currentMode, PlayMode.single);
      await tester.pumpAndSettle();
      expect(find.text('单句点读'), findsOneWidget);
      expect(find.byKey(const Key('sentence-highlight')), findsOneWidget);
      expect(find.text('音频尚未导入，请添加教材音频'), findsOneWidget);
      expect(service.currentBubbleId, isNull);
      backend.complete();
      await tester.pumpAndSettle();
      expect(find.text('第 1 / 2 页'), findsOneWidget);
      expect(backend.playedAssets, ['assets/bubble-one.mp3']);
    },
  );

  testWidgets(
    'tapping a paused bubble chooses and reads the precise sentence',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = await open(tester, backend);
      await service.pause();
      await tester.pumpAndSettle();
      expect(service.isPlaying, isFalse);
      expect(service.currentBubbleId, 'bubble-one');
      await tapPageAt(tester, const Offset(0.5, 0.52));
      await tester.pumpAndSettle();
      expect(service.currentMode, PlayMode.single);
      expect(service.currentSentenceId, 'two');
      expect(backend.playedAssets.last, 'assets/two.mp3');
    },
  );

  for (final elapsed in [20, 50]) {
    testWidgets(
      'sentence tap wins during manual next-page animation at ${elapsed}ms',
      (tester) async {
        final backend = FakeAudioBackend();
        final service = await open(tester, backend, startPlayback: false);
        await tester.tap(find.text('下一页'));
        await tester.pump();
        await tester.pump(Duration(milliseconds: elapsed));
        expect(
          find.text(elapsed == 20 ? '第 1 / 2 页' : '第 2 / 2 页'),
          findsOneWidget,
        );
        // The trailing portion of the old page remains visible after the midpoint.
        // Hit its actual second sentence rather than invoking a synthetic callback.
        await tapPageAt(tester, const Offset(0.75, 0.52));
        await tester.pumpAndSettle();
        expect(find.text('第 1 / 2 页'), findsOneWidget);
        expect(service.currentMode, PlayMode.single);
        expect(service.currentSentenceId, 'two');
        expect(backend.playedAssets, ['assets/two.mp3']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'dragging a sentence during manual page animation does not start point reading',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = await open(tester, backend, startPlayback: false);
      await tester.tap(find.text('下一页'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      final bounds = tester.getRect(find.byType(InteractiveTextbookPage).first);
      final image = containedImageRect(bounds.size, const Size(3, 4));
      final down =
          bounds.topLeft +
          image.topLeft +
          Offset(image.width * 0.75, image.height * 0.52);
      final gesture = await tester.startGesture(down);
      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump();
      // Returning near the down position still counts as a drag, not a tap.
      await gesture.moveTo(down);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(backend.playedAssets, isEmpty);
      expect(service.currentSentenceId, isNull);
    },
  );

  testWidgets(
    'a tap during automatic animation stops it and keeps the selected sentence',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = await open(tester, backend, mode: PlayMode.sequential);
      backend.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      await tapPageAt(tester, const Offset(0.75, 0.36));
      await tester.pumpAndSettle();
      expect(find.text('第 1 / 2 页'), findsOneWidget);
      expect(service.currentMode, PlayMode.sequential);
      expect(service.currentSentenceId, 'one');
      expect(backend.playedAssets, ['assets/two.mp3', 'assets/one.mp3']);
    },
  );

  testWidgets(
    'tapping original page during auto-turn preserves active duck and saves source progress',
    (tester) async {
      final backend = FakeAudioBackend()..volume = 0.6;
      final interruptions = FakeInterruptions();
      final progress = MemoryReadingProgressStore();
      final service = await open(
        tester,
        backend,
        interruptions: interruptions,
        progress: progress,
        mode: PlayMode.sequential,
      );
      interruptions.beginDuck();
      await tester.pump();
      expect(backend.volume, 0.25);
      backend.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 145));
      expect(find.text('第 2 / 2 页'), findsOneWidget);
      await tapPageAt(tester, const Offset(0.79, 0.36));
      await tester.pumpAndSettle();
      expect(find.text('第 1 / 2 页'), findsOneWidget);
      expect(service.currentMode, PlayMode.sequential);
      expect(service.currentSentenceId, 'one');
      expect(progress.pages['test'], 8);
      expect(backend.playedAssets, ['assets/two.mp3', 'assets/one.mp3']);
      expect(backend.playedVolumes, [0.6, 0.25]);
      expect(backend.volume, 0.25);
      interruptions.endDuck();
      for (var step = 0; step < 6; step++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(backend.volume, closeTo(0.6, 0.0001));
    },
  );

  testWidgets(
    'sequential auto-turn plays child sentences, keeps speed, and ends at book end',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = await open(tester, backend, mode: PlayMode.sequential);
      await service.setSpeed(0.8);
      await tester.pumpAndSettle();
      expect(find.text('0.8x'), findsOneWidget);
      backend.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(backend.playedAssets, ['assets/two.mp3']);
      await tester.pumpAndSettle();
      expect(find.text('第 2 / 2 页'), findsOneWidget);
      expect(service.currentMode, PlayMode.sequential);
      expect(service.currentSentenceId, 'three');
      expect(backend.playedSpeeds.last, 0.8);
      backend.complete();
      await tester.pumpAndSettle();
      expect(service.currentSentenceId, 'four');
      backend.complete();
      await tester.pumpAndSettle();
      expect(service.isPlaying, isFalse);
      expect(service.currentSentenceId, isNull);
      expect(backend.playedAssets, [
        'assets/two.mp3',
        'assets/three.mp3',
        'assets/four.mp3',
      ]);
    },
  );

  testWidgets('switching to single during auto-turn cancels queued playback', (
    tester,
  ) async {
    final backend = FakeAudioBackend();
    final service = await open(tester, backend, mode: PlayMode.sequential);
    backend.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.byKey(const Key('playback-mode')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    await tester.tap(find.byKey(const ValueKey('mode-option-single')));
    await tester.pumpAndSettle();
    expect(service.currentMode, PlayMode.single);
    expect(backend.playedAssets, ['assets/two.mp3']);
  });

  testWidgets('manual previous-page navigation cancels automatic playback', (
    tester,
  ) async {
    final backend = FakeAudioBackend();
    final service = await open(tester, backend, mode: PlayMode.sequential);
    backend.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('上一页'));
    await tester.pumpAndSettle();
    expect(find.text('第 1 / 2 页'), findsOneWidget);
    expect(service.currentSentenceId, isNull);
    expect(backend.playedAssets, ['assets/two.mp3']);
  });

  testWidgets('image-only pages are skipped without canceling continuation', (
    tester,
  ) async {
    final backend = FakeAudioBackend();
    final service = await open(
      tester,
      backend,
      emptyPage: true,
      mode: PlayMode.sequential,
    );
    backend.complete();
    await tester.pumpAndSettle();
    expect(find.text('第 3 / 3 页'), findsOneWidget);
    expect(service.currentSentenceId, 'three');
  });

  testWidgets(
    'reduced motion advances and shows the precise sentence without a border',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = await open(
        tester,
        backend,
        reduceMotion: true,
        mode: PlayMode.sequential,
      );
      backend.complete();
      await tester.pumpAndSettle();
      expect(service.currentSentenceId, 'three');
      final animation = tester.widget<TweenAnimationBuilder<double>>(
        find
            .descendant(
              of: find.byType(InteractiveTextbookPage),
              matching: find.byType(TweenAnimationBuilder<double>),
            )
            .first,
      );
      expect(animation.duration, Duration.zero);
      final highlight = tester.widget<DecoratedBox>(
        find.byKey(const Key('sentence-highlight')),
      );
      final decoration = highlight.decoration as BoxDecoration;
      expect(decoration.border, isNull);
      expect(decoration.color, Colors.yellow.withValues(alpha: 0.22));
      expect(decoration.borderRadius, BorderRadius.circular(4));
    },
  );
}
