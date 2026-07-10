import 'package:shared_preferences/shared_preferences.dart';

/// Per-file persistence for the viewer's measure/draw annotations. Stored as a
/// JSON string keyed by the file id, so reopening a drawing restores its shapes.
class AnnotationsRepository {
  static const String _prefix = 'annotations_';

  Future<String?> load(String fileId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_prefix$fileId');
  }

  Future<void> save(String fileId, String json) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_prefix$fileId';
    // Empty / "[]" means no shapes — drop the key so we don't accumulate junk.
    if (json.isEmpty || json == '[]') {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, json);
    }
  }
}
