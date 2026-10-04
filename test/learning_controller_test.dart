import 'dart:async';
import 'dart:convert';

import 'package:english_point_reading/services/learning_controller.dart';
import 'package:english_point_reading/services/learning_preferences_store.dart';
import 'package:english_point_reading/services/playback_preferences_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _Store implements LearningPreferencesStore {
  LearningPreferences? value;
  bool failLoad = false;
  bool failSave = false;
  int saveCount = 0;
  Completer<void>? firstWrite;

  @override
  Future<LearningPreferences?> load() async {
    if (failLoad) throw StateError('storage unavailable');
    return value;
  }

  @override
  Future<void> save(LearningPreferences next) async {
    saveCount++;
    if (saveCount == 1) await firstWrite?.future;
    if (failSave) throw StateError('write rejected');
    value = next;
  }
}

class _SpeedStore extends InMemoryPlaybackPreferencesStore {
  _SpeedStore({super.initialSpeed});
  bool failSave = false;

  @override
  Future<void> saveSpeed(double speed) async {
    if (failSave) throw StateError('write rejected');
    await super.saveSpeed(speed);
  }
}

class _FailingPlatform extends SharedPreferencesStorePlatform {
  _FailingPlatform(Map<String, Object> values)
    : backend = InMemorySharedPreferencesStore.withData(values);

  final InMemorySharedPreferencesStore backend;
  bool failSave = false;

  @override
  Future<Map<String, Object>> getAll() => backend.getAll();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      failSave ? false : backend.setValue(valueType, key, value);

  @override
  Future<bool> clear() => backend.clear();

  @override
  Future<bool> remove(String key) => backend.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  LearningController controller({
    LearningPreferencesStore? store,
    PlaybackPreferencesStore? speeds,
    DateTime Function()? now,
  }) => LearningController(
    preferencesStore: store ?? InMemoryLearningPreferencesStore(),
    playbackPreferencesStore: speeds ?? InMemoryPlaybackPreferencesStore(),
    now: now,
  );

  test('a new install has zero real activity and default settings', () async {
    final value = controller();
    addTearDown(value.dispose);
    await value.initialize();
    expect(value.initialized, isTrue);
    expect(value.readingDays, 0);
    expect(value.readingBooks, 0);
    expect(value.eyeReminderEnabled, isTrue);
    expect(value.currentSpeed, 1.0);
  });

  test('same local date and book are counted once', () async {
    final store = _Store();
    final value = controller(
      store: store,
      now: () => DateTime(2026, 10, 4, 13),
    );
    addTearDown(value.dispose);
    await Future.wait([
      value.recordPointRead('xiangshao_3_1'),
      value.recordPointRead('xiangshao_3_1'),
      value.recordPointRead('xiangshao_3_1'),
    ]);
    expect(value.readingDays, 1);
    expect(value.readingBooks, 1);
    expect(store.saveCount, 1);
    expect(store.value!.readingDates, {'2026-10-04'});
  });

  test('another book adds a book but another day adds a day', () async {
    var now = DateTime(2026, 10, 4);
    final value = controller(now: () => now);
    addTearDown(value.dispose);
    await value.recordPointRead('first');
    await value.recordPointRead('second');
    expect(value.readingDays, 1);
    expect(value.readingBooks, 2);
    now = DateTime(2026, 10, 5);
    await value.recordPointRead('first');
    expect(value.readingDays, 2);
    expect(value.readingBooks, 2);
  });

  test(
    'point-read date is captured before a slow save crosses midnight',
    () async {
      var now = DateTime(2026, 10, 4, 23, 59);
      final store = _Store()..firstWrite = Completer<void>();
      final value = controller(store: store, now: () => now);
      addTearDown(value.dispose);
      final beforeMidnight = value.recordPointRead('first');
      now = DateTime(2026, 10, 5);
      final afterMidnight = value.recordPointRead('first');
      await Future<void>.delayed(Duration.zero);
      store.firstWrite!.complete();
      await Future.wait([beforeMidnight, afterMidnight]);
      expect(store.value!.readingDates, {'2026-10-04', '2026-10-05'});
    },
  );

  test('settings and genuine activity survive a reopened store', () async {
    final first = LearningController(now: () => DateTime(2026, 10, 4));
    addTearDown(first.dispose);
    await first.setEyeReminderEnabled(false);
    await first.setSpeed(1.5);
    await first.recordPointRead('xiangshao_3_1');
    final reopened = LearningController();
    addTearDown(reopened.dispose);
    await reopened.initialize();
    expect(reopened.eyeReminderEnabled, isFalse);
    expect(reopened.currentSpeed, 1.5);
    expect(reopened.readingDays, 1);
    expect(reopened.readingBooks, 1);
    final prefs = await SharedPreferences.getInstance();
    final snapshot = jsonDecode(
      prefs.getString(
        SharedPreferencesLearningPreferencesStore.preferencesKey,
      )!,
    ) as Map<String, dynamic>;
    expect(snapshot['readingDates'], ['2026-10-04']);
    expect(snapshot['bookIds'], ['xiangshao_3_1']);
    expect(prefs.getDouble('playback_speed'), 1.5);
  });

  test('concurrent settings and activity keep the complete snapshot', () async {
    final store = _Store()..firstWrite = Completer<void>();
    final value = controller(store: store);
    addTearDown(value.dispose);
    final operations = [
      value.recordPointRead('first'),
      value.setEyeReminderEnabled(false),
      value.recordPointRead('second'),
      value.setEyeReminderEnabled(true),
    ];
    await Future<void>.delayed(Duration.zero);
    store.firstWrite!.complete();
    await Future.wait(operations);
    expect(value.readingBooks, 2);
    expect(store.value!.bookIds, {'first', 'second'});
    expect(store.value!.eyeReminderEnabled, isTrue);
  });

  test(
    'failed activity save cannot invent statistics and later saves work',
    () async {
      final store = _Store()..failSave = true;
      final value = controller(store: store);
      addTearDown(value.dispose);
      await expectLater(value.recordPointRead('first'), throwsStateError);
      expect(value.readingDays, 0);
      expect(value.readingBooks, 0);
      expect(value.errorMessage, isNotNull);
      store.failSave = false;
      await value.recordPointRead('first');
      expect(value.readingDays, 1);
      expect(value.readingBooks, 1);
      expect(value.errorMessage, isNull);
    },
  );

  test('failed eye preference keeps the confirmed switch state', () async {
    final store = _Store()..failSave = true;
    final value = controller(store: store);
    addTearDown(value.dispose);
    await expectLater(value.setEyeReminderEnabled(false), throwsStateError);
    expect(value.eyeReminderEnabled, isTrue);
  });

  test('a failed initial read never overwrites existing activity', () async {
    final store = _Store()
      ..value = LearningPreferences(
        readingDates: ['2026-10-03'],
        bookIds: ['existing'],
      )
      ..failLoad = true;
    final value = controller(store: store);
    addTearDown(value.dispose);
    await value.initialize();
    expect(value.errorMessage, isNotNull);
    await expectLater(value.recordPointRead('new'), throwsStateError);
    expect(store.saveCount, 0);
    store.failLoad = false;
    await value.recordPointRead('new');
    expect(value.readingBooks, 2);
    expect(store.value!.bookIds, {'existing', 'new'});
  });

  test('all six speeds share the established reader preference', () async {
    final store = _SpeedStore();
    final value = controller(speeds: store);
    addTearDown(value.dispose);
    for (final speed in [0.5, 0.8, 1.0, 1.2, 1.5, 2.0]) {
      await value.setSpeed(speed);
      expect(value.currentSpeed, speed);
      expect(await store.loadSpeed(), speed);
    }
    await expectLater(value.setSpeed(3), throwsArgumentError);
    expect(value.currentSpeed, 2.0);
  });

  test('failed speed save retains the confirmed preference', () async {
    final store = _SpeedStore(initialSpeed: 0.8)..failSave = true;
    final value = controller(speeds: store);
    addTearDown(value.dispose);
    await value.initialize();
    await expectLater(value.setSpeed(2.0), throwsStateError);
    expect(value.currentSpeed, 0.8);
    expect(await store.loadSpeed(), 0.8);
  });

  test('profile refresh picks up a reader speed change', () async {
    final store = InMemoryPlaybackPreferencesStore(initialSpeed: 1.0);
    final value = controller(speeds: store);
    addTearDown(value.dispose);
    await value.initialize();
    await store.saveSpeed(0.5);
    await value.refreshSpeed();
    expect(value.currentSpeed, 0.5);
  });

  test('native rejected writes do not pollute a reopened snapshot', () async {
    final previous = SharedPreferencesStorePlatform.instance;
    final existing = LearningPreferences(
      readingDates: ['2026-10-03'],
      bookIds: ['first'],
    );
    final platform = _FailingPlatform({
      'flutter.${SharedPreferencesLearningPreferencesStore.preferencesKey}':
          jsonEncode(existing.toJson()),
    });
    SharedPreferencesStorePlatform.instance = platform;
    addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
    final prefs = await SharedPreferences.getInstance();
    final store = SharedPreferencesLearningPreferencesStore(preferences: prefs);
    expect((await store.load())!.bookIds, {'first'});
    platform.failSave = true;
    await expectLater(
      store.save(existing.copyWith(bookIds: ['first', 'failed'])),
      throwsStateError,
    );
    final reopened = SharedPreferencesLearningPreferencesStore(
      preferences: prefs,
    );
    expect((await reopened.load())!.bookIds, {'first'});
  });

  test('invalid dates and invented non-string records are rejected', () {
    final valid = LearningPreferences().toJson();
    for (final date in ['2026-02-30', '2026-2-01', 'not-a-date', 15]) {
      expect(
        () => LearningPreferences.fromJson({
          ...valid,
          'readingDates': [date],
        }),
        throwsFormatException,
      );
    }
    for (final book in ['', ' ', 7]) {
      expect(
        () => LearningPreferences.fromJson({
          ...valid,
          'bookIds': [book],
        }),
        throwsFormatException,
      );
    }
  });

  test('snapshot input collections cannot change recorded counts', () {
    final books = ['first'];
    final snapshot = LearningPreferences(bookIds: books);
    books.add('second');
    expect(snapshot.bookIds, {'first'});
    expect(() => snapshot.bookIds.add('third'), throwsUnsupportedError);
  });
}
