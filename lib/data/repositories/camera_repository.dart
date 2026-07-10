import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the last viewed region per drawing (as "minX,minY,maxX,maxY")
/// so reopening a file resumes where the user left off instead of zoom-extents.
class CameraRepository {
  static const String _prefix = 'camera_';

  /// Returns [minX, minY, maxX, maxY] or null when nothing (valid) is stored.
  Future<List<double>?> load(String fileId) async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString('$_prefix$fileId');
    if (s == null) return null;
    final parts = s.split(',');
    if (parts.length != 4) return null;
    final v = parts.map(double.tryParse).toList();
    if (v.any((e) => e == null || !e.isFinite)) return null;
    final b = v.cast<double>();
    if (b[2] <= b[0] || b[3] <= b[1]) return null;
    return b;
  }

  Future<void> save(
      String fileId, double minX, double minY, double maxX, double maxY) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefix$fileId', '$minX,$minY,$maxX,$maxY');
  }
}
