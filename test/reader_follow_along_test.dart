import 'package:english_point_reading/models/textbook.dart';
import 'package:english_point_reading/screens/textbook_reader_screen.dart';
import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:english_point_reading/services/speech_evaluator.dart';
import 'package:english_point_reading/widgets/interactive_textbook_page.dart';
import 'package:english_point_reading/widgets/speech_evaluation_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_player_service_test.dart' show FakeAudioBackend;
import 'helpers/memory_reading_progress_store.dart';

const _sentences = [
  PointSentence(
    id: 'hello',
    text: 'Hello!',
    audioPath: 'assets/hello.mp3',
    rect: NormalizedRect(left: 0.1, top: 0.25, right: 0.9, bottom: 0.35),
  ),
  PointSentence(
    id: 'name',
    text: 'My name is Lingling.',
    audioPath: 'assets/name.mp3',
    rect: NormalizedRect(left: 0.1, top: 0.5, right: 0.9, bottom: 0.6),
  ),
];
const _book = Textbook(
  bookId: 'practice',
  title: 'Practice',
  pages: [TextbookPage(pageIndex: 1, imagePath: '', sentences: _sentences)],
);

class _Evaluator extends MockSpeechEvaluator {
  var preparations = 0;
  var disposals = 0;
  @override
  Future<void> prepare() async => preparations++;
  @override
  Future<void> dispose() async => disposals++;
}

class _FailingStopBackend extends FakeAudioBackend {
  bool failStop = false;
  @override
  Future<void> stop() {
    if (failStop) return Future.error(StateError('Native stop failed'));
    return super.stop();
  }
}

Future<void> _mount(
  WidgetTester tester,
  AudioPlayerService audio,
  _Evaluator evaluator,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: TextbookReaderScreen(
        book: _book,
        audioPlayerService: audio,
        progressStore: MemoryReadingProgressStore(),
        speechEvaluatorFactory: () => evaluator,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Offset _sentenceCenter(WidgetTester tester, PointSentence sentence) {
  final page = find.byType(InteractiveTextbookPage);
  final size = tester.getSize(page);
  final image = containedImageRect(size, const Size(3, 4));
  final local = Offset(
    image.left + image.width * (sentence.rect.left + sentence.rect.right) / 2,
    image.top + image.height * (sentence.rect.top + sentence.rect.bottom) / 2,
  );
  return tester.getTopLeft(page) + local;
}

void main() {
  testWidgets(
    'failed native preview stop still disposes and permits reopening',
    (tester) async {
      final backend = _FailingStopBackend();
      final audio = AudioPlayerService(backend: backend);
      final evaluator = _Evaluator();
      await _mount(tester, audio, evaluator);
      await tester.longPressAt(_sentenceCenter(tester, _sentences.first));
      await tester.pumpAndSettle();
      backend.failStop = true;
      await tester.tap(find.byKey(const ValueKey('speech-close')));
      await tester.pumpAndSettle();
      expect(evaluator.disposals, 1);
      expect(tester.takeException(), isNull);
      backend.failStop = false;
      await tester.longPressAt(_sentenceCenter(tester, _sentences.first));
      await tester.pumpAndSettle();
      expect(find.byType(SpeechEvaluationSheet), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('speech-close')));
      await tester.pumpAndSettle();
      expect(evaluator.disposals, 2);
      await tester.pumpWidget(const SizedBox());
      audio.dispose();
    },
  );
  testWidgets(
    'long press opens exact sentence, stops queue and disposes after close',
    (tester) async {
      final audio = AudioPlayerService(backend: FakeAudioBackend());
      final evaluator = _Evaluator();
      await _mount(tester, audio, evaluator);
      await audio.playSequential(page: _book.pages.single);
      await tester.pump();
      await tester.longPressAt(_sentenceCenter(tester, _sentences.last));
      await tester.pumpAndSettle();
      final sheet = tester.widget<SpeechEvaluationSheet>(
        find.byType(SpeechEvaluationSheet),
      );
      expect(sheet.sentence.id, 'name');
      expect(evaluator.preparations, 1);
      expect(audio.isPlaying, isFalse);
      await tester.tap(find.byKey(const ValueKey('speech-close')));
      await tester.pumpAndSettle();
      expect(find.byType(SpeechEvaluationSheet), findsNothing);
      expect(evaluator.disposals, 1);
      await tester.pumpWidget(const SizedBox());
      audio.dispose();
    },
  );

  testWidgets('microphone asks which sentence when there is no selection', (
    tester,
  ) async {
    final audio = AudioPlayerService(backend: FakeAudioBackend());
    final evaluator = _Evaluator();
    await _mount(tester, audio, evaluator);
    await tester.tap(find.byKey(const ValueKey('follow-along-button')));
    await tester.pumpAndSettle();
    expect(find.text('选择一句开始跟读'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Hello!'));
    await tester.pumpAndSettle();
    final sheet = tester.widget<SpeechEvaluationSheet>(
      find.byType(SpeechEvaluationSheet),
    );
    expect(sheet.sentence.id, 'hello');
    await tester.tap(find.byKey(const ValueKey('speech-close')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    audio.dispose();
  });

  testWidgets(
    'last point-read sentence remains available after its audio ends',
    (tester) async {
      final backend = FakeAudioBackend();
      final audio = AudioPlayerService(backend: backend);
      final evaluator = _Evaluator();
      await _mount(tester, audio, evaluator);
      await tester.tapAt(_sentenceCenter(tester, _sentences.last));
      await tester.pumpAndSettle();
      backend.complete();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('follow-along-button')));
      await tester.pumpAndSettle();
      expect(find.text('选择一句开始跟读'), findsNothing);
      expect(
        tester
            .widget<SpeechEvaluationSheet>(find.byType(SpeechEvaluationSheet))
            .sentence
            .id,
        'name',
      );
      await tester.tap(find.byKey(const ValueKey('speech-close')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      audio.dispose();
    },
  );
}
