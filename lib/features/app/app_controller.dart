import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/models/app_settings.dart';
import '../../data/models/recent_file.dart';
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
    await addOrRefreshRecentFile(file);
    _pendingIncomingFile = file;
    notifyListeners();
  }

  Future<void> togglePinned(RecentFile file) async {
    _recentFiles = _recentFiles.map((item) {
      return item.id == file.id ? item.copyWith(isPinned: !item.isPinned) : item;
    }).toList();
    await _recentFilesRepository.saveRecentFiles(_recentFiles);
    _recentFiles = _recentFilesRepository.loadRecentFiles();
    notifyListeners();
  }

  Future<void> updateThemeMode(ThemeMode themeMode) async {
    _settings = _settings.copyWith(themeMode: themeMode);
    await _settingsRepository.saveSettings(_settings);
    notifyListeners();
  }

  Future<void> clearCache() async {
    await _thumbnailService.clearAll();
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
