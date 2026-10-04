import 'package:shared_preferences/shared_preferences.dart';

abstract interface class PlaybackPreferencesStore {
  Future<double?> loadSpeed();
  Future<void> saveSpeed(double speed);
}

class SharedPreferencesPlaybackPreferencesStore
    implements PlaybackPreferencesStore {
  SharedPreferencesPlaybackPreferencesStore({this.preferences});

  static final instance = SharedPreferencesPlaybackPreferencesStore();
  static const speedKey = 'playback_speed';

  final SharedPreferences? preferences;
  Future<void> _pending = Future<void>.value();

  Future<SharedPreferences> get _prefs async =>
      preferences ?? await SharedPreferences.getInstance();

  @override
  Future<double?> loadSpeed() async {
    await _pending;
    final prefs = await _prefs;
    // Legacy setDouble updates its cache even if the platform write fails.
    // Read confirmed platform values so failed selections cannot survive a
    // reader reopening. A reload failure propagates instead of using stale data.
    await prefs.reload();
    final value = prefs.get(speedKey);
    // Older or externally modified preferences may use a different value type.
    // The player validates whether a numeric value is a supported speed.
    return value is double ? value : null;
  }

  @override
  Future<void> saveSpeed(double speed) {
    // An older slow write must not replace a user's more recent selection.
    final write = _pending.then((_) async {
      if (!await (await _prefs).setDouble(speedKey, speed)) {
        throw StateError('Unable to save playback speed.');
      }
    });
    // Surface errors to this caller while keeping later writes usable.
    _pending = write.catchError((Object _) {});
    return write;
  }
}

class InMemoryPlaybackPreferencesStore implements PlaybackPreferencesStore {
  InMemoryPlaybackPreferencesStore({double? initialSpeed})
    : _speed = initialSpeed;

  double? _speed;

  @override
  Future<double?> loadSpeed() async => _speed;

  @override
  Future<void> saveSpeed(double speed) async {
    _speed = speed;
  }
}
