import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/textbook.dart';
import 'audio_interruption_source.dart';
import 'playback_preferences_store.dart';

enum PlayMode { single, fullPage, sequential }

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

  double get volume;

  Future<void> setVolume(double volume);

  Future<Duration?> setAsset(String assetPath);

  Future<void> play();

  Future<void> pause();

  Future<void> setSpeed(double speed);

  Future<void> stop();

  Future<void> dispose();
}

/// Optional local-file capability keeps existing asset-only test backends valid.
abstract class AudioFilePlaybackBackend {
  Future<Duration?> setFilePath(String filePath);
}

class JustAudioPlaybackBackend
    implements AudioPlaybackBackend, AudioFilePlaybackBackend {
  JustAudioPlaybackBackend({AudioPlayer? player})
    : _player = player ?? AudioPlayer(handleInterruptions: false);

  final AudioPlayer _player;

  @override
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  @override
  double get volume => _player.volume;

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<Duration?> setAsset(String assetPath) => _player.setAsset(assetPath);

  @override
  Future<Duration?> setFilePath(String filePath) =>
      _player.setFilePath(filePath);

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
    PlaybackPreferencesStore? preferencesStore,
  }) : _backend = backend ?? JustAudioPlaybackBackend(),
       _preferences =
           preferencesStore ??
           (backend == null
               ? SharedPreferencesPlaybackPreferencesStore.instance
               : InMemoryPlaybackPreferencesStore()),
       _interruptions =
           interruptionSource ??
           (backend == null ? SystemAudioInterruptionSource() : null) {
    _stateSubscription = _backend.playerStateStream.listen(_onPlayerState);
    _interruptionSubscription = _interruptions?.interruptions.listen(
      _onInterruption,
      onError: (Object error) {
        debugPrint('AudioPlayerService: audio focus event failed: $error');
      },
    );
    _ready = _restoreSpeedPreferences();
  }

  final AudioPlaybackBackend _backend;
  final PlaybackPreferencesStore _preferences;
  late final Future<void> _ready;
  late final StreamSubscription<PlayerState> _stateSubscription;
  final AudioInterruptionSource? _interruptions;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  bool _isForeground = true;

  static const supportedSpeeds = <double>[0.5, 0.8, 1.0, 1.2, 1.5, 2.0];
  Future<void> get ready => _ready;
  bool _ducked = false;
  double? _volumeBeforeDuck;
  int _volumeGeneration = 0;
  Future<void> _pendingVolume = Future<void>.value();

  String? _currentSentenceId;
  DialogueBubble? _currentBubble;
  bool _isPlaying = false;
  bool _isLoading = false;
  bool _isPaused = false;
  bool _assetReady = false;
  PlayMode _currentMode = PlayMode.single;
  double _currentSpeed = 1.0;
  double _appliedSpeed = 1.0;
  double _persistedSpeed = 1.0;
  int _speedRequest = 0;
  Future<void> _pendingSpeed = Future<void>.value();
  Future<void> _pendingPreferences = Future<void>.value();
  int _continuationGeneration = 0;
  final _pageCompletions = StreamController<PagePlaybackCompletion>.broadcast(
    sync: true,
  );
  TextbookPage? _page;
  List<DialogueBubble> _pageBubbles = const [];
  int _currentBubbleIndex = -1;
  List<PointSentence> _sequenceSentences = const [];
  int _currentSentenceIndex = -1;
  int _requestId = 0;
  int? _activePlaybackRequest;
  int? _observedPlayingRequest;
  int? _reportedStartRequest;
  final _playbackStarts = StreamController<void>.broadcast(sync: true);
  Future<void> _pendingLoad = Future<void>.value();
  Future<void> _pendingTransport = Future<void>.value();
  int _transportRequest = 0;
  int _pendingInterrupts = 0;
  bool _disposed = false;
  bool _isPracticeAudio = false;

  String? get currentSentenceId => _currentSentenceId;
  String? get currentBubbleId => _currentBubble?.id;
  DialogueBubble? get currentBubble => _currentBubble;
  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading && !_isPaused;
  bool get isPaused => _isPaused;

  /// An explicit resume continues the selected asset, including a paused load.
  bool get canResume =>
      !_disposed &&
      _isForeground &&
      _isPaused &&
      (_currentSentenceId != null || _currentBubble != null);
  PlayMode get currentMode => _currentMode;
  double get currentSpeed => _currentSpeed;
  Stream<PagePlaybackCompletion> get pageCompletions => _pageCompletions.stream;

  /// Emitted once per asset only after native playback reaches the ready state.
  Stream<void> get playbackStarts => _playbackStarts.stream;

  bool canContinue(PagePlaybackCompletion completion) =>
      !_disposed &&
      _isForeground &&
      !_isPaused &&
      _currentMode == PlayMode.sequential &&
      completion.generation == _continuationGeneration;

  Future<void> setSpeed(double speed) {
    if (_disposed) {
      return Future.error(StateError('AudioPlayerService has been disposed.'));
    }
    if (!supportedSpeeds.contains(speed)) {
      return Future.error(
        ArgumentError.value(
          speed,
          'speed',
          'Must be a supported playback speed',
        ),
      );
    }
    final request = ++_speedRequest;
    _currentSpeed = speed;
    notifyListeners();
    final applied = _pendingSpeed.then((_) async {
      if (_disposed) return;
      try {
        await _backend.setSpeed(speed);
        _appliedSpeed = speed;
      } catch (error) {
        if (!_disposed && request == _speedRequest) {
          _currentSpeed = _appliedSpeed;
          notifyListeners();
        }
        rethrow;
      }
    });
    _pendingSpeed = applied.catchError((Object _) {});
    // Disk writes are ordered separately: a slow save must not delay a new
    // selection taking effect on speech that is already playing.
    final result = _pendingPreferences.then((_) async {
      await applied;
      await ready;
      if (_disposed) return;
      final previousPreference = _persistedSpeed;
      try {
        await _preferences.saveSpeed(speed);
        _persistedSpeed = speed;
      } catch (error) {
        try {
          final rollback = _pendingSpeed.then((_) async {
            // An old failed save must never undo a newer user selection.
            if (_disposed || request != _speedRequest) return;
            await _backend.setSpeed(previousPreference);
            _appliedSpeed = previousPreference;
          });
          _pendingSpeed = rollback.catchError((Object _) {});
          await rollback;
        } catch (rollbackError) {
          debugPrint(
            'AudioPlayerService: could not restore speed: $rollbackError',
          );
        }
        if (!_disposed) {
          try {
            await _preferences.saveSpeed(previousPreference);
          } catch (rollbackError) {
            debugPrint(
              'AudioPlayerService: could not restore saved speed: $rollbackError',
            );
          }
          if (request == _speedRequest) {
            _currentSpeed = _appliedSpeed;
            notifyListeners();
          }
        }
        rethrow;
      }
    });
    _pendingPreferences = result.catchError((Object _) {});
    return result;
  }

  Future<void> _restoreSpeedPreferences() async {
    try {
      final saved = await _preferences.loadSpeed();
      if (_disposed || !supportedSpeeds.contains(saved)) return;
      final validSpeed = saved!;
      _persistedSpeed = validSpeed;
      if (_speedRequest != 0) return;
      final restored = _pendingSpeed.then((_) async {
        if (_disposed || _speedRequest != 0) return;
        await _backend.setSpeed(validSpeed);
        _appliedSpeed = validSpeed;
        if (!_disposed && _speedRequest == 0) {
          _currentSpeed = validSpeed;
          notifyListeners();
        }
      });
      _pendingSpeed = restored.catchError((Object _) {});
      await restored;
    } catch (error) {
      debugPrint('AudioPlayerService: could not restore saved speed: $error');
    }
  }

  void _onInterruption(AudioInterruptionEvent event) {
    if (_disposed) return;
    if (!event.begin) {
      // AudioSession can label focus regained as pause-end after a new clip
      // activates focus. The active duck state decides whether to restore.
      if (_ducked) {
        unawaited(_restoreDuckedVolume(smooth: true));
      }
    } else if (event.type == AudioInterruptionType.duck) {
      if (_isForeground) _beginDucking();
    } else {
      // Calls, unknown focus loss and unplugged headphones suspend the lesson.
      // Their end only changes system focus; it never resumes playback.
      unawaited(pause());
    }
  }

  double? _readVolume() {
    try {
      final volume = _backend.volume;
      return volume.isFinite && volume >= 0 ? volume : null;
    } catch (error) {
      debugPrint('AudioPlayerService: could not read volume: $error');
      return null;
    }
  }

  void _beginDucking() {
    // Retain the first volume even if another duck arrives during restoration.
    _volumeBeforeDuck ??= _readVolume();
    final original = _volumeBeforeDuck;
    if (original == null) return;
    _ducked = true;
    final generation = ++_volumeGeneration;
    final quiet = original < 0.25 ? original : 0.25;
    unawaited(_writeVolume(quiet, generation));
  }

  Future<bool> _writeVolume(double volume, int generation) {
    final write = _pendingVolume.then((_) async {
      if (_disposed || generation != _volumeGeneration) return false;
      try {
        await _backend.setVolume(volume);
        return true;
      } catch (error) {
        if (!_disposed) {
          debugPrint('AudioPlayerService: could not change volume: $error');
        }
        return false;
      }
    });
    // Native writes finish in order, and stale fade steps are skipped. Failures
    // are contained here so focus callbacks cannot create an unhandled future.
    _pendingVolume = write.then<void>((_) {});
    return write;
  }

  Future<void> _restoreDuckedVolume({required bool smooth}) async {
    _ducked = false;
    final generation = ++_volumeGeneration;
    final original = _volumeBeforeDuck;
    if (original == null) return;
    await _pendingVolume;
    if (_disposed || generation != _volumeGeneration) return;
    final start = _readVolume() ?? original;
    var restored = false;
    if (smooth && start != original) {
      // Six short steps make the return gentle without delaying a new duck.
      for (var step = 1; step <= 6; step++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (_disposed || generation != _volumeGeneration) return;
        restored = await _writeVolume(
          start + (original - start) * step / 6,
          generation,
        );
      }
    } else {
      restored = await _writeVolume(original, generation);
    }
    if (restored && !_disposed && generation == _volumeGeneration) {
      _volumeBeforeDuck = null;
    }
  }

  /// A deliberate mode selection cancels sound, loading and page continuation.
  void setPlayMode(PlayMode mode) {
    if (_disposed) throw StateError('AudioPlayerService has been disposed.');
    ++_requestId;
    ++_transportRequest;
    ++_continuationGeneration;
    _currentMode = mode;
    _clearPlayback();
    // Keep an active notification's duck across a subsequent sentence tap.
    unawaited(
      _interruptPlayback(_backend.stop).catchError((Object error) {
        debugPrint('AudioPlayerService: could not change mode: $error');
      }),
    );
  }

  /// Manual point reading always wins over a running or queued page sequence.
  Future<void> playSentence({
    required List<PointSentence> pageSentences,
    required PointSentence targetSentence,
  }) {
    if (_disposed) {
      return Future.error(StateError('AudioPlayerService has been disposed.'));
    }
    if (!pageSentences.any((sentence) => sentence.id == targetSentence.id)) {
      return Future.error(
        ArgumentError.value(targetSentence.id, 'targetSentence', 'Not on page'),
      );
    }
    if (!_isForeground) return Future<void>.value();

    ++_continuationGeneration;
    _isPracticeAudio = false;
    _currentMode = PlayMode.single;
    _page = null;
    _pageBubbles = const [];
    _sequenceSentences = const [];
    _currentBubbleIndex = -1;
    _currentSentenceIndex = -1;
    _currentBubble = null;
    _currentSentenceId = targetSentence.id;
    return _loadAudio(targetSentence.audioPath);
  }

  /// Read complete synthesized bubbles on this page, then stop at its end.
  Future<void> playPage({
    required TextbookPage page,
    DialogueBubble? targetBubble,
  }) {
    if (_disposed) {
      return Future.error(StateError('AudioPlayerService has been disposed.'));
    }
    final bubbles = List<DialogueBubble>.unmodifiable(page.playbackBubbles);
    final index = targetBubble == null
        ? 0
        : bubbles.indexWhere((bubble) => bubble.id == targetBubble.id);
    if (targetBubble != null && index < 0) {
      return Future.error(
        ArgumentError.value(targetBubble.id, 'targetBubble', 'Not on page'),
      );
    }
    if (!_isForeground) return Future<void>.value();
    ++_continuationGeneration;
    _isPracticeAudio = false;
    _currentMode = PlayMode.fullPage;
    if (bubbles.isEmpty) return stop();
    _page = page;
    _pageBubbles = bubbles;
    _sequenceSentences = const [];
    _currentSentenceIndex = -1;
    return _playBubble(index);
  }

  /// Read exact child clips in bubble order, starting at the selected sentence.
  /// The reader may use pageCompletions to continue on the following page.
  Future<void> playSequential({
    required TextbookPage page,
    PointSentence? targetSentence,
  }) {
    if (_disposed) {
      return Future.error(StateError('AudioPlayerService has been disposed.'));
    }
    final ordered = _orderedSentences(page);
    final index = targetSentence == null
        ? 0
        : ordered.indexWhere((sentence) => sentence.id == targetSentence.id);
    if (targetSentence != null && index < 0) {
      return Future.error(
        ArgumentError.value(targetSentence.id, 'targetSentence', 'Not on page'),
      );
    }
    if (!_isForeground) return Future<void>.value();
    ++_continuationGeneration;
    _isPracticeAudio = false;
    _currentMode = PlayMode.sequential;
    if (ordered.isEmpty) return stop();
    _page = page;
    _pageBubbles = List<DialogueBubble>.unmodifiable(page.playbackBubbles);
    _sequenceSentences = ordered;
    _currentBubbleIndex = -1;
    _currentBubble = null;
    return _playSequentialSentence(index);
  }

  List<PointSentence> _orderedSentences(TextbookPage page) {
    final byId = <String, PointSentence>{
      for (final sentence in page.sentences) sentence.id: sentence,
    };
    final seen = <String>{};
    final ordered = <PointSentence>[];
    for (final bubble in page.playbackBubbles) {
      for (final id in bubble.sentenceIds) {
        final sentence = byId[id];
        if (sentence != null && seen.add(id)) ordered.add(sentence);
      }
    }
    // Retain readable sentences omitted by an older/incomplete bubble mapping.
    for (final sentence in page.sentences) {
      if (seen.add(sentence.id)) ordered.add(sentence);
    }
    return List<PointSentence>.unmodifiable(ordered);
  }

  Future<void> _playBubble(int index) {
    _currentBubbleIndex = index;
    _currentBubble = _pageBubbles[index];
    _currentSentenceId = null;
    return _loadAudio(_currentBubble!.audioPath);
  }

  Future<void> _playSequentialSentence(int index) {
    _currentSentenceIndex = index;
    _currentSentenceId = _sequenceSentences[index].id;
    _currentBubble = null;
    return _loadAudio(_sequenceSentences[index].audioPath);
  }

  /// A/B practice uses the same exclusive player without starting a reading queue
  /// or counting an extra textbook reading session. Keep the user's mode choice.
  Future<void> playPracticeAsset(String assetPath) =>
      _playPracticeAudio(assetPath, localFile: false);

  Future<void> playRecordingFile(String filePath) =>
      _playPracticeAudio(filePath, localFile: true);

  Future<void> _playPracticeAudio(String path, {required bool localFile}) {
    if (_disposed) return Future.error(StateError('Player has been disposed.'));
    if (path.isEmpty) {
      return Future.error(ArgumentError('Audio path is empty.'));
    }
    if (localFile && _backend is! AudioFilePlaybackBackend) {
      return Future.error(UnsupportedError('Local playback is unavailable.'));
    }
    if (!_isForeground) return Future<void>.value();
    ++_continuationGeneration;
    _page = null;
    _pageBubbles = const [];
    _sequenceSentences = const [];
    _currentBubbleIndex = -1;
    _currentSentenceIndex = -1;
    _currentBubble = null;
    _currentSentenceId = null;
    _isPracticeAudio = true;
    return _loadAudio(path, localFile: localFile);
  }

  Future<void> _loadAudio(String audioPath, {bool localFile = false}) {
    final request = ++_requestId;
    ++_transportRequest;
    _activePlaybackRequest = null;
    _observedPlayingRequest = null;
    _assetReady = false;
    _isLoading = true;
    _isPaused = false;
    _isPlaying = false;
    notifyListeners();

    // Stop immediately; a stale setAsset still has to finish before another load.
    final interruption = _interruptPlayback(_backend.stop);
    return _enqueueLoad(() async {
      try {
        await interruption;
        await _pendingTransport;
        if (request != _requestId || _disposed) return;
        await ready;
        if (request != _requestId || _disposed) return;
        await _interruptions?.initialize();
        if (request != _requestId || _disposed) return;
        if (localFile) {
          await (_backend as AudioFilePlaybackBackend).setFilePath(audioPath);
        } else {
          await _backend.setAsset(audioPath);
        }
        await _pendingSpeed;
        await _pendingVolume;
        await _pendingTransport;
        if (request != _requestId || _disposed) return;

        _assetReady = true;
        if (_isPaused || !_isForeground) {
          _isLoading = false;
          notifyListeners();
          return;
        }
        _startPlayback(request);
      } catch (error) {
        if (request != _requestId || _disposed) return;
        ++_continuationGeneration;
        _clearPlayback();
        rethrow;
      }
    });
  }

  void _startPlayback(int request) {
    if (_disposed ||
        request != _requestId ||
        _isPaused ||
        !_isForeground ||
        !_assetReady ||
        _pendingInterrupts != 0 ||
        _activePlaybackRequest == request) {
      return;
    }
    _activePlaybackRequest = request;
    _observedPlayingRequest = null;
    _isLoading = false;
    _isPlaying = true;
    notifyListeners();
    if (_activePlaybackRequest != request ||
        request != _requestId ||
        _isPaused ||
        !_isForeground ||
        _disposed) {
      return;
    }
    // just_audio's play future lasts until the clip ends or is paused/stopped.
    unawaited(
      _backend.play().then(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          _onPlaybackError(request, error);
        },
      ),
    );
  }

  /// Preserve the native asset and cursor; pending loads finish without playing.
  Future<void> pause() async {
    if (_disposed) return;
    ++_transportRequest;
    ++_continuationGeneration;
    _activePlaybackRequest = null;
    _observedPlayingRequest = null;
    _isPaused = true;
    _isPlaying = false;
    notifyListeners();
    final restoreVolume = _restoreDuckedVolume(smooth: false);
    try {
      await _interruptPlayback(_backend.pause);
      await restoreVolume;
    } catch (error) {
      debugPrint('AudioPlayerService: could not pause: $error');
    }
  }

  /// Resume the same asset at its native cursor, including after focus loss.
  Future<void> resume() async {
    if (!canResume) return;
    final request = _requestId;
    final transport = ++_transportRequest;
    _isPaused = false;
    _isLoading = true;
    notifyListeners();
    // A rapid pause/resume must wait for the outstanding native pause and load.
    await _pendingLoad;
    await _pendingTransport;
    await _pendingSpeed;
    await _pendingVolume;
    if (_disposed ||
        request != _requestId ||
        transport != _transportRequest ||
        _isPaused ||
        !_isForeground) {
      return;
    }
    _startPlayback(request);
  }

  Future<void> stop() {
    if (_disposed) return Future<void>.value();
    ++_requestId;
    ++_transportRequest;
    ++_continuationGeneration;
    _clearPlayback();
    return Future.wait([
      _interruptPlayback(_backend.stop),
      _restoreDuckedVolume(smooth: false),
    ]).then((_) {});
  }

  void setForeground(bool foreground) {
    if (_disposed) return;
    _isForeground = foreground;
    if (!foreground) unawaited(pause());
  }

  /// Native interrupts are invoked immediately and awaited before any play.
  Future<void> _interruptPlayback(Future<void> Function() action) {
    ++_pendingInterrupts;
    final operation = Future<void>.sync(action).whenComplete(() {
      --_pendingInterrupts;
    });
    _pendingTransport = Future.wait([_pendingTransport, operation])
        .then<void>((_) {}, onError: (Object error, StackTrace stackTrace) {});
    return operation;
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
      if (state.playing &&
          state.processingState == ProcessingState.ready &&
          _isForeground &&
          !_isPaused &&
          _activePlaybackRequest == _requestId &&
          _reportedStartRequest != _requestId) {
        _reportedStartRequest = _requestId;
        if (!_isPracticeAudio) _playbackStarts.add(null);
      }
      if (state.playing && _activePlaybackRequest == _requestId) {
        _observedPlayingRequest = _requestId;
      }
      // Ignore late ready=false during startup, but honor a genuine native pause.
      if (_activePlaybackRequest == _requestId &&
          _observedPlayingRequest == _requestId &&
          _isPlaying &&
          !state.playing) {
        unawaited(pause());
      }
      return;
    }
    if (_activePlaybackRequest != _requestId || _isPaused || !_isForeground) {
      return;
    }
    _activePlaybackRequest = null;
    if (_currentMode == PlayMode.fullPage &&
        _currentBubble != null &&
        _currentBubbleIndex + 1 < _pageBubbles.length) {
      _continuePlayback(_playBubble(_currentBubbleIndex + 1));
    } else if (_currentMode == PlayMode.sequential &&
        _currentSentenceId != null &&
        _currentSentenceIndex + 1 < _sequenceSentences.length) {
      _continuePlayback(_playSequentialSentence(_currentSentenceIndex + 1));
    } else if (_currentMode == PlayMode.sequential &&
        _currentSentenceId != null) {
      final sentenceId = _currentSentenceId!;
      String? bubbleId;
      for (final bubble in _pageBubbles) {
        if (bubble.sentenceIds.contains(sentenceId)) {
          bubbleId = bubble.id;
          break;
        }
      }
      final completion = PagePlaybackCompletion(
        _continuationGeneration,
        sentenceId,
        pageIndex: _page?.pageIndex,
        lastBubbleId: bubbleId,
      );
      _clearPlayback();
      unawaited(_finishPage(completion));
    } else {
      _finishNaturalPlayback();
    }
  }

  void _finishNaturalPlayback() {
    ++_requestId;
    ++_transportRequest;
    ++_continuationGeneration;
    _clearPlayback();
    // Clip completion does not end system ducking. A new deliberate clip must
    // stay quiet until focus returns; explicit stop/pause still restore volume.
    unawaited(
      _interruptPlayback(_backend.stop).catchError((Object error) {
        debugPrint('AudioPlayerService: could not finish playback: $error');
      }),
    );
  }

  void _continuePlayback(Future<void> next) {
    unawaited(
      next.then(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('AudioPlayerService: could not continue playback: $error');
        },
      ),
    );
  }

  Future<void> _finishPage(PagePlaybackCompletion completion) async {
    try {
      await _interruptPlayback(_backend.stop);
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
    _isLoading = false;
    _isPaused = false;
    _assetReady = false;
    _page = null;
    _pageBubbles = const [];
    _sequenceSentences = const [];
    _currentBubbleIndex = -1;
    _currentSentenceIndex = -1;
    _isPracticeAudio = false;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_requestId;
    ++_continuationGeneration;
    ++_volumeGeneration;
    _ducked = false;
    _volumeBeforeDuck = null;
    unawaited(_pageCompletions.close());
    unawaited(_playbackStarts.close());
    unawaited(_stateSubscription.cancel());
    unawaited(_interruptionSubscription?.cancel());
    unawaited(_interruptions?.dispose());
    unawaited(_backend.dispose());
    super.dispose();
  }
}
