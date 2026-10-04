import 'package:english_point_reading/models/textbook.dart';
import 'package:english_point_reading/models/textbook_unit.dart';
import 'package:english_point_reading/screens/textbook_reader_screen.dart';
import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:english_point_reading/services/learning_controller.dart';
import 'package:english_point_reading/services/learning_preferences_store.dart';
import 'package:english_point_reading/services/playback_preferences_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'audio_player_service_test.dart' show FakeAudioBackend, sentences;
import 'helpers/memory_reading_progress_store.dart';

LearningController controller({bool enabled = true}) => LearningController(
  preferencesStore: InMemoryLearningPreferencesStore(
    initialValue: LearningPreferences(eyeReminderEnabled: enabled),
  ),
  playbackPreferencesStore: InMemoryPlaybackPreferencesStore(),
  now: () => DateTime(2026, 10, 4),
);

const book = Textbook(
  bookId: 'future_book',
  title: '未来教材',
  pages: [
    TextbookPage(pageIndex: 10, imagePath: '', sentences: sentences),
    TextbookPage(pageIndex: 20, imagePath: '', sentences: sentences),
  ],
);

Future<void> openReader(
  WidgetTester tester,
  LearningController learning,
  AudioPlayerService audio, {
  Duration interval = const Duration(minutes: 20),
  List<TextbookUnit>? units,
}) async {
  await learning.initialize();
  await tester.pumpWidget(
    MaterialApp(
      home: TextbookReaderScreen(
        book: book,
        units: units,
        firstPageIndex: 10,
        progressStore: MemoryReadingProgressStore(),
        audioPlayerService: audio,
        learningController: learning,
        eyeReminderInterval: interval,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'statistics count native audio start, not opening or page turns',
    (tester) async {
      final learning = controller();
      final backend = FakeAudioBackend();
      final audio = AudioPlayerService(backend: backend);
      await openReader(tester, learning, audio);
      expect(learning.readingDays, 0);
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      expect(learning.readingBooks, 0);
      await audio.playSentence(
        pageSentences: sentences,
        targetSentence: sentences.first,
      );
      await tester.pump();
      expect(learning.readingDays, 0);
      backend.emitState(PlayerState(true, ProcessingState.ready));
      backend.emitState(PlayerState(true, ProcessingState.ready));
      await tester.pumpAndSettle();
      expect(learning.readingDays, 1);
      expect(learning.readingBooks, 1);
      await tester.pumpWidget(const SizedBox());
      audio.dispose();
      learning.dispose();
    },
  );

  test(
    'failed asset load and background playback do not emit learning starts',
    () async {
      final backend = FakeAudioBackend()
        ..failedAsset = sentences.first.audioPath;
      final audio = AudioPlayerService(backend: backend);
      var starts = 0;
      final subscription = audio.playbackStarts.listen((_) => starts++);
      await expectLater(
        audio.playSentence(
          pageSentences: sentences,
          targetSentence: sentences.first,
        ),
        throwsStateError,
      );
      backend.emitState(PlayerState(true, ProcessingState.ready));
      expect(starts, 0);
      backend.failedAsset = null;
      await audio.playSentence(
        pageSentences: sentences,
        targetSentence: sentences.first,
      );
      backend.emitState(PlayerState(true, ProcessingState.loading));
      expect(starts, 0);
      backend.emitState(PlayerState(true, ProcessingState.ready));
      backend.emitState(PlayerState(true, ProcessingState.ready));
      expect(starts, 1);
      audio.setForeground(false);
      backend.emitState(PlayerState(true, ProcessingState.ready));
      expect(starts, 1);
      await subscription.cancel();
      audio.dispose();
    },
  );

  testWidgets(
    'eye reminder responds to preference and cancels on reader exit',
    (tester) async {
      final learning = controller(enabled: false);
      final audio = AudioPlayerService(backend: FakeAudioBackend());
      await openReader(
        tester,
        learning,
        audio,
        interval: const Duration(seconds: 10),
      );
      await tester.pump(const Duration(seconds: 11));
      expect(find.text('已经学习一会儿了，休息一下，看看远处吧。'), findsNothing);
      await learning.setEyeReminderEnabled(true);
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('已经学习一会儿了，休息一下，看看远处吧。'), findsOneWidget);
      await learning.setEyeReminderEnabled(false);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 20));
      expect(tester.takeException(), isNull);
      audio.dispose();
      learning.dispose();
    },
  );

  testWidgets('eye reminder excludes background time', (tester) async {
    final learning = controller();
    final audio = AudioPlayerService(backend: FakeAudioBackend());
    await openReader(
      tester,
      learning,
      audio,
      interval: const Duration(seconds: 10),
    );
    tester.binding.handleAppLifecycleStateChanged(
      AppLifecycleState.paused,
    );
    await tester.pump(const Duration(seconds: 15));
    expect(find.text('已经学习一会儿了，休息一下，看看远处吧。'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已经学习一会儿了，休息一下，看看远处吧。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    audio.dispose();
    learning.dispose();
  });

  testWidgets(
    'future textbook uses injected units and its own first page offset',
    (tester) async {
      final learning = controller(enabled: false);
      final audio = AudioPlayerService(backend: FakeAudioBackend());
      await openReader(
        tester,
        learning,
        audio,
        units: const [
          TextbookUnit(1, 'Start', 10),
          TextbookUnit(2, 'Next', 20),
        ],
      );
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();
      expect(find.text('Unit 1 Start'), findsOneWidget);
      expect(find.text('教材第 1 页'), findsOneWidget);
      expect(find.text('教材第 11 页'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('unit-2')));
      await tester.pumpAndSettle();
      expect(find.text('第 2 / 2 页'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      audio.dispose();
      learning.dispose();
    },
  );
}
