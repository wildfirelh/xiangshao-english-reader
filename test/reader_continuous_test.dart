import 'package:english_point_reading/models/textbook.dart';
import 'package:english_point_reading/screens/textbook_reader_screen.dart';
import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:english_point_reading/widgets/interactive_textbook_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_player_service_test.dart' show FakeAudioBackend, sentences;
import 'helpers/memory_reading_progress_store.dart';

void main() {
  Future<AudioPlayerService> open(
    WidgetTester tester,
    FakeAudioBackend backend, {
    bool emptyPage = false,
    bool reduceMotion = false,
  }) async {
    final service = AudioPlayerService(backend: backend)
      ..setPlayMode(PlayMode.continuous);
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: TextbookReaderScreen(
            audioPlayerService: service,
            progressStore: MemoryReadingProgressStore(),
            book: Textbook(
              bookId: 'test',
              title: 'Test',
              pages: [
                TextbookPage(
                  pageIndex: 8,
                  imagePath: '',
                  sentences: [sentences[0]],
                ),
                if (emptyPage)
                  const TextbookPage(
                    pageIndex: 9,
                    imagePath: '',
                    sentences: [],
                  ),
                TextbookPage(
                  pageIndex: 10,
                  imagePath: '',
                  sentences: [sentences[1], sentences[2]],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await service.playSentence(
      pageSentences: [sentences[0]],
      targetSentence: sentences[0],
    );
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets(
    'a tap during automatic animation stops it and keeps the selected sentence',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = await open(tester, backend);
      final page = tester.widget<InteractiveTextbookPage>(
        find.byType(InteractiveTextbookPage).first,
      );
      backend.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      page.onSentenceTap(sentences.first);
      await tester.pumpAndSettle();
      expect(find.text('第 1 / 2 页'), findsOneWidget);
      expect(service.currentSentenceId, 'one');
      expect(backend.playedAssets, ['assets/one.mp3', 'assets/one.mp3']);
    },
  );

  testWidgets(
    'auto-turn plays first sentence, keeps speed, and ends at book end',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = await open(tester, backend);
      await tester.tap(find.byKey(const Key('playback-speed')));
      await tester.pumpAndSettle();
      expect(find.text('0.8x 慢速'), findsOneWidget);
      backend.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(backend.playedAssets, ['assets/one.mp3']);
      await tester.pumpAndSettle();
      expect(find.text('第 2 / 2 页'), findsOneWidget);
      expect(service.currentSentenceId, 'two');
      expect(backend.playedSpeeds.last, 0.8);
      backend.complete();
      await tester.pumpAndSettle();
      expect(service.currentSentenceId, 'three');
      backend.complete();
      await tester.pumpAndSettle();
      expect(service.isPlaying, isFalse);
      expect(service.currentSentenceId, isNull);
      expect(backend.playedAssets, [
        'assets/one.mp3',
        'assets/two.mp3',
        'assets/three.mp3',
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
    expect(backend.playedAssets, ['assets/one.mp3']);
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
    expect(service.currentSentenceId, isNull);
    expect(backend.playedAssets, ['assets/one.mp3']);
  });

  testWidgets(
    'image-only pages are skipped without canceling the continuation',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = await open(tester, backend, emptyPage: true);
      backend.complete();
      await tester.pumpAndSettle();
      expect(find.text('第 3 / 3 页'), findsOneWidget);
      expect(service.currentSentenceId, 'two');
    },
  );

  testWidgets('reduced motion still advances and uses an immediate highlight', (
    tester,
  ) async {
    final backend = FakeAudioBackend();
    final service = await open(tester, backend, reduceMotion: true);
    backend.complete();
    await tester.pumpAndSettle();
    expect(service.currentSentenceId, 'two');
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
  });
}
