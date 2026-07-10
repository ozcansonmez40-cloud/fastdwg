import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../data/models/dwg_scene.dart';
import '../shared/widgets/dwg_viewport.dart';

/// Generates and stores per-file preview thumbnails for the recent-files list.
/// PNGs live under the app documents dir in `thumbs/<fileId>.png`, so they
/// survive across sessions and are cheap to drop in [clearAll].
class ThumbnailService {
  static const String _dirName = 'thumbs';

  // File ids are often a full path or a `content://` URI — both contain `/`
  // and `:`, which are illegal in a filename and made the PNG write fail
  // silently. Base64url is filesystem-safe (no `/`) and stable per id.
  String _safeName(String fileId) =>
      base64Url.encode(utf8.encode(fileId)).replaceAll('=', '');

  Future<Directory> _thumbsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_dirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Renders [scene] to a PNG and writes it for [fileId]. Returns the saved
  /// file path, or null if rendering/writing failed.
  Future<String?> generate(
    String fileId,
    DwgScene scene, {
    Set<int> hiddenLayers = const {},
  }) async {
    try {
      final Uint8List? png =
          await renderSceneThumbnail(scene, hiddenLayers: hiddenLayers);
      if (png == null) return null;
      final dir = await _thumbsDir();
      final file = File('${dir.path}/${_safeName(fileId)}.png');
      await file.writeAsBytes(png, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(String fileId) async {
    try {
      final dir = await _thumbsDir();
      final file = File('${dir.path}/${_safeName(fileId)}.png');
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort cleanup.
    }
  }

  Future<void> clearAll() async {
    try {
      final dir = await _thumbsDir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Best-effort cleanup.
    }
  }
}
