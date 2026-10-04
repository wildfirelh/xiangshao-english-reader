import 'dart:async';

import 'package:english_point_reading/services/audio_interruption_source.dart';
import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_interruptions_test.dart' show FakeInterruptions;
import 'audio_player_service_test.dart'
    show FakeAudioBackend, bubblePage, bubbles, sentences;

Future<void> advanceVolumeClock(WidgetTester tester, int milliseconds) async {
  await tester.pump();
  // Flush async native-write completions between clock ticks, independently of
  // the production ramp's number of steps or timer interval.
  for (var elapsed = 0; elapsed < milliseconds; elapsed += 10) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  testWidgets(
    'ducking keeps a whole-bubble sequence, highlighting and speed active',
    (tester) async {
      final backend = FakeAudioBackend()..volume = 0.7;
      final focus = FakeInterruptions();
      final service = AudioPlayerService(
        backend: backend,
        interruptionSource: focus,
      );
      addTearDown(service.dispose);
      await service.setSpeed(1.5);
      await service.playPage(page: bubblePage);
      final stops = backend.stopCount;
      focus.beginDuck();
      await tester.pump();
      expect(backend.volume, 0.25);
      expect(backend.stopCount, stops);
      expect(backend.pauseCount, 0);
      expect(service.isPlaying, isTrue);
      expect(service.currentBubbleId, 'bubble-one');
      backend.complete();
      await tester.pump();
      expect(service.currentBubbleId, 'bubble-two');
      expect(backend.playedVolumes, [0.7, 0.25]);
      expect(backend.playedSpeeds, [1.5, 1.5]);
      focus.endDuck();
      await advanceVolumeClock(tester, 60);
      expect(backend.volume, greaterThan(0.25));
      expect(backend.volume, lessThan(0.7));
      await advanceVolumeClock(tester, 220);
      expect(backend.volume, closeTo(0.7, 0.00001));
      expect(service.isPlaying, isTrue);
      expect(backend.pauseCount, 0);
    },
  );

  testWidgets(
    'Reader mode change followed by a precise manual tap preserves an active duck',
    (tester) async {
      final backend = FakeAudioBackend()..volume = 0.6;
      final focus = FakeInterruptions();
      final service = AudioPlayerService(
        backend: backend,
        interruptionSource: focus,
      );
      addTearDown(service.dispose);
      await service.playPage(page: bubblePage);
      focus.beginDuck();
      await tester.pump();
      service.setPlayMode(PlayMode.single);
      await service.playSentence(
        pageSentences: sentences,
        targetSentence: sentences[1],
      );
      expect(service.currentMode, PlayMode.single);
      expect(service.currentSentenceId, 'two');
      expect(backend.playedVolumes.last, 0.25);
      expect(backend.volume, 0.25);
      // Re-activating focus for a new clip can report pause-end instead of duck-end.
      focus.endPause();
      await advanceVolumeClock(tester, 220);
      expect(backend.volume, closeTo(0.6, 0.00001));
      expect(service.isPlaying, isTrue);
      expect(backend.pauseCount, 0);
    },
  );

  testWidgets(
    'ducking while an asset loads survives a manual interruption and speed change',
    (tester) async {
      final backend = FakeAudioBackend()..delayFirstLoad = Completer<void>();
      final focus = FakeInterruptions();
      final service = AudioPlayerService(
        backend: backend,
        interruptionSource: focus,
      );
      addTearDown(service.dispose);
      final loading = service.playPage(page: bubblePage);
      await tester.pump();
      focus.beginDuck();
      await service.setSpeed(1.2);
      service.setPlayMode(PlayMode.single);
      final manual = service.playSentence(
        pageSentences: sentences,
        targetSentence: sentences.last,
      );
      backend.delayFirstLoad!.complete();
      await Future.wait([loading, manual]);
      expect(backend.playedAssets, ['assets/three.mp3']);
      expect(backend.playedSpeeds, [1.2]);
      expect(backend.playedVolumes, [0.25]);
      expect(service.currentMode, PlayMode.single);
    },
  );

  testWidgets('a volume already below the duck limit is never raised', (
    tester,
  ) async {
    final backend = FakeAudioBackend()..volume = 0.1;
    final focus = FakeInterruptions();
    final service = AudioPlayerService(
      backend: backend,
      interruptionSource: focus,
    );
    addTearDown(service.dispose);
    await service.playPage(page: bubblePage);
    focus.beginDuck();
    focus.beginDuck();
    await tester.pump();
    focus.endDuck();
    await advanceVolumeClock(tester, 220);
    expect(backend.volume, 0.1);
    expect(backend.volumeRequests.every((value) => value <= 0.1), isTrue);
    expect(backend.pauseCount, 0);
  });

  testWidgets(
    'a new duck arriving during an in-flight fade wins and preserves the original volume',
    (tester) async {
      final backend = FakeAudioBackend()..volume = 0.8;
      final focus = FakeInterruptions();
      final service = AudioPlayerService(
        backend: backend,
        interruptionSource: focus,
      );
      addTearDown(service.dispose);
      await service.playPage(page: bubblePage);
      focus.beginDuck();
      await tester.pump();
      focus.endDuck();
      await advanceVolumeClock(tester, 40);
      expect(backend.volume, greaterThan(0.25));
      backend.delayVolume = Completer<void>();
      await advanceVolumeClock(tester, 40);
      focus.beginDuck();
      backend.delayVolume!.complete();
      await tester.pump();
      expect(backend.volume, 0.25);
      focus.endDuck();
      focus.endDuck();
      await advanceVolumeClock(tester, 220);
      expect(backend.volume, closeTo(0.8, 0.00001));
      expect(backend.playedAssets, hasLength(1));
      expect(backend.pauseCount, 0);
    },
  );

  testWidgets(
    'pause, headphone-style focus loss and stop restore volume without resuming',
    (tester) async {
      final backend = FakeAudioBackend()..volume = 0.65;
      final focus = FakeInterruptions();
      final service = AudioPlayerService(
        backend: backend,
        interruptionSource: focus,
      );
      addTearDown(service.dispose);
      await service.playPage(page: bubblePage);
      focus.beginDuck();
      await tester.pump();
      focus.beginPause();
      await tester.pump();
      expect(service.isPlaying, isFalse);
      expect(service.currentBubbleId, 'bubble-one');
      expect(backend.volume, 0.65);
      focus.endPause();
      focus.endDuck();
      await advanceVolumeClock(tester, 220);
      expect(backend.playedAssets, hasLength(1));
      await service.playPage(page: bubblePage);
      focus.beginDuck();
      await tester.pump();
      await service.stop();
      expect(service.currentBubbleId, isNull);
      expect(backend.volume, 0.65);
      focus.endDuck();
      await advanceVolumeClock(tester, 220);
      expect(backend.playedAssets, hasLength(2));
      expect(service.isPlaying, isFalse);
    },
  );

  testWidgets(
    'background cleanup cancels a fade and ignores further duck requests',
    (tester) async {
      final backend = FakeAudioBackend()..volume = 0.75;
      final focus = FakeInterruptions();
      final service = AudioPlayerService(
        backend: backend,
        interruptionSource: focus,
      );
      addTearDown(service.dispose);
      await service.playPage(page: bubblePage);
      focus.beginDuck();
      await tester.pump();
      focus.endDuck();
      service.setForeground(false);
      await tester.pump();
      expect(backend.volume, 0.75);
      final requests = backend.volumeRequests.length;
      focus.beginDuck();
      await advanceVolumeClock(tester, 220);
      expect(backend.volumeRequests, hasLength(requests));
      expect(service.isPlaying, isFalse);
      service.setForeground(true);
      expect(backend.playedAssets, hasLength(1));
      await service.playPage(page: bubblePage);
      expect(backend.playedVolumes.last, 0.75);
    },
  );

  testWidgets(
    'volume failures are contained and do not lose the original volume for a later retry',
    (tester) async {
      final backend = FakeAudioBackend()..volume = 0.6;
      final focus = FakeInterruptions();
      final service = AudioPlayerService(
        backend: backend,
        interruptionSource: focus,
      );
      addTearDown(service.dispose);
      await service.playPage(page: bubblePage);
      focus.beginDuck();
      await tester.pump();
      backend.failVolume = true;
      focus.endDuck();
      await advanceVolumeClock(tester, 220);
      expect(service.isPlaying, isTrue);
      expect(backend.volume, 0.25);
      expect(backend.pauseCount, 0);
      backend.failVolume = false;
      focus.beginDuck();
      await tester.pump();
      focus.endDuck();
      await advanceVolumeClock(tester, 220);
      expect(backend.volume, closeTo(0.6, 0.00001));
      expect(backend.playedAssets, hasLength(1));
    },
  );

  testWidgets('ducking does not invalidate a pending next-page completion', (
    tester,
  ) async {
    final backend = FakeAudioBackend();
    final focus = FakeInterruptions();
    final service = AudioPlayerService(
      backend: backend,
      interruptionSource: focus,
    );
    addTearDown(service.dispose);
    final completions = <PagePlaybackCompletion>[];
    service.pageCompletions.listen(completions.add);
    await service.playPage(page: bubblePage, targetBubble: bubbles.last);
    backend.complete();
    focus.beginDuck();
    await tester.pump();
    expect(completions, hasLength(1));
    expect(service.canContinue(completions.single), isTrue);
    focus.events.add(
      AudioInterruptionEvent(false, AudioInterruptionType.unknown),
    );
    await advanceVolumeClock(tester, 220);
    expect(service.canContinue(completions.single), isTrue);
    expect(backend.volume, 1.0);
  });

  testWidgets(
    'dispose cancels pending fade steps and leaves no focus listeners',
    (tester) async {
      final backend = FakeAudioBackend();
      final focus = FakeInterruptions();
      final service = AudioPlayerService(
        backend: backend,
        interruptionSource: focus,
      );
      await service.playPage(page: bubblePage);
      focus.beginDuck();
      await tester.pump();
      focus.endDuck();
      service.dispose();
      final count = backend.volumeRequests.length;
      await advanceVolumeClock(tester, 220);
      expect(backend.volumeRequests, hasLength(count));
      expect(focus.disposed, isTrue);
    },
  );
}
