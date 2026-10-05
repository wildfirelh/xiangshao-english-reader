import 'dart:async';

import 'package:english_point_reading/services/audio_player_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_player_service_test.dart' show FakeAudioBackend, bubblePage;

class _PracticeBackend extends FakeAudioBackend
    implements AudioFilePlaybackBackend {
  final loadedFiles = <String>[];

  @override
  Future<Duration?> setFilePath(String path) {
    loadedFiles.add(path);
    return super.setAsset('file:$path');
  }
}

void main() {
  test(
    'A/B replaces queued reading, preserves mode and never advances pages',
    () async {
      final backend = _PracticeBackend();
      final audio = AudioPlayerService(backend: backend);
      var starts = 0;
      var pages = 0;
      final startsSubscription = audio.playbackStarts.listen((_) => starts++);
      final pagesSubscription = audio.pageCompletions.listen((_) => pages++);
      await audio.playSequential(page: bubblePage);
      final readingStarts = starts;
      await audio.playPracticeAsset('assets/reference.mp3');
      expect(audio.currentMode, PlayMode.sequential);
      expect(audio.currentSentenceId, isNull);
      await audio.playRecordingFile('/private/recording.wav');
      expect(backend.loadedFiles, ['/private/recording.wav']);
      expect(backend.playedAssets.last, 'file:/private/recording.wav');
      expect(starts, readingStarts);
      backend.complete();
      await Future<void>.delayed(Duration.zero);
      expect(pages, 0);
      expect(audio.isPlaying, isFalse);
      await startsSubscription.cancel();
      await pagesSubscription.cancel();
      audio.dispose();
    },
  );

  test('stop while recording preview loads prevents late autoplay', () async {
    final backend = _PracticeBackend()..delayFirstLoad = Completer<void>();
    final audio = AudioPlayerService(backend: backend);
    final loading = audio.playRecordingFile('/private/recording.wav');
    await Future<void>.delayed(Duration.zero);
    await audio.stop();
    backend.delayFirstLoad!.complete();
    await loading;
    expect(backend.playedAssets, isEmpty);
    expect(audio.isPlaying, isFalse);
    audio.dispose();
  });

  test(
    'asset-only backend rejects local preview without corrupting state',
    () async {
      final backend = FakeAudioBackend();
      final audio = AudioPlayerService(backend: backend);
      await expectLater(
        audio.playRecordingFile('/private/a.wav'),
        throwsUnsupportedError,
      );
      expect(audio.isPlaying, isFalse);
      expect(backend.loadedAssets, isEmpty);
      audio.dispose();
    },
  );
}
