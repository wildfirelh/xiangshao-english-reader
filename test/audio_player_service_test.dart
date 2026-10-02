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

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;

  @override
  Future<Duration?> setAsset(String assetPath) async {
    loadedAssets.add(assetPath);
    if (loadedAssets.length == 1 && delayFirstLoad != null) {
      await delayFirstLoad!.future;
    }
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
      service.setPlayMode(PlayMode.continuous);
      await service.playSentence(
        pageSentences: sentences,
        targetSentence: sentences.last,
      );
      backend.complete();
      backend.complete();
      await Future<void>.delayed(Duration.zero);
      expect(completions, hasLength(1));
      expect(service.canContinue(completions.single), isTrue);
      expect(service.currentSentenceId, isNull);
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
    'continuous mode advances from selected sentence and ends at page end',
    () async {
      final backend = FakeAudioBackend();
      final service = AudioPlayerService(backend: backend);
      service.setPlayMode(PlayMode.continuous);

      await service.playSentence(
        pageSentences: sentences,
        targetSentence: sentences[1],
      );
      backend.complete();
      await Future<void>.delayed(Duration.zero);
      expect(service.currentSentenceId, 'three');
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
}
