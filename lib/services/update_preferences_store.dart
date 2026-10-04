import 'package:shared_preferences/shared_preferences.dart';

abstract interface class UpdatePreferencesStore {
  Future<DateTime?> loadLastCheck();
  Future<void> saveLastCheck(DateTime value);
}

class SharedPreferencesUpdateStore implements UpdatePreferencesStore {
  static const lastCheckKey = 'last_app_update_check';

  @override
  Future<DateTime?> loadLastCheck() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.get(lastCheckKey);
    return value is int
        ? DateTime.fromMillisecondsSinceEpoch(value, isUtc: true)
        : null;
  }

  @override
  Future<void> saveLastCheck(DateTime value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(lastCheckKey, value.millisecondsSinceEpoch);
  }
}
