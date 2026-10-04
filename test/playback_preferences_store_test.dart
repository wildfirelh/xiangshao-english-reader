import 'dart:async';

import 'package:english_point_reading/services/playback_preferences_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Exercise the real plugin's cache against a failing platform implementation.
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _FailingPlatform extends SharedPreferencesStorePlatform {
  _FailingPlatform(Map<String, Object> values)
    : backend = InMemorySharedPreferencesStore.withData(values);

  final InMemorySharedPreferencesStore backend;
  final writes = <String>[];
  bool failNext = false;
  bool throwOnFailure = false;
  bool failRead = false;

  @override
  Future<Map<String, Object>> getAll() async {
    if (failRead) throw StateError('platform preferences unavailable');
    return backend.getAll();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes.add(key);
    if (failNext) {
      failNext = false;
      if (throwOnFailure) throw StateError('platform write failed');
      return false;
    }
    return backend.setValue(valueType, key, value);
  }

  @override
  Future<bool> clear() => backend.clear();

  @override
  Future<bool> remove(String key) => backend.remove(key);
}

class _DelayedPreferences extends Fake implements SharedPreferences {
  final firstWrite = Completer<void>();
  final writes = <double>[];
  double? value;
  bool failNext = false;
  bool failRead = false;

  @override
  Future<void> reload() async {}

  @override
  Object? get(String key) {
    if (failRead) throw StateError('preferences unavailable');
    return value;
  }

  @override
  Future<bool> setDouble(String key, double newValue) async {
    writes.add(newValue);
    if (writes.length == 1) await firstWrite.future;
    if (failNext) {
      failNext = false;
      return false;
    }
    value = newValue;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('missing speed leaves the player free to use its default', () async {
    final store = SharedPreferencesPlaybackPreferencesStore();
    expect(await store.loadSpeed(), isNull);
  });

  test('speed survives reopening a preferences store', () async {
    final store = SharedPreferencesPlaybackPreferencesStore();
    await store.saveSpeed(1.5);

    final reopened = SharedPreferencesPlaybackPreferencesStore();
    expect(await reopened.loadSpeed(), 1.5);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('playback_speed'), 1.5);
  });

  for (final corrupted in <Object>[
    '1.5',
    1,
    true,
    <String>['1.5'],
  ]) {
    test('a stored ${corrupted.runtimeType} is ignored safely', () async {
      SharedPreferences.setMockInitialValues({'playback_speed': corrupted});
      final store = SharedPreferencesPlaybackPreferencesStore();
      expect(await store.loadSpeed(), isNull);
      await store.saveSpeed(0.8);
      expect(await store.loadSpeed(), 0.8);
    });
  }

  test('rapid selections persist the latest speed', () async {
    final store = SharedPreferencesPlaybackPreferencesStore();
    final writes = <Future<void>>[
      store.saveSpeed(0.5),
      store.saveSpeed(0.8),
      store.saveSpeed(1.0),
      store.saveSpeed(1.2),
      store.saveSpeed(1.5),
      store.saveSpeed(2.0),
    ];
    final loaded = store.loadSpeed();
    await Future.wait(writes);
    expect(await loaded, 2.0);
    expect(await SharedPreferencesPlaybackPreferencesStore().loadSpeed(), 2.0);
  });

  test(
    'load waits for slow writes and newer selections stay ordered',
    () async {
      final prefs = _DelayedPreferences();
      final store = SharedPreferencesPlaybackPreferencesStore(
        preferences: prefs,
      );
      final slow = store.saveSpeed(0.5);
      final latest = store.saveSpeed(1.5);
      final loaded = store.loadSpeed();
      await Future<void>.delayed(Duration.zero);
      expect(prefs.writes, [0.5]);

      prefs.firstWrite.complete();
      await Future.wait([slow, latest]);
      expect(await loaded, 1.5);
    },
  );

  test('a rejected write is reported and later saves still work', () async {
    final prefs = _DelayedPreferences()..failNext = true;
    prefs.firstWrite.complete();
    final store = SharedPreferencesPlaybackPreferencesStore(preferences: prefs);
    await expectLater(store.saveSpeed(1.2), throwsStateError);
    await store.saveSpeed(2.0);
    expect(await store.loadSpeed(), 2.0);
  });

  test('storage read errors reach the caller for fallback handling', () async {
    final prefs = _DelayedPreferences()..failRead = true;
    final store = SharedPreferencesPlaybackPreferencesStore(preferences: prefs);
    await expectLater(store.loadSpeed(), throwsStateError);
    prefs.failRead = false;
    expect(await store.loadSpeed(), isNull);
  });

  for (final throws in [false, true]) {
    test(
      'real preferences reload saved speed after ${throws ? 'thrown' : 'rejected'} write',
      () async {
        final platform = _FailingPlatform({
          'flutter.playback_speed': 1.0,
          'flutter.other_preference': 'unchanged',
        })..throwOnFailure = throws;
        SharedPreferencesStorePlatform.instance = platform;
        final prefs = await SharedPreferences.getInstance();
        final store = SharedPreferencesPlaybackPreferencesStore();
        platform.failNext = true;

        await expectLater(store.saveSpeed(0.8), throwsStateError);
        // The actual plugin puts even failed writes in its memory cache.
        expect(prefs.getDouble('playback_speed'), 0.8);
        expect(await store.loadSpeed(), 1.0);
        expect(
          await SharedPreferencesPlaybackPreferencesStore().loadSpeed(),
          1.0,
        );
        expect(prefs.getString('other_preference'), 'unchanged');
        expect(platform.writes, ['flutter.playback_speed']);

        await store.saveSpeed(1.5);
        expect(await store.loadSpeed(), 1.5);
        expect(
          await SharedPreferencesPlaybackPreferencesStore().loadSpeed(),
          1.5,
        );
      },
    );
  }

  test(
    'failed first save does not manufacture a persisted preference',
    () async {
      final platform = _FailingPlatform({});
      SharedPreferencesStorePlatform.instance = platform;
      final store = SharedPreferencesPlaybackPreferencesStore();
      final prefs = await SharedPreferences.getInstance();
      platform.failNext = true;
      await expectLater(store.saveSpeed(2.0), throwsStateError);
      expect(prefs.getDouble('playback_speed'), 2.0);
      expect(await store.loadSpeed(), isNull);
      expect(
        await SharedPreferencesPlaybackPreferencesStore().loadSpeed(),
        isNull,
      );
    },
  );

  test('a failed reload never returns a rejected speed from memory', () async {
    final platform = _FailingPlatform({'flutter.playback_speed': 0.8});
    SharedPreferencesStorePlatform.instance = platform;
    final store = SharedPreferencesPlaybackPreferencesStore();
    await SharedPreferences.getInstance();
    platform.failNext = true;
    await expectLater(store.saveSpeed(2.0), throwsStateError);
    platform.failRead = true;
    await expectLater(store.loadSpeed(), throwsStateError);
    platform.failRead = false;
    expect(await store.loadSpeed(), 0.8);
  });

  test(
    'memory stores retain their own values without platform plugins',
    () async {
      final first = InMemoryPlaybackPreferencesStore(initialSpeed: 0.8);
      final second = InMemoryPlaybackPreferencesStore();
      expect(await first.loadSpeed(), 0.8);
      expect(await second.loadSpeed(), isNull);
      await first.saveSpeed(1.2);
      expect(await first.loadSpeed(), 1.2);
      expect(await second.loadSpeed(), isNull);
    },
  );
}
