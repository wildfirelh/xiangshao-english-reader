import 'package:english_point_reading/models/textbook.dart';
import 'package:english_point_reading/screens/textbook_reader_screen.dart';
import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:english_point_reading/widgets/interactive_textbook_page.dart';
import 'package:english_point_reading/widgets/textbook_bottom_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'helpers/memory_reading_progress_store.dart';

const _sentence = PointSentence(
  id: 'a',
  text: 'Hello!',
  audioPath: '',
  rect: NormalizedRect(left: 0.4, top: 0.4, right: 0.6, bottom: 0.6),
);

const _wideBubble = DialogueBubble(
  id: 'bubble',
  text: 'Hello! Nice to meet you.',
  audioPath: 'assets/bubble.mp3',
  sentenceIds: ['a'],
  rect: NormalizedRect(left: 0.2, top: 0.3, right: 0.8, bottom: 0.7),
);

class _SilentBackend implements AudioPlaybackBackend {
  _SilentBackend({this.failAsset = false});

  final bool failAsset;
  int stopCount = 0;

  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();

  @override
  Future<Duration?> setAsset(String assetPath) async {
    if (failAsset) throw StateError('Audio asset missing');
    return Duration.zero;
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> stop() async => stopCount++;

  @override
  Future<void> dispose() async {}
}

void main() {
  test('contain geometry excludes horizontal and vertical padding', () {
    expect(
      containedImageRect(const Size(400, 400), const Size(3, 4)),
      const Rect.fromLTWH(50, 0, 300, 400),
    );
    expect(
      containedImageRect(const Size(400, 400), const Size(4, 3)),
      const Rect.fromLTWH(0, 50, 400, 300),
    );
  });

  testWidgets('page ignores letterbox taps and aligns highlight to image', (
    tester,
  ) async {
    var tapCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 400,
              child: InteractiveTextbookPage(
                page: const TextbookPage(
                  pageIndex: 1,
                  imagePath: '',
                  sentences: [_sentence],
                ),
                activeSentenceId: 'a',
                onSentenceTap: (_) => tapCount++,
              ),
            ),
          ),
        ),
      ),
    );
    final origin = tester.getTopLeft(find.byType(InteractiveTextbookPage));
    await tester.tapAt(origin + const Offset(20, 200));
    expect(tapCount, 0);
    await tester.tapAt(origin + const Offset(200, 200));
    expect(tapCount, 1);

    final highlight = tester.getRect(
      find.byKey(const Key('sentence-highlight')),
    );
    expect(highlight.left - origin.dx, closeTo(170, 0.01));
    expect(highlight.top - origin.dy, closeTo(160, 0.01));
    expect(highlight.width, closeTo(60, 0.01));
    expect(highlight.height, closeTo(80, 0.01));
  });

  testWidgets(
    'bubble highlight covers full block while sentence highlight remains precise',
    (tester) async {
      Future<void> display({String? sentenceId, String? bubbleId}) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 400,
                    height: 400,
                    child: InteractiveTextbookPage(
                      page: const TextbookPage(
                        pageIndex: 1,
                        imagePath: '',
                        sentences: [_sentence],
                        bubbles: [_wideBubble],
                      ),
                      activeSentenceId: sentenceId,
                      activeBubbleId: bubbleId,
                      onSentenceTap: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          );
      await display(bubbleId: 'bubble');
      final origin = tester.getTopLeft(find.byType(InteractiveTextbookPage));
      final bubbleRect = tester.getRect(
        find.byKey(const Key('bubble-highlight')),
      );
      expect(bubbleRect.left - origin.dx, closeTo(110, 0.01));
      expect(bubbleRect.top - origin.dy, closeTo(120, 0.01));
      expect(bubbleRect.size.width, closeTo(180, 0.01));
      expect(bubbleRect.size.height, closeTo(160, 0.01));
      expect(find.byKey(const Key('sentence-highlight')), findsNothing);
      await display(sentenceId: 'a');
      final sentenceRect = tester.getRect(
        find.byKey(const Key('sentence-highlight')),
      );
      expect(sentenceRect.size.width, closeTo(60, 0.01));
      expect(sentenceRect.size.height, closeTo(80, 0.01));
      expect(find.byKey(const Key('bubble-highlight')), findsNothing);
    },
  );

  testWidgets(
    'bottom bar switches mode, hides translation and shows mic notice',
    (tester) async {
      var mode = PlayMode.single;
      var translationEnabled = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: StatefulBuilder(
              builder: (context, setState) => TextbookBottomBar(
                currentMode: mode,
                onModeChanged: (value) => setState(() => mode = value),
                isTranslationEnabled: translationEnabled,
                onTranslationChanged: (value) =>
                    setState(() => translationEnabled = value),
                activeSentence: _sentence,
              ),
            ),
          ),
        ),
      );

      expect(find.text('暂无释义'), findsOneWidget);
      await tester.tap(find.text('单句点读'));
      await tester.pump();
      expect(find.text('整页连读'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.translate));
      await tester.pump();
      expect(find.text('暂无释义'), findsNothing);
      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();
      expect(find.text('功能正在开发中，敬请期待'), findsOneWidget);
    },
  );

  testWidgets('page change stops playback and clears selected sentence', (
    tester,
  ) async {
    final backend = _SilentBackend();
    final audio = AudioPlayerService(backend: backend);
    addTearDown(audio.dispose);
    final book = Textbook(
      bookId: 'test',
      title: 'Test book',
      pages: const [
        TextbookPage(pageIndex: 1, imagePath: '', sentences: [_sentence]),
        TextbookPage(pageIndex: 2, imagePath: '', sentences: []),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: TextbookReaderScreen(
          book: book,
          audioPlayerService: audio,
          progressStore: MemoryReadingProgressStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hello!').first);
    await tester.pump();
    expect(find.byKey(const Key('sentence-highlight')), findsOneWidget);
    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
    expect(find.text('第 2 / 2 页'), findsOneWidget);
    expect(find.byKey(const Key('sentence-highlight')), findsNothing);
    expect(backend.stopCount, greaterThan(0));
  });

  testWidgets('missing image and audio keep the reader usable', (tester) async {
    final audio = AudioPlayerService(backend: _SilentBackend(failAsset: true));
    addTearDown(audio.dispose);
    const missingAudioSentence = PointSentence(
      id: 'missing',
      text: 'Try me',
      audioPath: 'assets/textbooks/xiangshao_3_1/audios/missing.mp3',
      rect: NormalizedRect(left: 0.2, top: 0.4, right: 0.8, bottom: 0.5),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: TextbookReaderScreen(
          book: const Textbook(
            bookId: 'test',
            title: 'Test book',
            pages: [
              TextbookPage(
                pageIndex: 1,
                imagePath: 'assets/textbooks/xiangshao_3_1/images/missing.png',
                sentences: [missingAudioSentence],
              ),
            ],
          ),
          audioPlayerService: audio,
          progressStore: MemoryReadingProgressStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('教材图片待导入'), findsOneWidget);

    await tester.tap(find.text('Try me'));
    await tester.pumpAndSettle();
    expect(find.text('音频尚未导入，请添加教材音频'), findsOneWidget);
    expect(find.byKey(const Key('sentence-highlight')), findsOneWidget);
  });
}
