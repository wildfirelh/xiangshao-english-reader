import 'dart:async';

import 'package:audio_session/audio_session.dart';

abstract class AudioInterruptionSource {
  Stream<void> get pauseRequests;
  Future<void> initialize();
  Future<void> dispose();
}

/// Owns listeners, not the shared AudioSession. Interruption end never resumes.
class SystemAudioInterruptionSource implements AudioInterruptionSource {
  SystemAudioInterruptionSource();

  final _pauses = StreamController<void>.broadcast(sync: true);
  StreamSubscription<AudioInterruptionEvent>? _interruptions;
  StreamSubscription<void>? _noisy;
  bool _disposed = false;
  Future<void>? _initializing;

  @override
  Stream<void> get pauseRequests => _pauses.stream;

  @override
  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    final session = await AudioSession.instance;
    if (_disposed) return;
    _interruptions = session.interruptionEventStream.listen((event) {
      // Spoken lessons pause even for duck requests so no words are missed.
      if (!_disposed && event.begin) _pauses.add(null);
    });
    _noisy = session.becomingNoisyEventStream.listen((_) {
      if (!_disposed) _pauses.add(null);
    });
    await session.configure(const AudioSessionConfiguration.speech());
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _interruptions?.cancel();
    await _noisy?.cancel();
    await _pauses.close();
  }
}
