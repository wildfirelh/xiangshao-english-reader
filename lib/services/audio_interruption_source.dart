import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

export 'package:audio_session/audio_session.dart'
    show AudioInterruptionEvent, AudioInterruptionType;

abstract class AudioInterruptionSource {
  Stream<AudioInterruptionEvent> get interruptions;
  Future<void> initialize();
  Future<void> dispose();
}

/// Owns listeners, not the shared AudioSession. Pause end never resumes.
class SystemAudioInterruptionSource implements AudioInterruptionSource {
  SystemAudioInterruptionSource({this.session});

  final AudioSession? session;

  final _events = StreamController<AudioInterruptionEvent>.broadcast(
    sync: true,
  );
  StreamSubscription<AudioInterruptionEvent>? _interruptions;
  StreamSubscription<void>? _noisy;
  bool _disposed = false;
  Future<void>? _initializing;

  @override
  Stream<AudioInterruptionEvent> get interruptions => _events.stream;

  @override
  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    final session = this.session ?? await AudioSession.instance;
    if (_disposed) return;
    _interruptions = session.interruptionEventStream.listen(
      (event) {
        if (!_disposed) _events.add(event);
      },
      onError: (Object error) {
        debugPrint('AudioInterruptionSource: focus event failed: $error');
      },
    );
    _noisy = session.becomingNoisyEventStream.listen(
      (_) {
        if (!_disposed) {
          _events.add(
            AudioInterruptionEvent(true, AudioInterruptionType.pause),
          );
        }
      },
      onError: (Object error) {
        debugPrint('AudioInterruptionSource: headphone event failed: $error');
      },
    );
    await session.configure(
      const AudioSessionConfiguration.speech().copyWith(
        androidWillPauseWhenDucked: false,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _interruptions?.cancel();
    await _noisy?.cancel();
    await _events.close();
  }
}
