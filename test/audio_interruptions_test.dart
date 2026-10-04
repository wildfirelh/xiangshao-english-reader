import 'dart:async';

import 'package:english_point_reading/models/textbook.dart';
import 'package:english_point_reading/screens/textbook_reader_screen.dart';
import 'package:english_point_reading/services/audio_interruption_source.dart';
import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:english_point_reading/widgets/interactive_textbook_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'audio_player_service_test.dart'
    show FakeAudioBackend, sentences, bubblePage, bubbles, legacyPage;
import 'helpers/memory_reading_progress_store.dart';

class FakeInterruptions implements AudioInterruptionSource {
  final events = StreamController<void>.broadcast(sync: true);
  bool initialized = false;
  bool disposed = false;
  @override
  Stream<void> get pauseRequests => events.stream;
  @override
  Future<void> initialize() async => initialized = true;
  @override
  Future<void> dispose() async {
    disposed = true;
    await events.close();
  }
}

void main() {
  test('interruption pauses, preserves selection and speed, and cancels completion', () async {
    final backend = FakeAudioBackend();
    final interruptions = FakeInterruptions();
    final service = AudioPlayerService(
      backend: backend,
      interruptionSource: interruptions,
    );
    addTearDown(service.dispose);
    await service.setSpeed(.8);
    await service.playPage(page: bubblePage);
    expect(interruptions.initialized, isTrue);
    interruptions.events.add(null);
    expect(service.isPlaying, isFalse);
    expect(service.currentSentenceId, isNull);
    expect(service.currentBubbleId, 'bubble-one');
    expect(backend.pauseCount, 1);
    backend.complete();
    await Future<void>.delayed(Duration.zero);
    expect(backend.playedAssets, hasLength(1));
    await service.playSentence(
      pageSentences: sentences,
      targetSentence: sentences.first,
    );
    expect(service.isPlaying, isTrue);
    expect(backend.playedSpeeds, [.8, .8]);
    service.dispose();
    expect(interruptions.disposed, isTrue);
  });

  test('interruption during asset load prevents late playback without clearing selection', () async {
    final backend = FakeAudioBackend()..delayFirstLoad = Completer<void>();
    final interruptions = FakeInterruptions();
    final service = AudioPlayerService(
      backend: backend,
      interruptionSource: interruptions,
    );
    addTearDown(service.dispose);
    final loading = service.playSentence(
      pageSentences: sentences,
      targetSentence: sentences.first,
    );
    await Future<void>.delayed(Duration.zero);
    interruptions.events.add(null);
    backend.delayFirstLoad!.complete();
    await loading;
    expect(backend.playedAssets, isEmpty);
    expect(service.currentSentenceId, 'one');
    expect(service.isPlaying, isFalse);
  });

  test('background invalidates page continuation and blocks new playback until foreground', () async {
    final backend = FakeAudioBackend();
    final service = AudioPlayerService(backend: backend);
    addTearDown(service.dispose);
    final completions = <PagePlaybackCompletion>[];
    service.pageCompletions.listen(completions.add);
    await service.playPage(
      page: legacyPage,
      targetBubble: legacyPage.playbackBubbles.last,
    );
    backend.complete();
    await Future<void>.delayed(Duration.zero);
    service.setForeground(false);
    expect(service.canContinue(completions.single), isFalse);
    await service.playSentence(
      pageSentences: sentences,
      targetSentence: sentences.first,
    );
    expect(backend.playedAssets, hasLength(1));
    service.setForeground(true);
    expect(service.isPlaying, isFalse);
    await service.playSentence(
      pageSentences: sentences,
      targetSentence: sentences.first,
    );
    expect(backend.playedAssets, hasLength(2));
  });

  test(
    'focus interruption while a complete bubble loads retains bubble highlight',
    () async {
      final backend = FakeAudioBackend()..delayFirstLoad = Completer<void>();
      final interruptions = FakeInterruptions();
      final service = AudioPlayerService(
        backend: backend,
        interruptionSource: interruptions,
      );
      addTearDown(service.dispose);
      final loading = service.playPage(page: bubblePage);
      await Future<void>.delayed(Duration.zero);
      interruptions.events.add(null);
      backend.delayFirstLoad!.complete();
      await loading;
      expect(service.currentBubble, same(bubbles.first));
      expect(service.currentSentenceId, isNull);
      expect(service.isPlaying, isFalse);
      expect(backend.playedAssets, isEmpty);
      backend.complete();
      await Future<void>.delayed(Duration.zero);
      expect(backend.playedAssets, isEmpty);
    },
  );

  test(
    'native pause updates state and late ready events do not interrupt startup',
    () async {
      final backend = FakeAudioBackend();
      final service = AudioPlayerService(backend: backend);
      addTearDown(service.dispose);
      await service.playSentence(
        pageSentences: sentences,
        targetSentence: sentences.first,
      );
      backend.emitState(PlayerState(false, ProcessingState.ready));
      expect(service.isPlaying, isTrue);
      backend.emitState(PlayerState(true, ProcessingState.ready));
      backend.emitState(PlayerState(false, ProcessingState.ready));
      expect(service.isPlaying, isFalse);
      expect(service.currentSentenceId, 'one');
    },
  );

  testWidgets(
    'reader lifecycle pauses on lock/background, retains highlight, never auto resumes',
    (tester) async {
      final backend = FakeAudioBackend();
      final service = AudioPlayerService(backend: backend);
      addTearDown(service.dispose);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        MaterialApp(
          home: TextbookReaderScreen(
            audioPlayerService: service,
            progressStore: MemoryReadingProgressStore(),
            book: Textbook(
              bookId: 'test',
              title: 'Test',
              pages: [
                TextbookPage(pageIndex: 8, imagePath: '', sentences: sentences),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await service.playSentence(
        pageSentences: sentences,
        targetSentence: sentences.first,
      );
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
        expect(service.isPlaying, isFalse);
        expect(
          tester
              .widget<InteractiveTextbookPage>(
                find.byType(InteractiveTextbookPage),
              )
              .activeSentenceId,
          'one',
        );
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(service.isPlaying, isFalse);
      expect(backend.playedAssets, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      final pauses = backend.pauseCount;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(backend.pauseCount, pauses);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );
}
