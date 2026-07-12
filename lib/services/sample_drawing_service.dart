import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models/recent_file.dart';

/// Ships a built-in demo drawing so a freshly-installed app is not empty and the
/// user can open the viewer immediately, before picking a file of their own.
///
/// The DWG is bundled as an asset (inside the APK) and copied into the app's
/// documents dir on first launch, then handed back as a pinned [RecentFile].
/// The native parser reads from a real file path, not the asset bundle, which
/// is why the copy step exists — it is invisible to the user and never touches
/// the network. Seeding runs once, guarded by a SharedPreferences flag, so a
/// user who deletes the sample is not nagged with it again.
class SampleDrawingService {
  SampleDrawingService(this._preferences);

  final SharedPreferences _preferences;

  static const String _assetPath = 'assets/samples/demo.dwg';
  // Bump the suffix if the bundled drawing is ever replaced, so existing
  // installs re-seed the new file instead of keeping the old copy.
  static const String _seededKey = 'sample_seeded_v5';
  static const String _sampleId = 'builtin_sample_v1';
  static const String _sampleName = 'Sample Project.dwg';

  /// On first launch, writes the bundled drawing into app storage and returns a
  /// pinned [RecentFile] for it. Returns null if already seeded or if the copy
  /// failed — either way the caller simply shows the normal (empty) list.
  Future<RecentFile?> ensureSeeded() async {
    if (_preferences.getBool(_seededKey) ?? false) return null;

    try {
      final data = await rootBundle.load(_assetPath);
      final documentsDir = await getApplicationDocumentsDirectory();
      final samplesDir = Directory('${documentsDir.path}/samples');
      if (!samplesDir.existsSync()) {
        samplesDir.createSync(recursive: true);
      }
      final file = File('${samplesDir.path}/demo.dwg');
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );

      // Mark seeded only after the file is safely on disk, so a failure mid-way
      // is retried on the next launch rather than silently skipped forever.
      await _preferences.setBool(_seededKey, true);

      return RecentFile(
        id: _sampleId,
        name: _sampleName,
        uri: file.path,
        fileExtension: 'dwg',
        lastOpenedAt: DateTime.now(),
        fileSizeBytes: data.lengthInBytes,
        // Not pinned: a pinned demo would sit above every drawing the user
        // opens, so their most-recent file could never reach the top. As a
        // plain recent entry it drifts down naturally as real files are opened.
        isPinned: false,
      );
    } catch (_) {
      return null;
    }
  }
}
