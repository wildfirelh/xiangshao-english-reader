import 'package:flutter/foundation.dart';

import 'audio_player_service.dart';
import 'learning_preferences_store.dart';
import 'playback_preferences_store.dart';

/// Local settings and statistics shared by every textbook reader.
class LearningController extends ChangeNotifier {
  LearningController({
    LearningPreferencesStore? preferencesStore,
    PlaybackPreferencesStore? playbackPreferencesStore,
    DateTime Function()? now,
  }) : _preferences =
           preferencesStore ??
           SharedPreferencesLearningPreferencesStore.instance,
       _playbackPreferences =
           playbackPreferencesStore ??
           SharedPreferencesPlaybackPreferencesStore.instance,
       _now = now ?? DateTime.now;

  final LearningPreferencesStore _preferences;
  final PlaybackPreferencesStore _playbackPreferences;
  final DateTime Function() _now;
  LearningPreferences _value = LearningPreferences();
  double _currentSpeed = 1.0;
  bool _initialized = false;
  bool _preferencesLoaded = false;
  bool _speedLoaded = false;
  bool _disposed = false;
  String? _errorMessage;
  Future<void>? _initialization;
  Future<void> _pending = Future<void>.value();

  bool get initialized => _initialized;
  bool get statisticsAvailable => _preferencesLoaded;
  bool get eyeReminderEnabled => _value.eyeReminderEnabled;
  double get currentSpeed => _currentSpeed;
  int get readingDays => _value.readingDates.length;
  int get readingBooks => _value.bookIds.length;
  String? get errorMessage => _errorMessage;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _loadPreferences() async {
    _value = await _preferences.load() ?? LearningPreferences();
    _preferencesLoaded = true;
  }

  Future<void> _loadSpeed() async {
    final speed = await _playbackPreferences.loadSpeed();
    _currentSpeed = AudioPlayerService.supportedSpeeds.contains(speed)
        ? speed!
        : 1.0;
    _speedLoaded = true;
  }

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      await _loadPreferences();
    } catch (_) {
      _errorMessage = '学习记录暂时无法读取，请稍后再试';
    }
    try {
      await _loadSpeed();
    } catch (_) {
      _errorMessage ??= '语速偏好暂时无法读取，请稍后再试';
    }
    _initialized = true;
    _notify();
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final write = _pending.then((_) async {
      await initialize();
      if (_disposed) return;
      try {
        await operation();
        _errorMessage = null;
        _notify();
      } catch (_) {
        _errorMessage = '设置或学习记录未保存，请重试';
        _notify();
        rethrow;
      }
    });
    _pending = write.catchError((Object _) {});
    return write;
  }

  Future<void> setEyeReminderEnabled(bool enabled) => _serialize(() async {
    // An unread snapshot must never be overwritten with default statistics.
    if (!_preferencesLoaded) await _loadPreferences();
    if (enabled == _value.eyeReminderEnabled) return;
    final next = _value.copyWith(eyeReminderEnabled: enabled);
    await _preferences.save(next);
    _value = next;
  });

  Future<void> setSpeed(double speed) {
    if (!AudioPlayerService.supportedSpeeds.contains(speed)) {
      return Future<void>.error(ArgumentError.value(speed, 'speed'));
    }
    return _serialize(() async {
      if (!_speedLoaded) await _loadSpeed();
      if (speed == _currentSpeed) return;
      await _playbackPreferences.saveSpeed(speed);
      _currentSpeed = speed;
    });
  }

  /// Call after real audio starts, never from book navigation or page views.
  Future<void> recordPointRead(String bookId) {
    final normalizedId = bookId.trim();
    if (normalizedId.isEmpty) {
      return Future<void>.error(ArgumentError.value(bookId, 'bookId'));
    }
    final now = _now().toLocal();
    final date =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    return _serialize(() async {
      if (!_preferencesLoaded) await _loadPreferences();
      if (_value.readingDates.contains(date) &&
          _value.bookIds.contains(normalizedId)) {
        return;
      }
      final next = _value.copyWith(
        readingDates: {..._value.readingDates, date},
        bookIds: {..._value.bookIds, normalizedId},
      );
      await _preferences.save(next);
      _value = next;
    });
  }

  /// Synchronize changes made by a reader before showing the profile again.
  Future<void> refreshSpeed() => _serialize(_loadSpeed);

  Future<void> refresh() => _serialize(() async {
    await _loadPreferences();
    await _loadSpeed();
  });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
