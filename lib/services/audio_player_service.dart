import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/textbook.dart';
import 'audio_interruption_source.dart';

enum PlayMode { single, continuous }

class PagePlaybackCompletion {
  const PagePlaybackCompletion(
    this.generation,
    this.sentenceId, {
    this.pageIndex,
    this.lastBubbleId,
  });
  final int generation;

  /// Last child sentence; retained for callers reading older books.
  final String sentenceId;
  final int? pageIndex;
  final String? lastBubbleId;
}

/// Small boundary around just_audio so scheduling can be tested without a device.
abstract class AudioPlaybackBackend {
  Stream<PlayerState> get playerStateStream;

  Future<Duration?> setAsset(String assetPath);

  Future<void> play();

  Future<void> pause();

  Future<void> setSpeed(double speed);

  Future<void> stop();

  Future<void> dispose();
}

class JustAudioPlaybackBackend implements AudioPlaybackBackend {
  JustAudioPlaybackBackend({AudioPlayer? player})
    : _player = player ?? AudioPlayer(handleInterruptions: false);

  final AudioPlayer _player;

  @override
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  @override
  Future<Duration?> setAsset(String assetPath) => _player.setAsset(assetPath);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();
}

class AudioPlayerService extends ChangeNotifier {
  AudioPlayerService({
    AudioPlaybackBackend? backend,
    AudioInterruptionSource? interruptionSource,
  }) : _backend = backend ?? JustAudioPlaybackBackend(),
       _interruptions =
           interruptionSource ??
           (backend == null ? SystemAudioInterruptionSource() : null) {
    _stateSubscription = _backend.playerStateStream.listen(_onPlayerState);
    _pauseSubscription = _interruptions?.pauseRequests.listen((_) {
      unawaited(pause());
    });
  }

  final AudioPlaybackBackend _backend;
  late final StreamSubscription<PlayerState> _stateSubscription;
  final AudioInterruptionSource? _interruptions;
  StreamSubscription<void>? _pauseSubscription;
  bool _isForeground = true;

  String? _currentSentenceId;
  DialogueBubble? _currentBubble;
  bool _isPlaying = false;
  PlayMode _currentMode = PlayMode.single;
  double _currentSpeed = 1.0;
  double _appliedSpeed = 1.0;
  int _speedRequest = 0;
  Future<void> _pendingSpeed = Future<void>.value();
  int _continuationGeneration = 0;
  final _pageCompletions = StreamController<PagePlaybackCompletion>.broadcast(
    sync: true,
  );
  TextbookPage? _page;
  List<DialogueBubble> _pageBubbles = const [];
  int _currentBubbleIndex = -1;
  int _requestId = 0;
  int? _activePlaybackRequest;
  int? _observedPlayingRequest;
  Future<void> _pendingLoad = Future<void>.value();
  bool _disposed = false;

  String? get currentSentenceId => _currentSentenceId;
  String? get currentBubbleId => _currentBubble?.id;
  DialogueBubble? get currentBubble => _currentBubble;
  bool get isPlaying => _isPlaying;
  PlayMode get currentMode => _currentMode;
  double get currentSpeed => _currentSpeed;
  Stream<PagePlaybackCompletion> get pageCompletions => _pageCompletions.stream;

  bool canContinue(PagePlaybackCompletion completion) =>
      !_disposed &&
      _isForeground &&
      _currentMode == PlayMode.continuous &&
      completion.generation == _continuationGeneration;

  Future<void> setSpeed(double speed) {
    if (_disposed) {
      return Future.error(StateError('AudioPlayerService has been disposed.'));
    }
    if (!speed.isFinite || speed <= 0) {
      return Future.error(
        ArgumentError.value(speed, 'speed', 'Must be finite and positive'),
      );
    }
    final request = ++_speedRequest;
    _currentSpeed = speed;
    notifyListeners();
    final result = _pendingSpeed.then((_) async {
      if (_disposed) return;
      await _backend.setSpeed(speed);
      _appliedSpeed = speed;
    });
    _pendingSpeed = result.catchError((Object error) {
      if (!_disposed && request == _speedRequest) {
        _currentSpeed = _appliedSpeed;
        notifyListeners();
      }
    });
    return result;
  }

  void setPlayMode(PlayMode mode) {
    if (_disposed) throw StateError('AudioPlayerService has been disposed.');
    if (_currentMode == mode) return;
    ++_continuationGeneration;
    _currentMode = mode;
    if (mode == PlayMode.single && _currentBubble != null) {
      // A mode change must also invalidate a bubble whose asset is still loading.
      unawaited(stop());
      return;
    }
    notifyListeners();
  }

  /// Manual point reading always wins over a running or queued page sequence.
  Future<void> playSentence({
    required List<PointSentence> pageSentences,
    required PointSentence targetSentence,
  }) {
    if (_disposed) {
      return Future.error(StateError('AudioPlayerService has been disposed.'));
    }
    final index = pageSentences.indexWhere(
      (sentence) => sentence.id == targetSentence.id,
    );
    if (index < 0) {
      return Future.error(
        ArgumentError.value(targetSentence.id, 'targetSentence', 'Not on page'),
      );
    }

    ++_continuationGeneration;
    _currentMode = PlayMode.single;
    _page = null;
    _pageBubbles = const [];
    _currentBubbleIndex = -1;
    _currentBubble = null;
    if (!_isForeground) {
      notifyListeners();
      return Future<void>.value();
    }
    _currentSentenceId = targetSentence.id;
    return _loadAudio(targetSentence.audioPath);
  }

  /// Continuous reading uses a complete synthesized paragraph for each bubble.
  /// Automatic same-page continuation calls _playBubble, never playSentence.
  Future<void> playPage({
    required TextbookPage page,
    DialogueBubble? targetBubble,
  }) {
    if (_disposed) {
      return Future.error(StateError('AudioPlayerService has been disposed.'));
    }
    if (!_isForeground) return Future<void>.value();
    final bubbles = List<DialogueBubble>.unmodifiable(page.playbackBubbles);
    final index = targetBubble == null
        ? 0
        : bubbles.indexWhere((bubble) => bubble.id == targetBubble.id);
    if (targetBubble != null && index < 0) {
      return Future.error(
        ArgumentError.value(targetBubble.id, 'targetBubble', 'Not on page'),
      );
    }
    ++_continuationGeneration;
    _currentMode = PlayMode.continuous;
    if (bubbles.isEmpty) return stop();
    _page = page;
    _pageBubbles = bubbles;
    return _playBubble(index);
  }

  Future<void> _playBubble(int index) {
    _currentBubbleIndex = index;
    _currentBubble = _pageBubbles[index];
    _currentSentenceId = null;
    return _loadAudio(_currentBubble!.audioPath);
  }

  Future<void> _loadAudio(String audioPath) {
    final request = ++_requestId;
    _activePlaybackRequest = null;
    _observedPlayingRequest = null;
    _isPlaying = false;
    notifyListeners();

    // Interrupt sound immediately, even if a previous asset load is pending.
    final interruption = _backend.stop();
    return _enqueueLoad(() async {
      try {
        await interruption;
        if (request != _requestId || _disposed) return;
        await _interruptions?.initialize();
        if (request != _requestId || _disposed) return;
        await _backend.setAsset(audioPath);
        await _pendingSpeed;
        if (request != _requestId || _disposed) return;

        _activePlaybackRequest = request;
        _isPlaying = true;
        notifyListeners();
        // just_audio's play() future completes when playback ends, so do not
        // await it here; completion is handled through playerStateStream.
        unawaited(
          _backend.play().then(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {
              _onPlaybackError(request, error);
            },
          ),
        );
      } catch (error) {
        if (request != _requestId || _disposed) return;
        _clearPlayback();
        rethrow;
      }
    });
  }

  Future<void> stop() {
    if (_disposed) return Future<void>.value();
    ++_requestId;
    ++_continuationGeneration;
    _clearPlayback();
    return _backend.stop();
  }

  /// Suspend loading and continuation while retaining the selected sentence/bubble.
  /// The next deliberate sentence tap/replay starts it from the beginning.
  Future<void> pause() async {
    if (_disposed) return;
    ++_requestId;
    ++_continuationGeneration;
    _activePlaybackRequest = null;
    _observedPlayingRequest = null;
    _isPlaying = false;
    notifyListeners();
    try {
      await _backend.pause();
    } catch (error) {
      debugPrint('AudioPlayerService: could not pause: $error');
    }
  }

  void setForeground(bool foreground) {
    if (_disposed) return;
    _isForeground = foreground;
    if (!foreground) unawaited(pause());
  }

  Future<void> _enqueueLoad(Future<void> Function() action) {
    final result = _pendingLoad.then((_) => action());
    _pendingLoad = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }

  void _onPlayerState(PlayerState state) {
    if (_disposed) return;
    if (state.processingState != ProcessingState.completed) {
      if (state.playing && _activePlaybackRequest == _requestId) {
        _observedPlayingRequest = _requestId;
      }
      // Also reflect native pauses / refused focus instead of showing playback
      // as active forever. Asset-loading events have no active request yet.
      if (_activePlaybackRequest == _requestId &&
          _observedPlayingRequest == _requestId &&
          _isPlaying &&
          !state.playing) {
        unawaited(pause());
      }
      return;
    }
    if (_activePlaybackRequest != _requestId) return;
    _activePlaybackRequest = null;

    if (_currentMode == PlayMode.continuous &&
        _currentBubble != null &&
        _currentBubbleIndex + 1 < _pageBubbles.length) {
      unawaited(
        _playBubble(_currentBubbleIndex + 1).then(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            debugPrint(
              'AudioPlayerService: could not play next bubble: $error',
            );
          },
        ),
      );
    } else if (_currentMode == PlayMode.continuous && _currentBubble != null) {
      final lastBubble = _currentBubble!;
      final completion = PagePlaybackCompletion(
        _continuationGeneration,
        lastBubble.sentenceIds.lastOrNull ?? lastBubble.id,
        pageIndex: _page?.pageIndex,
        lastBubbleId: lastBubble.id,
      );
      _clearPlayback();
      unawaited(_finishPage(completion));
    } else {
      unawaited(stop());
    }
  }

  Future<void> _finishPage(PagePlaybackCompletion completion) async {
    try {
      await _backend.stop();
      if (canContinue(completion)) _pageCompletions.add(completion);
    } catch (error) {
      debugPrint('AudioPlayerService: could not finish page: $error');
    }
  }

  void _onPlaybackError(int request, Object error) {
    if (_disposed || request != _requestId) return;
    debugPrint('AudioPlayerService: playback failed: $error');
    unawaited(stop());
  }

  void _clearPlayback() {
    _activePlaybackRequest = null;
    _observedPlayingRequest = null;
    _currentSentenceId = null;
    _currentBubble = null;
    _isPlaying = false;
    _page = null;
    _pageBubbles = const [];
    _currentBubbleIndex = -1;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_requestId;
    ++_continuationGeneration;
    unawaited(_pageCompletions.close());
    unawaited(_stateSubscription.cancel());
    unawaited(_pauseSubscription?.cancel());
    unawaited(_interruptions?.dispose());
    unawaited(_backend.dispose());
    super.dispose();
  }
}
