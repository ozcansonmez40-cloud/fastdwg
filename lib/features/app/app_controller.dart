import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/l10n/l10n.dart';

import '../../data/models/app_settings.dart';
import '../../data/models/recent_file.dart';
import '../../data/repositories/photos_repository.dart';
import '../../data/repositories/recent_files_repository.dart';
import '../../data/models/dwg_scene.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/dwg_renderer_service.dart';
import '../../services/file_picker_service.dart';
import '../../services/incoming_drawing_service.dart';
import '../../services/sample_drawing_service.dart';
import '../../services/thumbnail_service.dart';

class AppController extends ChangeNotifier {
  AppController({
    required RecentFilesRepository recentFilesRepository,
    required SettingsRepository settingsRepository,
    required FilePickerService filePickerService,
    required DwgRendererService dwgRendererService,
    required IncomingDrawingService incomingDrawingService,
    required ThumbnailService thumbnailService,
    required SampleDrawingService sampleDrawingService,
  })  : _recentFilesRepository = recentFilesRepository,
        _settingsRepository = settingsRepository,
        _filePickerService = filePickerService,
        _dwgRendererService = dwgRendererService,
        _incomingDrawingService = incomingDrawingService,
        _thumbnailService = thumbnailService,
        _sampleDrawingService = sampleDrawingService {
    _incomingDrawingService.onDrawingReceived = _handleIncomingDrawing;
  }

  final RecentFilesRepository _recentFilesRepository;
  final SettingsRepository _settingsRepository;
  final FilePickerService _filePickerService;
  final DwgRendererService _dwgRendererService;
  final IncomingDrawingService _incomingDrawingService;
  final ThumbnailService _thumbnailService;
  final SampleDrawingService _sampleDrawingService;

  List<RecentFile> _recentFiles = [];
  AppSettings _settings = const AppSettings();
  RecentFile? _pendingIncomingFile;
  bool _isPickingFile = false;
  String? _lastError;

  List<RecentFile> get recentFiles => List.unmodifiable(_recentFiles);
  AppSettings get settings => _settings;
  bool get isPickingFile => _isPickingFile;
  String? get lastError => _lastError;
  DwgRendererService get dwgRendererService => _dwgRendererService;
  RecentFile? get pendingIncomingFile => _pendingIncomingFile;

  Future<void> load() async {
    _settings = _settingsRepository.loadSettings();
    appLanguage = _settings.language;
    _recentFiles = _recentFilesRepository.loadRecentFiles();
    // Backfill sizes for entries saved before size tracking (or whose intent
    // payload lacked one) so every recents row shows its MB.
    _recentFiles = _recentFiles
        .map((f) => f.fileSizeBytes == null
            ? f.copyWith(fileSizeBytes: _statFileSize(f.uri))
            : f)
        .toList();

    // First launch (or after the bundled drawing/name is updated): put the demo
    // at the top. Replace any previous builtin-sample entry by id so a renamed
    // or re-seeded demo overwrites the stale one instead of being dropped.
    final sample = await _sampleDrawingService.ensureSeeded();
    if (sample != null) {
      _recentFiles = [
        sample,
        ..._recentFiles.where((existing) => existing.id != sample.id),
      ];
    }

    await _recentFilesRepository.saveRecentFiles(_recentFiles);
    notifyListeners();

    final initialFile = await _incomingDrawingService.getInitialDrawing();
    if (initialFile != null) {
      await _handleIncomingDrawing(initialFile);
    }
  }

  Future<RecentFile?> pickDwgFile() async {
    _isPickingFile = true;
    _lastError = null;
    notifyListeners();

    try {
      final file = await _filePickerService.pickDwgFile();
      if (file == null) return null;
      await addOrRefreshRecentFile(file);
      return file;
    } catch (error) {
      _lastError = 'Unable to open DWG file.';
      return null;
    } finally {
      _isPickingFile = false;
      notifyListeners();
    }
  }

  Future<void> addOrRefreshRecentFile(RecentFile file) async {
    // Stamp "now" so the just-opened file sorts to the top — the list is ordered
    // by last-opened, and reusing the old timestamp would leave it in place.
    // Backfill a missing file size (files arriving via share/VIEW intents don't
    // always carry one) so every row can show its MB in the recents list.
    final refreshed = file.copyWith(
      lastOpenedAt: DateTime.now(),
      fileSizeBytes: file.fileSizeBytes ?? _statFileSize(file.uri),
    );
    _recentFiles = [
      refreshed,
      ..._recentFiles.where((existing) => existing.uri != file.uri),
    ];
    await _recentFilesRepository.saveRecentFiles(_recentFiles);
    _recentFiles = _recentFilesRepository.loadRecentFiles();
    notifyListeners();
  }

  /// Size in bytes of the file behind [uri], when it points at a readable
  /// local path (plain path or file:// URI). content:// and unreadable paths
  /// return null — the row simply shows no size then.
  int? _statFileSize(String uri) {
    try {
      final path = uri.startsWith('file://') ? Uri.parse(uri).toFilePath() : uri;
      final f = File(path);
      if (!f.existsSync()) return null;
      final len = f.lengthSync();
      return len > 0 ? len : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> removeRecentFile(RecentFile file) async {
    _recentFiles =
        _recentFiles.where((existing) => existing.uri != file.uri).toList();
    await _recentFilesRepository.saveRecentFiles(_recentFiles);
    _recentFiles = _recentFilesRepository.loadRecentFiles();
    notifyListeners();
    // Drop the preview PNG so removed files don't leave orphaned thumbnails.
    await _thumbnailService.remove(file.id);
  }

  /// Renames the drawing: the file on disk too when [file.uri] is a plain
  /// local path (content:// sources only get their display name updated).
  /// The extension is preserved so a renamed DWG stays openable.
  Future<void> renameRecentFile(RecentFile file, String newName) async {
    var name = newName.trim();
    if (name.isEmpty || name == file.name) return;
    if (!name.toLowerCase().endsWith('.${file.fileExtension}')) {
      name = '$name.${file.fileExtension}';
    }
    var uri = file.uri;
    try {
      final f = File(uri);
      if (f.existsSync()) {
        final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final dest = '${f.parent.path}${Platform.pathSeparator}$safe';
        if (dest != uri && !File(dest).existsSync()) {
          f.renameSync(dest);
          uri = dest;
        }
      }
    } catch (_) {
      // Disk rename failed (read-only location, etc.) — still rename the entry.
    }
    _recentFiles = _recentFiles
        .map((item) =>
            item.id == file.id ? item.copyWith(name: name, uri: uri) : item)
        .toList();
    await _recentFilesRepository.saveRecentFiles(_recentFiles);
    _recentFiles = _recentFilesRepository.loadRecentFiles();
    notifyListeners();
  }

  /// Deletes the drawing itself (when it lives on a local path) and every
  /// trace of it: recents entry, thumbnail and attached photo notes.
  Future<void> deleteRecentFile(RecentFile file) async {
    try {
      final f = File(file.uri);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // Best-effort: a content:// source can't be deleted from here.
    }
    await PhotosRepository().clearForFile(file.id);
    await removeRecentFile(file);
  }

  /// Renders a preview thumbnail for [file] from its parsed [scene] (once) and
  /// stores the path on the recent entry. Called by the viewer after a drawing
  /// finishes loading. A no-op if the file already has a usable thumbnail.
  Future<void> ensureThumbnail(
    RecentFile file,
    DwgScene scene, {
    Set<int> hiddenLayers = const {},
  }) async {
    final existingPath = file.thumbnailPath;
    // Regenerate when the recorded PNG no longer exists on disk (cleared cache,
    // OS eviction) — otherwise the stale path suppressed regeneration and the
    // recents row lost its preview forever.
    if (existingPath != null &&
        existingPath.isNotEmpty &&
        File(existingPath).existsSync()) {
      return;
    }
    final path = await _thumbnailService.generate(
      file.id,
      scene,
      hiddenLayers: hiddenLayers,
    );
    if (path == null) return;
    var changed = false;
    _recentFiles = _recentFiles.map((item) {
      if (item.id == file.id) {
        changed = true;
        return item.copyWith(thumbnailPath: path);
      }
      return item;
    }).toList();
    if (!changed) return;
    await _recentFilesRepository.saveRecentFiles(_recentFiles);
    _recentFiles = _recentFilesRepository.loadRecentFiles();
    notifyListeners();
  }

  Future<void> consumePendingIncomingFile() async {
    _pendingIncomingFile = null;
    notifyListeners();
  }

  Future<void> _handleIncomingDrawing(RecentFile file) async {
    // If this exact drawing is already in Recents (same bytes — e.g. a file
    // we shared over WhatsApp coming back, or the same project sent twice),
    // open the EXISTING entry instead of a fresh copy: its name, measurements
    // and photo pins all come along, and no duplicate row is created.
    final match = await _findExistingCopy(file);
    if (match != null) {
      try {
        File(file.uri).deleteSync();
      } catch (_) {
        // Best-effort cleanup of the redundant cache copy.
      }
      await addOrRefreshRecentFile(match);
      _pendingIncomingFile = match;
      notifyListeners();
      return;
    }
    await addOrRefreshRecentFile(file);
    _pendingIncomingFile = file;
    notifyListeners();
  }

  /// Recents entry whose stored file is byte-identical to [incoming], or null.
  /// Cheap check: equal length + equal first/last 64KB — copies of a shared
  /// drawing are byte-identical, and length collisions among different DWGs
  /// are already rare.
  Future<RecentFile?> _findExistingCopy(RecentFile incoming) async {
    final File inFile;
    final int inLen;
    try {
      inFile = File(incoming.uri);
      if (!inFile.existsSync()) return null;
      inLen = inFile.lengthSync();
    } catch (_) {
      return null;
    }
    for (final existing in _recentFiles) {
      var p = existing.uri;
      if (p.startsWith('content://')) continue;
      if (p.startsWith('file://')) p = Uri.parse(p).toFilePath();
      if (p == incoming.uri) continue;
      try {
        final ef = File(p);
        if (!ef.existsSync() || ef.lengthSync() != inLen) continue;
        if (_sameContent(inFile, ef, inLen)) return existing;
      } catch (_) {
        // Unreadable entry — skip it.
      }
    }
    return null;
  }

  static bool _sameContent(File a, File b, int len) {
    const chunk = 64 * 1024;
    bool equalAt(int start, int count) {
      final ra = a.openSync();
      final rb = b.openSync();
      try {
        ra.setPositionSync(start);
        rb.setPositionSync(start);
        final ba = ra.readSync(count);
        final bb = rb.readSync(count);
        if (ba.length != bb.length) return false;
        for (var i = 0; i < ba.length; i++) {
          if (ba[i] != bb[i]) return false;
        }
        return true;
      } finally {
        ra.closeSync();
        rb.closeSync();
      }
    }

    final head = len < chunk ? len : chunk;
    if (!equalAt(0, head)) return false;
    if (len > chunk) {
      if (!equalAt(len - chunk, chunk)) return false;
    }
    return true;
  }

  Future<void> togglePinned(RecentFile file) async {
    _recentFiles = _recentFiles.map((item) {
      return item.id == file.id ? item.copyWith(isPinned: !item.isPinned) : item;
    }).toList();
    await _recentFilesRepository.saveRecentFiles(_recentFiles);
    _recentFiles = _recentFilesRepository.loadRecentFiles();
    notifyListeners();
  }

  /// 'system', 'tr' or 'en' — takes effect immediately (widgets rebuild via
  /// notifyListeners and read the l10n override).
  Future<void> updateLanguage(String language) async {
    _settings = _settings.copyWith(language: language);
    appLanguage = language;
    await _settingsRepository.saveSettings(_settings);
    notifyListeners();
  }

  Future<void> updateThemeMode(ThemeMode themeMode) async {
    _settings = _settings.copyWith(themeMode: themeMode);
    await _settingsRepository.saveSettings(_settings);
    notifyListeners();
  }

  /// Persists the viewer display preferences so every next drawing opens with
  /// them (called by the viewer's settings sheet on each change).
  Future<void> updateViewerDefaults({
    bool? bgWhite,
    bool? monochrome,
    bool? lineWeights,
  }) async {
    _settings = _settings.copyWith(
      viewerBgWhite: bgWhite,
      viewerMonochrome: monochrome,
      viewerLineWeights: lineWeights,
    );
    await _settingsRepository.saveSettings(_settings);
    notifyListeners();
  }

  /// Total bytes of everything the app keeps on disk: preview PNGs, parsed
  /// scene binaries, cached copies of opened drawings and preferences. Shown
  /// in Settings so "Local storage" reports real usage, not a made-up number.
  Future<int> computeStorageUsageBytes() async {
    var total = 0;
    Future<void> addDir(String path) async {
      try {
        final dir = Directory(path);
        if (!dir.existsSync()) return;
        await for (final e in dir.list(recursive: true, followLinks: false)) {
          if (e is File) {
            try {
              total += e.lengthSync();
            } catch (_) {}
          }
        }
      } catch (_) {}
    }

    await addDir((await getApplicationDocumentsDirectory()).path);
    await addDir((await getApplicationSupportDirectory()).path);
    await addDir((await getTemporaryDirectory()).path);
    return total;
  }

  Future<void> clearCache() async {
    await _thumbnailService.clearAll();
    // Parsed scene binaries are pure cache too — they re-generate on the next
    // open. The DWG copies themselves are kept (recents must stay openable).
    try {
      final support = await getApplicationSupportDirectory();
      for (final f in Directory(support.path).listSync()) {
        final name = f.uri.pathSegments.last;
        if (f is File &&
            (name == 'last_scene.bin' ||
                name == 'last_scene.bin.timing' ||
                (name.startsWith('scene_') &&
                    (name.endsWith('.bin') || name.endsWith('.timing'))))) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
    // Forget the stored thumbnail paths so the list falls back to the icon
    // until each drawing is reopened and re-rendered.
    _recentFiles = _recentFiles
        .map((item) => (item.thumbnailPath ?? '').isEmpty
            ? item
            : item.copyWith(thumbnailPath: ''))
        .toList();
    await _recentFilesRepository.saveRecentFiles(_recentFiles);
    _recentFiles = _recentFilesRepository.loadRecentFiles();
    notifyListeners();
  }
}
