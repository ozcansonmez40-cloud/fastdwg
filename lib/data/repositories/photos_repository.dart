import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/photo_note.dart';

/// Per-file persistence for photos pinned to a drawing. The note list (model
/// coords + image path) is a JSON string in SharedPreferences keyed by file id;
/// the image bytes are copied into the app documents dir so they survive even
/// if the source (gallery/camera temp) is cleared.
class PhotosRepository {
  static const String _prefix = 'photos_';
  static const String _dirName = 'photos';

  String _safe(String fileId) =>
      base64Url.encode(utf8.encode(fileId)).replaceAll('=', '');

  Future<List<PhotoNote>> load(String fileId) async {
    final prefs = await SharedPreferences.getInstance();
    return PhotoNote.decodeList(prefs.getString('$_prefix$fileId'));
  }

  Future<void> save(String fileId, List<PhotoNote> notes) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_prefix$fileId';
    if (notes.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, PhotoNote.encodeList(notes));
    }
  }

  Future<Directory> _dir(String fileId) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_dirName/${_safe(fileId)}');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Copies a picked image (at [sourcePath]) into permanent app storage for
  /// [fileId] and returns the stored absolute path (or null on failure).
  Future<String?> importImage(String fileId, String sourcePath) async {
    try {
      final dir = await _dir(fileId);
      final ext = sourcePath.contains('.')
          ? sourcePath.substring(sourcePath.lastIndexOf('.') + 1).toLowerCase()
          : 'jpg';
      final safeExt = ext.length <= 4 ? ext : 'jpg';
      final id = DateTime.now().microsecondsSinceEpoch.toString();
      final dest = File('${dir.path}/$id.$safeExt');
      await File(sourcePath).copy(dest.path);
      return dest.path;
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteImageFile(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // Best-effort.
    }
  }

  /// Removes all photos (notes + image files) for a file.
  Future<void> clearForFile(String fileId) async {
    try {
      final dir = await _dir(fileId);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Best-effort.
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$fileId');
  }
}
