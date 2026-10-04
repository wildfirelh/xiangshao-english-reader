import 'dart:async';

import 'package:english_point_reading/models/textbook.dart';
import 'package:english_point_reading/screens/textbook_reader_screen.dart';
import 'package:english_point_reading/services/audio_interruption_source.dart';
import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:english_point_reading/widgets/interactive_textbook_page.dart';
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

void main() {
  Future<AudioPlayerService> open(
    WidgetTester tester,
    FakeAudioBackend backend, {
    bool emptyPage = false,
    bool reduceMotion = false,
    bool startPlayback = true,
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
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: TextbookReaderScreen(
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
    );
    await tester.pumpAndSettle();
    if (startPlayback) {
      await tester.tap(find.text('单句点读'));
      await tester.pumpAndSettle();
    }
    return service;
  }

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

  testWidgets(
    'continuous button starts complete bubble audio and translation',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = await open(tester, backend);
      expect(service.currentMode, PlayMode.continuous);
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
    await tester.tap(find.text('单句点读'));
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
      final service = await open(tester, backend);
      backend.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      await tapPageAt(tester, const Offset(0.75, 0.36));
      await tester.pumpAndSettle();
      expect(find.text('第 1 / 2 页'), findsOneWidget);
      expect(service.currentMode, PlayMode.single);
      expect(service.currentSentenceId, 'one');
      expect(backend.playedAssets, ['assets/bubble-one.mp3', 'assets/one.mp3']);
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
      expect(service.currentMode, PlayMode.single);
      expect(service.currentSentenceId, 'one');
      expect(progress.pages['test'], 8);
      expect(backend.playedAssets, ['assets/bubble-one.mp3', 'assets/one.mp3']);
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
    'auto-turn plays bubbles in sequence, keeps speed, and ends at book end',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = await open(tester, backend);
      await service.setSpeed(0.8);
      await tester.pumpAndSettle();
      expect(find.text('0.8x'), findsOneWidget);
      backend.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(backend.playedAssets, ['assets/bubble-one.mp3']);
      await tester.pumpAndSettle();
      expect(find.text('第 2 / 2 页'), findsOneWidget);
      expect(service.currentMode, PlayMode.continuous);
      expect(service.currentBubbleId, 'bubble-two');
      expect(backend.playedSpeeds.last, 0.8);
      backend.complete();
      await tester.pumpAndSettle();
      expect(service.currentBubbleId, 'bubble-three');
      backend.complete();
      await tester.pumpAndSettle();
      expect(service.isPlaying, isFalse);
      expect(service.currentBubbleId, isNull);
      expect(backend.playedAssets, [
        'assets/bubble-one.mp3',
        'assets/bubble-two.mp3',
        'assets/bubble-three.mp3',
      ]);
    },
  );

  testWidgets('switching to single during auto-turn cancels queued playback', (
    tester,
  ) async {
    final backend = FakeAudioBackend();
    final service = await open(tester, backend);
    backend.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('整页连读'));
    await tester.pumpAndSettle();
    expect(service.currentMode, PlayMode.single);
    expect(backend.playedAssets, ['assets/bubble-one.mp3']);
  });

  testWidgets('manual previous-page navigation cancels automatic playback', (
    tester,
  ) async {
    final backend = FakeAudioBackend();
    final service = await open(tester, backend);
    backend.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('上一页'));
    await tester.pumpAndSettle();
    expect(find.text('第 1 / 2 页'), findsOneWidget);
    expect(service.currentBubbleId, isNull);
    expect(backend.playedAssets, ['assets/bubble-one.mp3']);
  });

  testWidgets('image-only pages are skipped without canceling continuation', (
    tester,
  ) async {
    final backend = FakeAudioBackend();
    final service = await open(tester, backend, emptyPage: true);
    backend.complete();
    await tester.pumpAndSettle();
    expect(find.text('第 3 / 3 页'), findsOneWidget);
    expect(service.currentBubbleId, 'bubble-two');
  });

  testWidgets(
    'reduced motion advances and shows full bubble without a border',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = await open(tester, backend, reduceMotion: true);
      backend.complete();
      await tester.pumpAndSettle();
      expect(service.currentBubbleId, 'bubble-two');
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
        find.byKey(const Key('bubble-highlight')),
      );
      final decoration = highlight.decoration as BoxDecoration;
      expect(decoration.border, isNull);
      expect(decoration.color, Colors.yellow.withValues(alpha: 0.22));
      expect(decoration.borderRadius, BorderRadius.circular(4));
    },
  );
}
