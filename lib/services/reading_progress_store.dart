import 'package:shared_preferences/shared_preferences.dart';

abstract interface class ReadingProgressStore {
  Future<int?> load(String bookId);
  Future<void> save(String bookId, int pageIndex);
}

class SharedPreferencesReadingProgressStore implements ReadingProgressStore {
  SharedPreferencesReadingProgressStore({this.preferences});

  static final instance = SharedPreferencesReadingProgressStore();
  final SharedPreferencesAsync? preferences;
  SharedPreferencesAsync? _platformPreferences;
  Future<void> _pending = Future<void>.value();

  SharedPreferencesAsync get _prefs =>
      preferences ?? (_platformPreferences ??= SharedPreferencesAsync());

  static String keyFor(String bookId) => 'last_read_page_index.$bookId';

  @override
  Future<int?> load(String bookId) async {
    await _pending;
    return _prefs.getInt(keyFor(bookId));
  }

  @override
  Future<void> save(String bookId, int pageIndex) {
    // Serialize rapid turns so a slow older write cannot overwrite a new page.
    final write = _pending.then(
      (_) => _prefs.setInt(keyFor(bookId), pageIndex),
    );
    // Report this failure to the caller, but keep the queue usable afterwards.
    _pending = write.catchError((Object _) {});
    return write;
  }
}
