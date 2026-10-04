import 'dart:async';

import 'package:english_point_reading/models/textbook.dart';
import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

const sentences = [
  PointSentence(
    id: 'one',
    text: 'One',
    audioPath: 'assets/one.mp3',
    rect: NormalizedRect(left: 0, top: 0, right: 0.5, bottom: 0.2),
  ),
  PointSentence(
    id: 'two',
    text: 'Two',
    audioPath: 'assets/two.mp3',
    rect: NormalizedRect(left: 0, top: 0.2, right: 0.5, bottom: 0.4),
  ),
  PointSentence(
    id: 'three',
    text: 'Three',
    audioPath: 'assets/three.mp3',
    rect: NormalizedRect(left: 0, top: 0.4, right: 0.5, bottom: 0.6),
  ),
];

const legacyPage = TextbookPage(
  pageIndex: 8,
  imagePath: '',
  sentences: sentences,
);

const bubbles = [
  DialogueBubble(
    id: 'bubble-one',
    text: 'One. Two.',
    translation: '一。二。',
    audioPath: 'assets/bubble-one.mp3',
    rect: NormalizedRect(left: 0, top: 0, right: 0.5, bottom: 0.4),
    sentenceIds: ['one', 'two'],
  ),
  DialogueBubble(
    id: 'bubble-two',
    text: 'Three.',
    audioPath: 'assets/bubble-two.mp3',
    rect: NormalizedRect(left: 0, top: 0.4, right: 0.5, bottom: 0.6),
    sentenceIds: ['three'],
  ),
];

const bubblePage = TextbookPage(
  pageIndex: 8,
  imagePath: '',
  sentences: sentences,
  bubbles: bubbles,
);

class FakeAudioBackend implements AudioPlaybackBackend {
  final _states = StreamController<PlayerState>.broadcast(sync: true);
  final loadedAssets = <String>[];
  final playedAssets = <String>[];
  Completer<void>? delayFirstLoad;
  String? _asset;
  int stopCount = 0;
  int pauseCount = 0;
  double speed = 1.0;
  final playedSpeeds = <double>[];
  final speedRequests = <double>[];
  Completer<void>? delaySpeed;
  bool failSpeed = false;
  String? failedAsset;
  Completer<void>? delayNextLoad;

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;

  @override
  Future<Duration?> setAsset(String assetPath) async {
    loadedAssets.add(assetPath);
    if (loadedAssets.length == 1 && delayFirstLoad != null) {
      await delayFirstLoad!.future;
    }
    if (loadedAssets.length > 1 && delayNextLoad != null) {
      await delayNextLoad!.future;
    }
    if (assetPath == failedAsset) throw StateError('Missing asset');
    _asset = assetPath;
    return const Duration(seconds: 1);
  }

  @override
  Future<void> play() async {
    playedAssets.add(_asset!);
    playedSpeeds.add(speed);
  }

  @override
  Future<void> setSpeed(double value) async {
    speedRequests.add(value);
    await delaySpeed?.future;
    if (failSpeed) throw StateError('Speed unavailable');
    speed = value;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  Future<void> pause() async {
    pauseCount++;
  }

  void emitState(PlayerState state) => _states.add(state);

  void complete() {
    _states.add(PlayerState(false, ProcessingState.completed));
  }

  @override
  Future<void> dispose() => _states.close();
}

void main() {
  test('speed affects current playback and subsequent sentences without interruption', () async {
    final backend = FakeAudioBackend();
    final service = AudioPlayerService(backend: backend);
    addTearDown(service.dispose);
    expect(service.currentSpeed, 1.0);
    await service.playSentence(
      pageSentences: sentences,
      targetSentence: sentences.first,
    );
    final stops = backend.stopCount;
    await service.setSpeed(0.8);
    expect(service.currentSentenceId, 'one');
    expect(backend.speed, 0.8);
    expect(backend.stopCount, stops);
    await service.playSentence(
      pageSentences: sentences,
      targetSentence: sentences[1],
    );
    expect(backend.playedSpeeds, [1.0, 0.8]);
    await service.setSpeed(1.0);
    expect(backend.speed, 1.0);
    expect(service.currentSpeed, 1.0);
  });

  test(
    'rapid speed changes are serialized and failed changes roll back',
    () async {
      final backend = FakeAudioBackend()..delaySpeed = Completer<void>();
      final service = AudioPlayerService(backend: backend);
      addTearDown(service.dispose);
      final slow = service.setSpeed(0.8);
      final normal = service.setSpeed(1.0);
      await Future<void>.delayed(Duration.zero);
      expect(backend.speedRequests, [0.8]);
      backend.delaySpeed!.complete();
      await Future.wait([slow, normal]);
      expect(backend.speedRequests, [0.8, 1.0]);
      expect(backend.speed, 1.0);
      backend.failSpeed = true;
      await expectLater(service.setSpeed(0.8), throwsStateError);
      expect(service.currentSpeed, 1.0);
      for (final value in [0.0, -1.0, double.nan, double.infinity]) {
        await expectLater(service.setSpeed(value), throwsArgumentError);
      }
    },
  );

  test(
    'continuous page completion fires once and stop invalidates continuation',
    () async {
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
      backend.complete();
      await Future<void>.delayed(Duration.zero);
      expect(completions, hasLength(1));
      expect(service.canContinue(completions.single), isTrue);
      expect(service.currentSentenceId, isNull);
      expect(service.currentBubbleId, isNull);
      expect(completions.single.pageIndex, 8);
      expect(completions.single.lastBubbleId, 'three');
      await service.stop();
      expect(service.canContinue(completions.single), isFalse);
    },
  );

  test('single mode never emits a next-page request', () async {
    final backend = FakeAudioBackend();
    final service = AudioPlayerService(backend: backend);
    addTearDown(service.dispose);
    final completions = <PagePlaybackCompletion>[];
    service.pageCompletions.listen(completions.add);
    await service.playSentence(
      pageSentences: sentences,
      targetSentence: sentences.last,
    );
    backend.complete();
    await Future<void>.delayed(Duration.zero);
    expect(completions, isEmpty);
  });

  test('single mode clears highlight after completion', () async {
    final backend = FakeAudioBackend();
    final service = AudioPlayerService(backend: backend);

    await service.playSentence(
      pageSentences: sentences,
      targetSentence: sentences.first,
    );
    expect(service.currentSentenceId, 'one');
    expect(service.isPlaying, isTrue);
    backend.complete();
    await Future<void>.delayed(Duration.zero);
    expect(service.currentSentenceId, isNull);
    expect(service.isPlaying, isFalse);
    expect(backend.playedAssets, ['assets/one.mp3']);
    service.dispose();
  });

  test(
    'older books advance from selected fallback bubble and end at page end',
    () async {
      final backend = FakeAudioBackend();
      final service = AudioPlayerService(backend: backend);
      await service.playPage(
        page: legacyPage,
        targetBubble: legacyPage.playbackBubbles[1],
      );
      backend.complete();
      await Future<void>.delayed(Duration.zero);
      expect(service.currentSentenceId, isNull);
      expect(service.currentBubbleId, 'three');
      expect(service.isPlaying, isTrue);
      backend.complete();
      await Future<void>.delayed(Duration.zero);
      expect(service.currentSentenceId, isNull);
      expect(backend.playedAssets, ['assets/two.mp3', 'assets/three.mp3']);
      service.dispose();
    },
  );

  test(
    'rapid tap interrupts loading and plays only the latest sentence',
    () async {
      final backend = FakeAudioBackend()..delayFirstLoad = Completer<void>();
      final service = AudioPlayerService(backend: backend);

      final first = service.playSentence(
        pageSentences: sentences,
        targetSentence: sentences.first,
      );
      await Future<void>.delayed(Duration.zero);
      final second = service.playSentence(
        pageSentences: sentences,
        targetSentence: sentences[1],
      );
      expect(service.currentSentenceId, 'two');
      expect(backend.stopCount, 2);
      backend.delayFirstLoad!.complete();
      await Future.wait([first, second]);
      expect(backend.playedAssets, ['assets/two.mp3']);
      service.dispose();
    },
  );

  test('stop invalidates a pending asset load', () async {
    final backend = FakeAudioBackend()..delayFirstLoad = Completer<void>();
    final service = AudioPlayerService(backend: backend);
    final pending = service.playSentence(
      pageSentences: sentences,
      targetSentence: sentences.first,
    );
    await Future<void>.delayed(Duration.zero);

    await service.stop();
    backend.delayFirstLoad!.complete();
    await pending;
    expect(service.currentSentenceId, isNull);
    expect(backend.playedAssets, isEmpty);
    service.dispose();
  });

  test('continuous playback loads whole bubbles, highlights their union, and finishes once', () async {
    final backend = FakeAudioBackend();
    final service = AudioPlayerService(backend: backend);
    addTearDown(service.dispose);
    final completions = <PagePlaybackCompletion>[];
    service.pageCompletions.listen(completions.add);
    await service.setSpeed(0.8);
    await service.playPage(page: bubblePage);
    expect(service.currentMode, PlayMode.continuous);
    expect(service.currentSentenceId, isNull);
    expect(service.currentBubble, same(bubbles.first));
    expect(service.currentBubble!.rect.bottom, 0.4);
    backend.complete();
    await Future<void>.delayed(Duration.zero);
    expect(service.currentBubbleId, 'bubble-two');
    expect(backend.playedAssets, [
      'assets/bubble-one.mp3',
      'assets/bubble-two.mp3',
    ]);
    expect(backend.playedSpeeds, [0.8, 0.8]);
    backend.complete();
    backend.complete();
    await Future<void>.delayed(Duration.zero);
    expect(service.isPlaying, isFalse);
    expect(service.currentBubbleId, isNull);
    expect(completions, hasLength(1));
    expect(completions.single.sentenceId, 'three');
    expect(completions.single.lastBubbleId, 'bubble-two');
    expect(service.canContinue(completions.single), isTrue);
  });

  test('tap immediately switches a playing bubble to single and never resumes the sequence', () async {
    final backend = FakeAudioBackend();
    final service = AudioPlayerService(backend: backend);
    addTearDown(service.dispose);
    final modes = <PlayMode>[];
    final completions = <PagePlaybackCompletion>[];
    service.addListener(() => modes.add(service.currentMode));
    service.pageCompletions.listen(completions.add);
    await service.playPage(page: bubblePage);
    final stops = backend.stopCount;
    final tapped = service.playSentence(
      pageSentences: sentences,
      targetSentence: sentences[1],
    );
    expect(service.currentMode, PlayMode.single);
    expect(modes.last, PlayMode.single);
    expect(service.currentSentenceId, 'two');
    expect(service.currentBubbleId, isNull);
    expect(backend.stopCount, stops + 1);
    // A late completion from the interrupted bubble must not schedule bubble two.
    backend.complete();
    await tapped;
    backend.complete();
    await Future<void>.delayed(Duration.zero);
    expect(backend.playedAssets, ['assets/bubble-one.mp3', 'assets/two.mp3']);
    expect(service.isPlaying, isFalse);
    expect(service.currentSentenceId, isNull);
    expect(completions, isEmpty);
  });

  test(
    'rapid manual taps cancel a loading bubble and only the last tap starts',
    () async {
      final backend = FakeAudioBackend()..delayFirstLoad = Completer<void>();
      final service = AudioPlayerService(backend: backend);
      addTearDown(service.dispose);
      final loading = service.playPage(page: bubblePage);
      await Future<void>.delayed(Duration.zero);
      final firstTap = service.playSentence(
        pageSentences: sentences,
        targetSentence: sentences[1],
      );
      final tapped = service.playSentence(
        pageSentences: sentences,
        targetSentence: sentences.last,
      );
      expect(service.currentMode, PlayMode.single);
      backend.complete();
      backend.delayFirstLoad!.complete();
      await Future.wait([loading, firstTap, tapped]);
      expect(backend.playedAssets, ['assets/three.mp3']);
      backend.complete();
      await Future<void>.delayed(Duration.zero);
      expect(service.currentSentenceId, isNull);
    },
  );

  test(
    'tap cancels the next bubble even after its loading has been queued',
    () async {
      final backend = FakeAudioBackend()..delayNextLoad = Completer<void>();
      final service = AudioPlayerService(backend: backend);
      addTearDown(service.dispose);
      await service.playPage(page: bubblePage);
      backend.complete();
      await Future<void>.delayed(Duration.zero);
      expect(backend.loadedAssets.last, 'assets/bubble-two.mp3');
      final tapped = service.playSentence(
        pageSentences: sentences,
        targetSentence: sentences.first,
      );
      expect(service.currentMode, PlayMode.single);
      backend.delayNextLoad!.complete();
      await tapped;
      expect(backend.playedAssets, ['assets/bubble-one.mp3', 'assets/one.mp3']);
    },
  );

  test('tap invalidates an already delivered next-page completion', () async {
    final backend = FakeAudioBackend();
    final service = AudioPlayerService(backend: backend);
    addTearDown(service.dispose);
    final completions = <PagePlaybackCompletion>[];
    service.pageCompletions.listen(completions.add);
    await service.playPage(page: bubblePage, targetBubble: bubbles.last);
    backend.complete();
    await Future<void>.delayed(Duration.zero);
    expect(service.canContinue(completions.single), isTrue);
    await service.playSentence(
      pageSentences: sentences,
      targetSentence: sentences.first,
    );
    expect(service.currentMode, PlayMode.single);
    expect(service.canContinue(completions.single), isFalse);
  });

  test('a manual tap after focus pause still switches to single', () async {
    final backend = FakeAudioBackend();
    final service = AudioPlayerService(backend: backend);
    addTearDown(service.dispose);
    await service.playPage(page: bubblePage);
    await service.pause();
    expect(service.currentBubbleId, 'bubble-one');
    await service.playSentence(
      pageSentences: sentences,
      targetSentence: sentences.first,
    );
    expect(service.currentMode, PlayMode.single);
    expect(service.currentBubbleId, isNull);
    backend.complete();
    await Future<void>.delayed(Duration.zero);
    expect(backend.playedAssets, ['assets/bubble-one.mp3', 'assets/one.mp3']);
  });

  test('switching mode cancels a bubble that is still loading', () async {
    final backend = FakeAudioBackend()..delayFirstLoad = Completer<void>();
    final service = AudioPlayerService(backend: backend);
    addTearDown(service.dispose);
    final loading = service.playPage(page: bubblePage);
    await Future<void>.delayed(Duration.zero);
    service.setPlayMode(PlayMode.single);
    backend.delayFirstLoad!.complete();
    await loading;
    expect(service.currentMode, PlayMode.single);
    expect(service.currentBubbleId, isNull);
    expect(backend.playedAssets, isEmpty);
  });

  test(
    'a missing bubble audio ends the sequence without switching to child clips',
    () async {
      final backend = FakeAudioBackend()..failedAsset = 'assets/bubble-two.mp3';
      final service = AudioPlayerService(backend: backend);
      addTearDown(service.dispose);
      final completions = <PagePlaybackCompletion>[];
      service.pageCompletions.listen(completions.add);
      await service.playPage(page: bubblePage);
      backend.complete();
      await Future<void>.delayed(Duration.zero);
      expect(service.currentBubbleId, isNull);
      expect(service.isPlaying, isFalse);
      expect(backend.playedAssets, ['assets/bubble-one.mp3']);
      expect(completions, isEmpty);
    },
  );
}
