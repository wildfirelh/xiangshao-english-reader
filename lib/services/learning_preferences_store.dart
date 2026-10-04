import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A single snapshot keeps each successful point read's date and book together.
class LearningPreferences {
  LearningPreferences({
    this.eyeReminderEnabled = true,
    Iterable<String> readingDates = const [],
    Iterable<String> bookIds = const [],
  }) : readingDates = Set<String>.unmodifiable(readingDates),
       bookIds = Set<String>.unmodifiable(bookIds);

  final bool eyeReminderEnabled;
  final Set<String> readingDates;
  final Set<String> bookIds;

  factory LearningPreferences.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1 || json['eyeReminderEnabled'] is! bool) {
      throw const FormatException('Invalid learning preferences');
    }
    final dates = json['readingDates'];
    final books = json['bookIds'];
    if (dates is! List ||
        books is! List ||
        dates.any((date) => date is! String || !_validDate(date)) ||
        books.any((book) => book is! String || book.trim().isEmpty)) {
      throw const FormatException('Invalid learning statistics');
    }
    return LearningPreferences(
      eyeReminderEnabled: json['eyeReminderEnabled'] as bool,
      readingDates: dates.cast<String>(),
      bookIds: books.cast<String>(),
    );
  }

  static bool _validDate(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
    final date = DateTime.tryParse(value);
    return date != null &&
        date.year.toString().padLeft(4, '0') == value.substring(0, 4) &&
        date.month.toString().padLeft(2, '0') == value.substring(5, 7) &&
        date.day.toString().padLeft(2, '0') == value.substring(8, 10);
  }

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'eyeReminderEnabled': eyeReminderEnabled,
    'readingDates': readingDates.toList()..sort(),
    'bookIds': bookIds.toList()..sort(),
  };

  LearningPreferences copyWith({
    bool? eyeReminderEnabled,
    Iterable<String>? readingDates,
    Iterable<String>? bookIds,
  }) => LearningPreferences(
    eyeReminderEnabled: eyeReminderEnabled ?? this.eyeReminderEnabled,
    readingDates: readingDates ?? this.readingDates,
    bookIds: bookIds ?? this.bookIds,
  );
}

abstract interface class LearningPreferencesStore {
  Future<LearningPreferences?> load();
  Future<void> save(LearningPreferences value);
}

class SharedPreferencesLearningPreferencesStore
    implements LearningPreferencesStore {
  SharedPreferencesLearningPreferencesStore({this.preferences});

  static final instance = SharedPreferencesLearningPreferencesStore();
  static const preferencesKey = 'learning_preferences_v1';
  final SharedPreferences? preferences;
  Future<void> _pending = Future<void>.value();

  Future<SharedPreferences> get _prefs async =>
      preferences ?? await SharedPreferences.getInstance();

  @override
  Future<LearningPreferences?> load() async {
    await _pending;
    final prefs = await _prefs;
    // Confirm the native value after failed writes; the legacy plugin updates
    // its memory cache even when the platform rejects a save.
    await prefs.reload();
    final raw = prefs.get(preferencesKey);
    if (raw == null) return null;
    if (raw is! String) {
      throw const FormatException('Invalid stored learning preferences');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid stored learning preferences');
    }
    return LearningPreferences.fromJson(decoded);
  }

  @override
  Future<void> save(LearningPreferences value) {
    final encoded = jsonEncode(value.toJson());
    final write = _pending.then((_) async {
      if (!await (await _prefs).setString(preferencesKey, encoded)) {
        throw StateError('Unable to save learning preferences.');
      }
    });
    _pending = write.catchError((Object _) {});
    return write;
  }
}

class InMemoryLearningPreferencesStore implements LearningPreferencesStore {
  InMemoryLearningPreferencesStore({LearningPreferences? initialValue})
    : _value = initialValue;

  LearningPreferences? _value;

  @override
  Future<LearningPreferences?> load() async => _value;

  @override
  Future<void> save(LearningPreferences value) async => _value = value;
}
