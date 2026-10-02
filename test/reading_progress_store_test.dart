import 'dart:async';

import 'package:english_point_reading/services/reading_progress_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _WriteState {
  Completer<void>? gate;
  bool failNext = false;
}

class _Preferences extends Fake implements SharedPreferencesAsync {
  final values = <String, int>{};
  final writes = <int>[];
  final state = _WriteState();

  @override
  Future<int?> getInt(String key) async => values[key];

  @override
  Future<void> setInt(String key, int value) async {
    writes.add(value);
    await state.gate?.future;
    if (state.failNext) {
      state.failNext = false;
      throw StateError('disk error');
    }
    values[key] = value;
  }
}

void main() {
  test(
    'stores physical page separately for each book across store instances',
    () async {
      final prefs = _Preferences();
      final store = SharedPreferencesReadingProgressStore(preferences: prefs);
      expect(await store.load('a'), isNull);
      await store.save('a', 28);
      await store.save('b', 63);
      final reopened = SharedPreferencesReadingProgressStore(
        preferences: prefs,
      );
      expect(await reopened.load('a'), 28);
      expect(await reopened.load('b'), 63);
      expect(prefs.values['last_read_page_index.a'], 28);
    },
  );

  test(
    'serializes writes and load waits for the latest pending page',
    () async {
      final prefs = _Preferences();
      prefs.state.gate = Completer<void>();
      final store = SharedPreferencesReadingProgressStore(preferences: prefs);
      final first = store.save('a', 8);
      final second = store.save('a', 13);
      final loaded = store.load('a');
      await Future<void>.delayed(Duration.zero);
      expect(prefs.writes, [8]);
      prefs.state.gate!.complete();
      await Future.wait([first, second]);
      expect(await loaded, 13);
      expect(prefs.writes, [8, 13]);
    },
  );

  test('a failed write does not prevent the next save', () async {
    final prefs = _Preferences();
    prefs.state.failNext = true;
    final store = SharedPreferencesReadingProgressStore(preferences: prefs);
    await expectLater(store.save('a', 8), throwsStateError);
    await store.save('a', 9);
    expect(await store.load('a'), 9);
  });
}
