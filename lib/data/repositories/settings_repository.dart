import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/app_constants.dart';
import '../models/app_settings.dart';

class SettingsRepository {
  SettingsRepository(this._preferences);

  final SharedPreferences _preferences;

  AppSettings loadSettings() {
    final payload = _preferences.getString(AppConstants.settingsStorageKey);
    if (payload == null) return const AppSettings();
    return AppSettings.fromJson(payload);
  }

  Future<void> saveSettings(AppSettings settings) {
    return _preferences.setString(
      AppConstants.settingsStorageKey,
      settings.toJson(),
    );
  }
}
