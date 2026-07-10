import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../data/models/recent_file.dart';

class FilePickerService {
  Future<RecentFile?> pickDwgFile() async {
    // FileType.any — Android does not have a registered MIME type for .dwg,
    // so FileType.custom filters out all files on API 33+. Show all files
    // and validate the extension ourselves.
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
      allowMultiple: false,
    );

    final file = result?.files.single;
    if (file == null) return null;

    final ext = file.name.split('.').last.toLowerCase();
    if (ext != 'dwg') return null;

    if (file.bytes != null && file.bytes!.isNotEmpty) {
      final savedPath = await _saveBytesToAppDir(file.name, file.bytes!);
      return RecentFile(
        id: savedPath,
        name: file.name,
        uri: savedPath,
        fileExtension: 'dwg',
        lastOpenedAt: DateTime.now(),
        fileSizeBytes: file.bytes!.length,
      );
    }

    // Prefer content URI (identifier): Kotlin's contentResolver can open it.
    final uri = file.identifier ?? file.path;
    if (uri == null) return null;

    // If it's already an accessible local path, use it directly.
    if (!uri.startsWith('content://') && !uri.startsWith('file://')) {
      if (File(uri).existsSync()) {
        return RecentFile(
          id: uri,
          name: file.name,
          uri: uri,
          fileExtension: 'dwg',
          lastOpenedAt: DateTime.now(),
          fileSizeBytes: file.size,
        );
      }
    }

    // Save a permanent copy via bytes for persistent access across sessions.
    // Read bytes here while the SAF URI permission is active.
    try {
      final bytes = await _readUri(uri);
      if (bytes != null && bytes.isNotEmpty) {
        final savedPath = await _saveBytesToAppDir(file.name, bytes);
        return RecentFile(
          id: savedPath,
          name: file.name,
          uri: savedPath,
          fileExtension: 'dwg',
          lastOpenedAt: DateTime.now(),
          fileSizeBytes: bytes.length,
        );
      }
    } catch (_) {}

    // Final fallback: pass the raw URI and let Kotlin handle it.
    return RecentFile(
      id: uri,
      name: file.name,
      uri: uri,
      fileExtension: 'dwg',
      lastOpenedAt: DateTime.now(),
      fileSizeBytes: file.size,
    );
  }

  Future<List<int>?> _readUri(String uri) async {
    if (uri.startsWith('content://') || uri.startsWith('file://')) {
      // For content URIs, use FilePicker to read bytes via a second call.
      // We can't use dart:io File for content:// URIs.
      return null; // Let Kotlin handle content:// URIs
    }
    final f = File(uri);
    if (await f.exists()) return f.readAsBytes();
    return null;
  }

  Future<String> _saveBytesToAppDir(String name, List<int> bytes) async {
    final dir = await getTemporaryDirectory();
    final cacheDir = Directory('${dir.path}/dwg_cache');
    if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);

    final safeName = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final dest = File('${cacheDir.path}/$safeName');
    await dest.writeAsBytes(bytes, flush: true);
    return dest.path;
  }
}
