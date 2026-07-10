import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/app_constants.dart';
import '../models/recent_file.dart';

class RecentFilesRepository {
  RecentFilesRepository(this._preferences);

  final SharedPreferences _preferences;

  List<RecentFile> loadRecentFiles() {
    final items =
        _preferences.getStringList(AppConstants.recentFilesStorageKey) ?? [];
    return items
        .map(RecentFile.fromJson)
        .where((file) => !_isExpiredProviderUri(file.uri))
        .toList()
      ..sort((a, b) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
        return b.lastOpenedAt.compareTo(a.lastOpenedAt);
      });
  }

  bool _isExpiredProviderUri(String uri) {
    return uri.startsWith('content://com.whatsapp.provider.media/');
  }

  Future<void> saveRecentFiles(List<RecentFile> files) {
    final payload = files.take(AppConstants.maxRecentFiles).map((file) {
      return file.toJson();
    }).toList();
    return _preferences.setStringList(
      AppConstants.recentFilesStorageKey,
      payload,
    );
  }
}
