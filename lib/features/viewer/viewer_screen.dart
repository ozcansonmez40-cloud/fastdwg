import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/l10n/l10n.dart';
import '../../data/models/dwg_scene.dart';
import '../../data/models/recent_file.dart';
import '../../data/repositories/annotations_repository.dart';
import '../../data/repositories/camera_repository.dart';
import '../../features/app/app_controller.dart';
import '../../services/dwg_export_service.dart';
import '../../services/dwg_renderer_service.dart';
import '../../shared/widgets/blueprint_background.dart';
import '../../shared/widgets/dwg_viewport.dart';
import '../../shared/widgets/walking_worker.dart';
import '../../shared/widgets/technical_chip.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radii.dart';

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, required this.file});

  final RecentFile file;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  DwgRendererState _renderState = const DwgRendererState(
    status: DwgRenderStatus.loading,
  );

  /// Indices into the scene's layer table that are toggled off. Initialised
  /// from the DWG's own off/frozen flags, then user-controlled via the panel.
  final Set<int> _hiddenLayers = {};

  /// Measure tool: when active, taps place points (distance = 2 points, area =
  /// a polygon) and the live result is reported back here.
  bool _measureMode = false;
  MeasureType _measureType = MeasureType.distance;
  // Whether the active sub-tool (Distance/Area/Rectangle…) currently captures
  // taps. Set when a sub-tool is pressed, cleared when a shape is finished — the
  // panel stays open either way.
  bool _toolArmed = false;
  MeasureResult? _measureResult;
  int _measureClearToken = 0;
  int _measureUndoToken = 0;

  /// Draw tool: when active, taps place shape points (polyline/rect/circle/arc).
  /// Measure and Draw are mutually exclusive.
  bool _drawMode = false;
  DrawTool _drawTool = DrawTool.polyline;

  /// Export: select a region (rectangle / visible view / whole drawing) and
  /// share it as PDF + PNG.
  final DwgExportService _exportService = DwgExportService();
  bool _exportSelectMode = false; // dragging a rectangle to export
  bool _exporting = false; // rendering/sharing in progress
  DwgBounds? _visibleBounds; // current on-screen region (for "visible" export)

  /// Settings: appearance of the drawing + comment/draw overlays.
  Color _commentColor = const Color(0xFFFFB300);
  bool _bgWhite = false; // background black (default) vs white
  bool _drawingMono = false; // original colors vs black/white
  String _unit = 'u'; // measurement unit label

  // What ONE raw model unit represents ($INSUNITS code: 4=mm, 5=cm, 6=m).
  // DWG headers often lie about this (the untouched AutoCAD default says mm
  // while the model is really cm), so mm/unitless headers are NOT trusted and
  // fall back to cm. A header explicitly set to cm or m is adopted on load
  // (see _prepareRenderer); the user can flip it in Settings either way.
  int _modelUnit = 5; // cm

  // Draw each layer at its DWG lineweight (thick walls etc.) vs. a uniform
  // hairline. Toggleable in Settings; applies to both screen and PDF export.
  bool _lineWeights = true;

  // ── Çizim içinde metin arama ──
  bool _searchOpen = false;
  final TextEditingController _searchCtl = TextEditingController();
  List<int> _searchMatches = const []; // scene.texts içindeki eşleşen indeksler
  int _searchPos = -1; // o anki eşleşme (0..matches-1)
  Offset? _focusTarget; // viewport'un odaklanacağı model noktası
  double _focusSpan = 0; // o noktada görünür olacak model yüksekliği
  int _focusToken = 0; // her artışta viewport yeniden odaklanır
  int _fitToken = 0; // her artışta tüm çizime sığdırılır (zoom-extents)

  // Dosya bazında kaydedilen çizim/ölçümler.
  final AnnotationsRepository _annotationsRepo = AnnotationsRepository();
  String? _annotations; // açılışta yüklenen JSON, viewport'a verilir

  // Dosya bazında son bakılan bölge — kapatıp açınca kaldığın yerden devam.
  final CameraRepository _cameraRepo = CameraRepository();

  static const List<String> _units = ['u', 'mm', 'cm', 'm', 'in', 'ft'];

  int get _effectiveInsUnits => _modelUnit;

  static const List<Color> _commentColors = [
    Color(0xFFFFB300), // amber
    Color(0xFFFF3B30), // red
    Color(0xFF34C759), // green
    Color(0xFF0A84FF), // blue
    Color(0xFF31E0C8), // cyan
    Color(0xFFFF2D95), // magenta
    Color(0xFFFFFFFF), // white
    Color(0xFFAF52DE), // purple
  ];

  @override
  void initState() {
    super.initState();
    // Start from the remembered viewer defaults (set in any previous session's
    // settings sheet) instead of hard-coded ones.
    final saved = context.read<AppController>().settings;
    _bgWhite = saved.viewerBgWhite;
    _drawingMono = saved.viewerMonochrome;
    _lineWeights = saved.viewerLineWeights;
    _prepareRenderer();
    _loadAnnotations();
  }

  Future<void> _loadAnnotations() async {
    final json = await _annotationsRepo.load(widget.file.id);
    if (!mounted || json == null) return;
    setState(() => _annotations = json);
  }

  void _onAnnotationsChanged(String json) {
    // Fire-and-forget save; keep the in-memory copy so it isn't reloaded.
    _annotations = json;
    _annotationsRepo.save(widget.file.id, json);
  }

  @override
  void dispose() {
    // Remember where the user was looking so the next open resumes there
    // (fire-and-forget; prefs write outlives this state object safely).
    final b = _visibleBounds;
    if (b != null) {
      _cameraRepo.save(widget.file.id, b.minX, b.minY, b.maxX, b.maxY);
    }
    _searchCtl.dispose();
    super.dispose();
  }

  // Arama çubuğunu aç/kapat. Kapatınca eşleşmeler ve odak temizlenir.
  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _searchCtl.clear();
        _searchMatches = const [];
        _searchPos = -1;
      }
    });
  }

  // Türkçe duyarlı küçük harfe çevirme (İ/I ayrımı dahil).
  String _norm(String s) =>
      s.replaceAll('İ', 'i').replaceAll('I', 'ı').toLowerCase();

  void _runSearch(String query) {
    final scene = _renderState.scene;
    final q = _norm(query.trim());
    if (scene == null || q.isEmpty) {
      setState(() {
        _searchMatches = const [];
        _searchPos = -1;
      });
      return;
    }
    final matches = <int>[];
    for (var i = 0; i < scene.texts.length; i++) {
      if (_norm(scene.texts[i].value).contains(q)) matches.add(i);
    }
    setState(() {
      _searchMatches = matches;
      _searchPos = matches.isEmpty ? -1 : 0;
    });
    if (matches.isNotEmpty) _focusOnMatch();
  }

  // Sonraki/önceki eşleşmeye geç (delta +1/-1), döngüsel.
  void _stepMatch(int delta) {
    if (_searchMatches.isEmpty) return;
    setState(() {
      _searchPos = (_searchPos + delta) % _searchMatches.length;
      if (_searchPos < 0) _searchPos += _searchMatches.length;
    });
    _focusOnMatch();
  }

  // O anki eşleşen metnin konumuna viewport'u odakla.
  void _focusOnMatch() {
    final scene = _renderState.scene;
    if (scene == null || _searchPos < 0 || _searchPos >= _searchMatches.length) {
      return;
    }
    final t = scene.texts[_searchMatches[_searchPos]];
    final h = t.height.isFinite && t.height > 0 ? t.height : 1.0;
    setState(() {
      _focusTarget = Offset(t.x, t.y);
      _focusSpan = h * 45.0; // metin ekranın ~1/45'i kadar olacak şekilde yakınlaş
      _focusToken++;
    });
  }

  Future<void> _prepareRenderer() async {
    final service = context.read<AppController>().dwgRendererService;
    final state = await service.prepare(widget.file);
    if (!mounted) return;
    setState(() {
      _renderState = state;
      // Adopt the header's $INSUNITS only when it explicitly says cm or m —
      // someone set those on purpose. mm/unitless is usually the untouched
      // AutoCAD template default on a model really drawn in cm, so those keep
      // the cm assumption (user can still flip it in Settings).
      // Auto-detect the drawing's own unit from the header. cm/m/in/ft are
      // adopted as-is — someone set those deliberately. mm(4)/unitless(0) are
      // NOT trusted: that's the untouched AutoCAD template default and real
      // drawings (e.g. this project's own test file: header says mm, model is
      // cm) lie exactly there, so those keep the cm assumption.
      final hdrUnits = state.scene?.insUnits ?? 0;
      if (hdrUnits == 1 || hdrUnits == 2 || hdrUnits == 5 || hdrUnits == 6) {
        _modelUnit = hdrUnits;
      }
      // Measurements open directly in the detected unit — no manual pick.
      _unit = switch (_modelUnit) {
        1 => 'in',
        2 => 'ft',
        4 => 'mm',
        6 => 'm',
        _ => 'cm',
      };
      _hiddenLayers.clear();
      final layers = state.scene?.layers ?? const [];
      for (var i = 0; i < layers.length; i++) {
        if (!layers[i].visible) _hiddenLayers.add(i);
      }
    });
    _restoreCamera();
  }

  /// Jumps to the region the user was viewing when this file was last closed.
  Future<void> _restoreCamera() async {
    if (_renderState.scene == null) return;
    final b = await _cameraRepo.load(widget.file.id);
    if (!mounted || b == null) return;
    setState(() {
      _focusTarget = Offset((b[0] + b[2]) / 2, (b[1] + b[3]) / 2);
      _focusSpan = b[3] - b[1];
      _focusToken++;
    });
  }

  void _onMeasureTap() {
    if (_renderState.scene == null) return;
    setState(() {
      _measureMode = !_measureMode;
      if (_measureMode) _drawMode = false; // mutually exclusive
      _toolArmed = _measureMode; // arm the sub-tool when the panel opens
      _measureResult = null;
    });
  }

  void _onDrawTap() {
    if (_renderState.scene == null) return;
    setState(() {
      _drawMode = !_drawMode;
      if (_drawMode) _measureMode = false; // mutually exclusive
      _toolArmed = _drawMode;
      _measureResult = null;
    });
  }

  void _setDrawTool(DrawTool tool) {
    // Pressing a sub-tool (re-)arms it.
    setState(() {
      _drawTool = tool;
      _toolArmed = true;
    });
  }

  // A shape/measurement was finished → DISARM the active sub-tool (Distance /
  // Area / Rectangle …) so it no longer captures taps, but keep the panel open.
  // The user re-presses the same sub-tool to draw/measure another. The panel
  // only closes when the bottom Measure/Draw button is pressed again.
  void _onShapeCompleted() {
    if (!_toolArmed) return;
    setState(() {
      _toolArmed = false;
    });
  }

  void _onExportTap() {
    if (_renderState.scene == null || _exporting) return;
    // Export is its own mode — drop measure/draw so taps don't conflict.
    setState(() {
      _measureMode = false;
      _drawMode = false;
    });
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgDeep,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 16, 18, 8),
                child: TechnicalChip(label: 'EXPORT', icon: Icons.ios_share),
              ),
              _ExportOption(
                icon: Icons.fit_screen,
                title: tr('Visible view', 'Görünen alan'),
                subtitle: tr('Share the area currently on screen as a PDF', 'Ekrandaki alanı PDF olarak paylaş'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  final scene = _renderState.scene;
                  if (scene == null) return;
                  _runExport(_visibleBounds ?? scene.drawableBounds);
                },
              ),
              _ExportOption(
                icon: Icons.crop,
                title: tr('Select area', 'Alan seç'),
                subtitle: tr('Draw a box and share only that region as a PDF', 'Kutu çiz, yalnızca o bölgeyi PDF olarak paylaş'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  setState(() => _exportSelectMode = true);
                },
              ),
              _ExportOption(
                icon: Icons.crop_free,
                title: tr('Whole drawing', 'Tüm çizim'),
                subtitle: tr('Share the entire drawing as a PDF', 'Çizimin tamamını PDF olarak paylaş'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  final scene = _renderState.scene;
                  if (scene == null) return;
                  _runExport(scene.drawableBounds);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _onExportRectSelected(DwgBounds region) {
    setState(() => _exportSelectMode = false);
    _runExport(region);
  }

  void _cancelExportSelect() {
    setState(() => _exportSelectMode = false);
  }

  Future<void> _runExport(DwgBounds region) async {
    final scene = _renderState.scene;
    if (scene == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      await _exportService.shareRegion(
        scene: scene,
        region: region,
        hiddenLayers: _hiddenLayers,
        baseName: widget.file.name,
        showLineWeights: _lineWeights,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Export failed.', 'Dışa aktarma başarısız.')),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _onMeasureResult(MeasureResult? result) {
    setState(() => _measureResult = result);
  }

  void _setMeasureType(MeasureType type) {
    // Pressing a sub-tool (re-)arms it — even the same one again (so you can
    // start a fresh measurement after the previous finished).
    setState(() {
      _measureType = type;
      _measureResult = null;
      _toolArmed = true;
    });
  }

  void _clearMeasure() {
    setState(() {
      _measureClearToken++;
      _measureResult = null;
    });
  }

  void _showSettings() {
    if (_renderState.scene == null) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgDeep,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            void apply(VoidCallback change) {
              setSheetState(() {});
              setState(change);
              // Remember the display prefs as defaults for every next drawing
              // (fire-and-forget; unit/modelUnit stay per-drawing because
              // they're auto-detected from each file's header).
              context.read<AppController>().updateViewerDefaults(
                    bgWhite: _bgWhite,
                    monochrome: _drawingMono,
                    lineWeights: _lineWeights,
                  );
            }

            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const TechnicalChip(
                      label: 'SETTINGS',
                      icon: Icons.tune,
                    ),
                    const SizedBox(height: 18),
                    _SettingsLabel(tr('Comment color', 'Yorum rengi')),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 14,
                      runSpacing: 12,
                      children: [
                        for (final c in _commentColors)
                          GestureDetector(
                            onTap: () => apply(() => _commentColor = c),
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: c,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _commentColor == c
                                      ? Colors.white
                                      : AppColors.border,
                                  width: _commentColor == c ? 3 : 1,
                                ),
                              ),
                              child: _commentColor == c
                                  ? const Icon(Icons.check,
                                      size: 18, color: Colors.black)
                                  : null,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    _SettingsLabel(tr('Background color', 'Arka plan rengi')),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _SettingsChoice(
                          label: tr('Black', 'Siyah'),
                          selected: !_bgWhite,
                          onTap: () => apply(() => _bgWhite = false),
                        ),
                        const SizedBox(width: 10),
                        _SettingsChoice(
                          label: tr('White', 'Beyaz'),
                          selected: _bgWhite,
                          onTap: () => apply(() => _bgWhite = true),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    _SettingsLabel(tr('Drawing color', 'Çizim rengi')),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _SettingsChoice(
                          label: tr('Original color', 'Orijinal renkler'),
                          selected: !_drawingMono,
                          onTap: () => apply(() => _drawingMono = false),
                        ),
                        const SizedBox(width: 10),
                        _SettingsChoice(
                          label: tr('Black/White', 'Siyah/Beyaz'),
                          selected: _drawingMono,
                          onTap: () => apply(() => _drawingMono = true),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    _SettingsLabel(tr('Measurement unit', 'Ölçü birimi')),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final u in _units)
                          _SettingsChoice(
                            label: u == 'u' ? 'units' : u,
                            selected: _unit == u,
                            onTap: () => apply(() => _unit = u),
                          ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    _SettingsLabel(tr('Drawing unit (1 unit =)', 'Çizim birimi (1 birim =)')),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _SettingsChoice(
                          label: 'mm',
                          selected: _modelUnit == 4,
                          onTap: () => apply(() => _modelUnit = 4),
                        ),
                        _SettingsChoice(
                          label: 'cm',
                          selected: _modelUnit == 5,
                          onTap: () => apply(() => _modelUnit = 5),
                        ),
                        _SettingsChoice(
                          label: 'm',
                          selected: _modelUnit == 6,
                          onTap: () => apply(() => _modelUnit = 6),
                        ),
                        _SettingsChoice(
                          label: 'inch',
                          selected: _modelUnit == 1,
                          onTap: () => apply(() => _modelUnit = 1),
                        ),
                        _SettingsChoice(
                          label: 'feet',
                          selected: _modelUnit == 2,
                          onTap: () => apply(() => _modelUnit = 2),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    _SettingsLabel(tr('Line weights', 'Çizgi kalınlıkları')),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _SettingsChoice(
                          label: tr('On', 'Açık'),
                          selected: _lineWeights,
                          onTap: () => apply(() => _lineWeights = true),
                        ),
                        _SettingsChoice(
                          label: tr('Off', 'Kapalı'),
                          selected: !_lineWeights,
                          onTap: () => apply(() => _lineWeights = false),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _undoMeasure() {
    setState(() => _measureUndoToken++);
  }

  void _showLayerPanel() {
    final scene = _renderState.scene;
    if (scene == null) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgDeep,
      isScrollControlled: true,
      // A bit over half the screen so the search + list are usable on drawings
      // with many layers, while the drawing behind stays partly visible.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.55,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) => _LayerPanelSheet(
        scene: scene,
        initialHidden: _hiddenLayers,
        // Mirror the sheet's hidden-set into the viewer so the drawing updates
        // live behind the panel.
        onChanged: (hidden) => setState(() {
          _hiddenLayers
            ..clear()
            ..addAll(hidden);
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      extendBodyBehindAppBar: _renderState.scene != null,
      appBar: _renderState.scene == null
          ? AppBar(
              title: Text(
                widget.file.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            )
          : null,
      body: BlueprintBackground(
        child: SafeArea(
          top: _renderState.scene == null,
          bottom: _renderState.scene == null,
          child: Padding(
            padding: _renderState.scene == null
                ? const EdgeInsets.fromLTRB(16, 8, 16, 18)
                : EdgeInsets.zero,
            child: _renderState.scene == null
                ? (_renderState.status == DwgRenderStatus.error ||
                        _renderState.status == DwgRenderStatus.unsupported
                    ? _ViewerErrorView(
                        fileName: widget.file.name,
                        message: _renderState.message,
                      )
                    : _ViewerLoadingView(fileName: widget.file.name))
                : Stack(
                    children: [
                      _FullScreenDrawing(
                        file: widget.file,
                        renderState: _renderState,
                        hiddenLayers: Set<int>.of(_hiddenLayers),
                        onLayersTap: _showLayerPanel,
                        onMeasureTap: _onMeasureTap,
                        onDrawTap: _onDrawTap,
                        onSettingsTap: _showSettings,
                        onExportTap: _onExportTap,
                        onSearchTap: _toggleSearch,
                        exportSelectMode: _exportSelectMode,
                        exporting: _exporting,
                        onExportRectSelected: _onExportRectSelected,
                        onCancelExportSelect: _cancelExportSelect,
                        onVisibleBoundsChanged: (b) => _visibleBounds = b,
                        commentColor: _commentColor,
                        backgroundIsWhite: _bgWhite,
                        monochrome: _drawingMono,
                        unit: _unit,
                        insUnits: _effectiveInsUnits,
                        showLineWeights: _lineWeights,
                        focusTarget: _focusTarget,
                        focusSpan: _focusSpan,
                        focusToken: _focusToken,
                        fitToken: _fitToken,
                        onFitTap: () => setState(() => _fitToken++),
                        initialAnnotations: _annotations,
                        onAnnotationsChanged: _onAnnotationsChanged,
                        measureMode: _measureMode,
                        measureType: _measureType,
                        measureResult: _measureResult,
                        drawMode: _drawMode,
                        drawTool: _drawTool,
                        measureClearToken: _measureClearToken,
                        measureUndoToken: _measureUndoToken,
                        armed: _toolArmed,
                        onShapeCompleted: _onShapeCompleted,
                        onMeasureResult: _onMeasureResult,
                        onMeasureTypeChanged: _setMeasureType,
                        onDrawToolChanged: _setDrawTool,
                        onMeasureClear: _clearMeasure,
                        onMeasureUndo: _undoMeasure,
                      ),
                      if (_searchOpen)
                        Positioned(
                          left: 8,
                          right: 8,
                          top: 70,
                          child: SafeArea(
                            bottom: false,
                            child: _TextSearchBar(
                              controller: _searchCtl,
                              matchCount: _searchMatches.length,
                              position: _searchPos,
                              onChanged: _runSearch,
                              onPrev: () => _stepMatch(-1),
                              onNext: () => _stepMatch(1),
                              onClose: _toggleSearch,
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// Shown while the native parser decodes the file (can take a few seconds on a
/// large drawing).
class _ViewerLoadingView extends StatelessWidget {
  const _ViewerLoadingView({required this.fileName});

  final String fileName;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const WalkingWorker(size: 104),
          const SizedBox(height: 14),
          Text(
            tr('Opening drawing…', 'Çizim açılıyor…'),
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Text(
              fileName,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the file is corrupt or its DWG version isn't supported — a clean
/// message instead of a crash or a blank screen.
class _ViewerErrorView extends StatelessWidget {
  const _ViewerErrorView({required this.fileName, this.message});

  final String fileName;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                size: 56, color: AppColors.accentSecondary),
            const SizedBox(height: 16),
            const Text(
              "This drawing couldn't be opened",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message ??
                  tr('The file may be corrupted or its DWG version is not supported.', 'Dosya bozuk olabilir veya DWG sürümü desteklenmiyor.'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13.5,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back, size: 18),
              label: Text(tr('Go back', 'Geri dön')),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accentPrimary,
                side: const BorderSide(color: AppColors.accentPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FullScreenDrawing extends StatelessWidget {
  const _FullScreenDrawing({
    required this.file,
    required this.renderState,
    this.hiddenLayers = const {},
    this.onLayersTap,
    this.onMeasureTap,
    this.onDrawTap,
    this.onSettingsTap,
    this.onExportTap,
    this.onSearchTap,
    this.exportSelectMode = false,
    this.exporting = false,
    this.onExportRectSelected,
    this.onCancelExportSelect,
    this.onVisibleBoundsChanged,
    this.commentColor = const Color(0xFFFFB300),
    this.backgroundIsWhite = false,
    this.monochrome = false,
    this.unit = 'u',
    this.insUnits = 0,
    this.showLineWeights = true,
    this.focusTarget,
    this.focusSpan = 0,
    this.focusToken = 0,
    this.fitToken = 0,
    this.onFitTap,
    this.initialAnnotations,
    this.onAnnotationsChanged,
    this.measureMode = false,
    this.measureType = MeasureType.distance,
    this.measureResult,
    this.drawMode = false,
    this.drawTool = DrawTool.polyline,
    this.measureClearToken = 0,
    this.measureUndoToken = 0,
    this.armed = false,
    this.onShapeCompleted,
    this.onMeasureResult,
    this.onMeasureTypeChanged,
    this.onDrawToolChanged,
    this.onMeasureClear,
    this.onMeasureUndo,
  });

  final RecentFile file;
  final DwgRendererState renderState;
  final Set<int> hiddenLayers;
  final VoidCallback? onLayersTap;
  final VoidCallback? onMeasureTap;
  final VoidCallback? onDrawTap;
  final VoidCallback? onSettingsTap;
  final VoidCallback? onExportTap;
  final VoidCallback? onSearchTap;
  final bool exportSelectMode;
  final bool exporting;
  final ValueChanged<DwgBounds>? onExportRectSelected;
  final VoidCallback? onCancelExportSelect;
  final ValueChanged<DwgBounds>? onVisibleBoundsChanged;
  final Color commentColor;
  final bool backgroundIsWhite;
  final bool monochrome;
  final String unit;
  final int insUnits;
  final bool showLineWeights;
  final Offset? focusTarget;
  final double focusSpan;
  final int focusToken;
  final int fitToken;
  final VoidCallback? onFitTap;
  final String? initialAnnotations;
  final ValueChanged<String>? onAnnotationsChanged;
  final bool measureMode;
  final MeasureType measureType;
  final MeasureResult? measureResult;
  final bool drawMode;
  final DrawTool drawTool;
  final int measureClearToken;
  final int measureUndoToken;
  final bool armed;
  final VoidCallback? onShapeCompleted;
  final ValueChanged<MeasureResult?>? onMeasureResult;
  final ValueChanged<MeasureType>? onMeasureTypeChanged;
  final ValueChanged<DrawTool>? onDrawToolChanged;
  final VoidCallback? onMeasureClear;
  final VoidCallback? onMeasureUndo;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: DwgViewport(
            scene: renderState.scene,
            showOverview: false,
            title: 'MODEL SPACE',
            hiddenLayers: hiddenLayers,
            measureMode: measureMode,
            measureType: measureType,
            drawMode: drawMode,
            drawTool: drawTool,
            measureClearToken: measureClearToken,
            measureUndoToken: measureUndoToken,
            armed: armed,
            onShapeCompleted: onShapeCompleted,
            onMeasureResult: onMeasureResult,
            commentColor: commentColor,
            backgroundIsWhite: backgroundIsWhite,
            monochrome: monochrome,
            unit: unit,
            insUnits: insUnits,
            showLineWeights: showLineWeights,
            focusTarget: focusTarget,
            focusSpan: focusSpan,
            focusToken: focusToken,
            fitToken: fitToken,
            initialAnnotations: initialAnnotations,
            onAnnotationsChanged: onAnnotationsChanged,
            exportSelectMode: exportSelectMode,
            onExportRectSelected: onExportRectSelected,
            onVisibleBoundsChanged: onVisibleBoundsChanged,
          ),
        ),
        Positioned(
          left: 8,
          right: 8,
          top: 8,
          child: SafeArea(
            bottom: false,
            child: _FloatingViewerBar(
              file: file,
              renderState: renderState,
              onSearchTap: onSearchTap,
            ),
          ),
        ),
        Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (measureMode)
                _MeasureReadout(
                  type: measureType,
                  armed: armed,
                  result: measureResult,
                  unit: unit,
                  insUnits: insUnits,
                  onTypeChanged: onMeasureTypeChanged,
                  onClear: onMeasureClear,
                  onUndo: onMeasureUndo,
                ),
              if (drawMode)
                _DrawToolbar(
                  tool: drawTool,
                  armed: armed,
                  onToolChanged: onDrawToolChanged,
                  onClear: onMeasureClear,
                  onUndo: onMeasureUndo,
                ),
              if (exportSelectMode)
                _ExportSelectBar(onCancel: onCancelExportSelect),
              if (measureMode || drawMode || exportSelectMode)
                const SizedBox(height: 8),
              _ViewerBottomBar(
                onMeasureTap: onMeasureTap,
                onLayersTap: onLayersTap,
                onDrawTap: onDrawTap,
                onSettingsTap: onSettingsTap,
                onExportTap: onExportTap,
                measureActive: measureMode,
                drawActive: drawMode,
                exportActive: exportSelectMode,
              ),
            ],
          ),
        ),
        // Zoom-to-extents: fit the whole drawing back into view.
        Positioned(
          right: 12,
          bottom: 92,
          child: SafeArea(
            child: Material(
              color: AppColors.bgDeep.withValues(alpha: 0.92),
              shape: const CircleBorder(
                side: BorderSide(color: AppColors.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onFitTap,
                child: const Padding(
                  padding: EdgeInsets.all(11),
                  child: Icon(Icons.fit_screen,
                      size: 22, color: AppColors.textPrimary),
                ),
              ),
            ),
          ),
        ),
        if (exporting)
          const Positioned.fill(child: _ExportingOverlay()),
      ],
    );
  }
}

class _MeasureReadout extends StatelessWidget {
  const _MeasureReadout({
    required this.type,
    this.armed = false,
    this.result,
    this.unit = 'u',
    this.insUnits = 0,
    this.onTypeChanged,
    this.onClear,
    this.onUndo,
  });

  final MeasureType type;
  final bool armed;
  final MeasureResult? result;
  final String unit;
  final int insUnits;
  final ValueChanged<MeasureType>? onTypeChanged;
  final VoidCallback? onClear;
  final VoidCallback? onUndo;

  static String _format(double v) {
    if (!v.isFinite) return '–';
    if (v >= 100) return v.toStringAsFixed(1);
    if (v >= 1) return v.toStringAsFixed(2);
    return v.toStringAsFixed(4);
  }

  String _readout() {
    if (!armed) return tr('Tap a measurement to select it, then ✕ to delete.', 'Silmek için önce ölçüme dokun, sonra ✕.');
    final r = result;
    final f = dwgUnitFactor(unit, insUnits);
    switch (type) {
      case MeasureType.distance:
        if (r?.distance == null) return tr('Tap two points', 'İki noktaya dokun');
        return 'Distance: ${_format(r!.distance! * f)} $unit';
      case MeasureType.angle:
        if (r?.angleDeg == null) return tr('Tap 1st arm, then the vertex, then 2nd arm', 'Önce 1. kol, sonra köşe, sonra 2. kol');
        return 'Angle: ${r!.angleDeg!.toStringAsFixed(1)}°';
      case MeasureType.area:
        if (r?.area != null) {
          return 'Area: ${_format(r!.area! * f * f)} $unit²   ·   Perimeter: ${_format((r.perimeter ?? 0) * f)} $unit';
        }
        if (r?.perimeter != null) {
          return 'Perimeter: ${_format(r!.perimeter! * f)} $unit · add a 3rd point';
        }
        return tr('Tap corners (3+); tap the first point to close. Press Area again for a new one.', 'Köşelere dokun (3+); kapatmak için ilk noktaya dokun.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.bgDeep.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(AppRadii.input),
        border: Border.all(color: AppColors.accentPrimary),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _TypeChip(
                          label: tr('Distance', 'Mesafe'),
                          icon: Icons.straighten,
                          selected: armed && type == MeasureType.distance,
                          onTap: () => onTypeChanged?.call(MeasureType.distance),
                        ),
                        const SizedBox(width: 6),
                        _TypeChip(
                          label: tr('Angle', 'Açı'),
                          icon: Icons.architecture,
                          selected: armed && type == MeasureType.angle,
                          onTap: () => onTypeChanged?.call(MeasureType.angle),
                        ),
                        const SizedBox(width: 6),
                        _TypeChip(
                          label: tr('Area', 'Alan'),
                          icon: Icons.crop_square,
                          selected: armed && type == MeasureType.area,
                          onTap: () => onTypeChanged?.call(MeasureType.area),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: tr('Undo', 'Geri al'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.undo, size: 20),
                  color: AppColors.textSecondary,
                  onPressed: onUndo,
                ),
                IconButton(
                  tooltip: tr('Clear', 'Temizle'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: AppColors.textSecondary,
                  onPressed: onClear,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 2, 6, 2),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: AppColors.accentPrimary, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _readout(),
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawToolbar extends StatelessWidget {
  const _DrawToolbar({
    required this.tool,
    this.armed = false,
    this.onToolChanged,
    this.onClear,
    this.onUndo,
  });

  final DrawTool tool;
  final bool armed;
  final ValueChanged<DrawTool>? onToolChanged;
  final VoidCallback? onClear;
  final VoidCallback? onUndo;

  String get _hint {
    if (!armed) return tr('Tap a drawing to select it, then ✕ to delete.', 'Silmek için önce çizime dokun, sonra ✕.');
    return switch (tool) {
      DrawTool.polyline => tr('Tap points; tap the last point again to finish', 'Noktalara dokun; bitirmek için son noktaya tekrar dokun'),
      DrawTool.rectangle => tr('Tap two opposite corners', 'Karşılıklı iki köşeye dokun'),
      DrawTool.circle => tr('Tap the centre, then a point on the edge', 'Merkeze, sonra kenardan bir noktaya dokun'),
      DrawTool.arc => tr('Tap start, a point on the arc, then end', 'Başlangıca, yaydan bir noktaya, sonra bitişe dokun'),
    };
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.bgDeep.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(AppRadii.input),
        border: Border.all(color: AppColors.accentPrimary),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _TypeChip(
                          label: tr('Polyline', 'Çoklu çizgi'),
                          icon: Icons.timeline,
                          selected: armed && tool == DrawTool.polyline,
                          onTap: () => onToolChanged?.call(DrawTool.polyline),
                        ),
                        const SizedBox(width: 6),
                        _TypeChip(
                          label: tr('Rectangle', 'Dikdörtgen'),
                          icon: Icons.crop_square,
                          selected: armed && tool == DrawTool.rectangle,
                          onTap: () => onToolChanged?.call(DrawTool.rectangle),
                        ),
                        const SizedBox(width: 6),
                        _TypeChip(
                          label: tr('Circle', 'Daire'),
                          icon: Icons.circle_outlined,
                          selected: armed && tool == DrawTool.circle,
                          onTap: () => onToolChanged?.call(DrawTool.circle),
                        ),
                        const SizedBox(width: 6),
                        _TypeChip(
                          label: tr('Arc', 'Yay'),
                          icon: Icons.architecture,
                          selected: armed && tool == DrawTool.arc,
                          onTap: () => onToolChanged?.call(DrawTool.arc),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: tr('Undo', 'Geri al'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.undo, size: 20),
                  color: AppColors.textSecondary,
                  onPressed: onUndo,
                ),
                IconButton(
                  tooltip: tr('Clear', 'Temizle'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: AppColors.textSecondary,
                  onPressed: onClear,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 2, 6, 2),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: AppColors.accentPrimary, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _hint,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsLabel extends StatelessWidget {
  const _SettingsLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.textSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
      ),
    );
  }
}

class _SettingsChoice extends StatelessWidget {
  const _SettingsChoice({
    required this.label,
    required this.selected,
    this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accentPrimary.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.accentPrimary : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppColors.accentPrimary : AppColors.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    required this.label,
    required this.icon,
    required this.selected,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accentPrimary.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.accentPrimary : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 16,
                color: selected ? AppColors.accentPrimary : AppColors.textSecondary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? AppColors.accentPrimary : AppColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FloatingViewerBar extends StatelessWidget {
  const _FloatingViewerBar({
    required this.file,
    required this.renderState,
    this.onSearchTap,
  });

  final RecentFile file;
  final DwgRendererState renderState;
  final VoidCallback? onSearchTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.bgDeep.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(AppRadii.input),
        border: Border.all(color: AppColors.border),
      ),
      child: SizedBox(
        height: 54,
        child: Row(
          children: [
            IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
            ),
            Expanded(
              child: Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              '${renderState.entityCount}',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
            IconButton(
              onPressed: onSearchTap,
              tooltip: tr('Search text', 'Metin ara'),
              icon: const Icon(Icons.search, color: AppColors.textPrimary),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

/// Çizim içinde metin arama çubuğu: yaz, eşleşmeler arasında ◄ ► ile gez.
class _TextSearchBar extends StatelessWidget {
  const _TextSearchBar({
    required this.controller,
    required this.matchCount,
    required this.position,
    required this.onChanged,
    required this.onPrev,
    required this.onNext,
    required this.onClose,
  });

  final TextEditingController controller;
  final int matchCount;
  final int position; // 0 tabanlı; -1 = yok
  final ValueChanged<String> onChanged;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final hasQuery = controller.text.trim().isNotEmpty;
    final label = !hasQuery
        ? ''
        : (matchCount == 0 ? '0/0' : '${position + 1}/$matchCount');
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.bgDeep.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(AppRadii.input),
        border: Border.all(color: AppColors.accentPrimary),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
        child: Row(
          children: [
            const Icon(Icons.search, color: AppColors.textMuted, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: true,
                onChanged: onChanged,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => onNext(),
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: tr('Search text (room, number, grid...)', 'Metin ara (oda, numara, aks...)'),
                  hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 14),
                ),
              ),
            ),
            if (label.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  label,
                  style: TextStyle(
                    color: matchCount == 0
                        ? AppColors.accentSecondary
                        : AppColors.textSecondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            IconButton(
              onPressed: matchCount > 0 ? onPrev : null,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.keyboard_arrow_up, color: AppColors.textPrimary),
            ),
            IconButton(
              onPressed: matchCount > 0 ? onNext : null,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.keyboard_arrow_down, color: AppColors.textPrimary),
            ),
            IconButton(
              onPressed: onClose,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Layer panel: toggle visibility, isolate (solo), and search by name. A real
/// StatefulWidget so its search controller is disposed by the framework at the
/// right time (the old StatefulBuilder + manual whenComplete dispose tore an
/// InheritedWidget down with live dependents → red-screen on sheet close).
class _LayerPanelSheet extends StatefulWidget {
  const _LayerPanelSheet({
    required this.scene,
    required this.initialHidden,
    required this.onChanged,
  });

  final DwgScene scene;
  final Set<int> initialHidden;
  final ValueChanged<Set<int>> onChanged;

  @override
  State<_LayerPanelSheet> createState() => _LayerPanelSheetState();
}

class _LayerPanelSheetState extends State<_LayerPanelSheet> {
  late final Set<int> _hidden = {...widget.initialHidden};
  final TextEditingController _ctl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  String _norm(String s) =>
      s.replaceAll('İ', 'i').replaceAll('I', 'ı').toLowerCase();

  void _commit() => widget.onChanged(Set<int>.of(_hidden));

  @override
  Widget build(BuildContext context) {
    final scene = widget.scene;
    final count = scene.layers.length;
    final allHidden = _hidden.length >= count;
    final q = _norm(_query.trim());
    final shown = <int>[
      for (var i = 0; i < count; i++)
        if (q.isEmpty || _norm(scene.layers[i].name).contains(q)) i,
    ];
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 10, 4),
            child: Row(
              children: [
                const TechnicalChip(label: 'LAYERS', icon: Icons.layers_outlined),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    setState(() => _hidden.clear());
                    _commit();
                  },
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: Text(tr('All', 'Tümü')),
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.accentPrimary),
                ),
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      if (allHidden) {
                        _hidden.clear();
                      } else {
                        _hidden
                          ..clear()
                          ..addAll(List.generate(count, (k) => k));
                      }
                    });
                    _commit();
                  },
                  icon: Icon(
                    allHidden
                        ? Icons.visibility
                        : Icons.visibility_off_outlined,
                    size: 18,
                  ),
                  label: Text(allHidden ? tr('Show', 'Göster') : tr('Hide', 'Gizle')),
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SizedBox(
              height: 40,
              child: TextField(
                controller: _ctl,
                onChanged: (v) => setState(() => _query = v),
                style:
                    const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search,
                      size: 18, color: AppColors.textMuted),
                  hintText: tr('Search layers', 'Katman ara'),
                  hintStyle:
                      const TextStyle(color: AppColors.textMuted, fontSize: 13),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadii.input),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadii.input),
                    borderSide: const BorderSide(color: AppColors.accentPrimary),
                  ),
                ),
              ),
            ),
          ),
          Flexible(
            child: shown.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(tr('No layers match', 'Eşleşen katman yok'),
                        style: TextStyle(color: AppColors.textMuted)),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: shown.length,
                    itemBuilder: (context, idx) {
                      final i = shown[idx];
                      final layer = scene.layers[i];
                      final hidden = _hidden.contains(i);
                      final swatch = layer.color == 0
                          ? Colors.white
                          : Color(0xFF000000 | layer.color);
                      return CheckboxListTile(
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        activeColor: AppColors.accentPrimary,
                        value: !hidden,
                        onChanged: (_) {
                          setState(() {
                            if (hidden) {
                              _hidden.remove(i);
                            } else {
                              _hidden.add(i);
                            }
                          });
                          _commit();
                        },
                        secondary: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 16,
                              height: 16,
                              decoration: BoxDecoration(
                                color: swatch,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: AppColors.border),
                              ),
                            ),
                            IconButton(
                              tooltip: tr('Isolate', 'Sadece bu'),
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.lightbulb_outline, size: 20),
                              color: AppColors.textMuted,
                              onPressed: () {
                                setState(() {
                                  _hidden
                                    ..clear()
                                    ..addAll(List.generate(count, (k) => k)
                                        .where((k) => k != i));
                                });
                                _commit();
                              },
                            ),
                          ],
                        ),
                        title: Text(
                          layer.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 13),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ViewerBottomBar extends StatelessWidget {
  const _ViewerBottomBar({
    this.onMeasureTap,
    this.onLayersTap,
    this.onDrawTap,
    this.onSettingsTap,
    this.onExportTap,
    this.measureActive = false,
    this.drawActive = false,
    this.exportActive = false,
  });

  final VoidCallback? onMeasureTap;
  final VoidCallback? onLayersTap;
  final VoidCallback? onDrawTap;
  final VoidCallback? onSettingsTap;
  final VoidCallback? onExportTap;
  final bool measureActive;
  final bool drawActive;
  final bool exportActive;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.bgDeep.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(AppRadii.input),
        border: Border.all(color: AppColors.border),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _BottomAction(
                icon: Icons.straighten,
                label: tr('Measure', 'Ölç'),
                onTap: onMeasureTap,
                active: measureActive,
              ),
              _BottomAction(
                icon: Icons.edit_outlined,
                label: tr('Draw', 'Çiz'),
                onTap: onDrawTap,
                active: drawActive,
              ),
              _BottomAction(
                icon: Icons.layers_outlined,
                label: tr('Layers', 'Katmanlar'),
                onTap: onLayersTap,
              ),
              _BottomAction(
                icon: Icons.ios_share,
                label: tr('Export', 'Dışa aktar'),
                onTap: onExportTap,
                active: exportActive,
              ),
              _BottomAction(
                icon: Icons.tune,
                label: tr('Settings', 'Ayarlar'),
                onTap: onSettingsTap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomAction extends StatelessWidget {
  const _BottomAction({
    required this.icon,
    required this.label,
    this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.accentPrimary : AppColors.accentSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: active
            ? BoxDecoration(
                color: AppColors.accentPrimary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              )
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                color: active ? AppColors.accentPrimary : AppColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Instruction strip shown while the user is dragging an export-selection
/// rectangle, with a button to cancel back out of the mode.
class _ExportSelectBar extends StatelessWidget {
  const _ExportSelectBar({this.onCancel});

  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.bgDeep.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(AppRadii.input),
        border: Border.all(color: AppColors.accentPrimary),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Row(
          children: [
            const Icon(Icons.crop, color: AppColors.accentPrimary, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                tr('Draw a rectangle to export', 'Dışa aktarmak için dikdörtgen çiz'),
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              onPressed: onCancel,
              style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
              child: Text(tr('Cancel', 'Vazgeç')),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen blocking overlay shown while a region is being rendered and the
/// share sheet prepared.
class _ExportingOverlay extends StatelessWidget {
  const _ExportingOverlay();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.bgDeep.withValues(alpha: 0.55),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppColors.accentPrimary),
            const SizedBox(height: 16),
            Text(
              tr('Exporting…', 'Dışa aktarılıyor…'),
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One row in the export bottom sheet (an area-selection mode).
class _ExportOption extends StatelessWidget {
  const _ExportOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: AppColors.accentPrimary),
      title: Text(
        title,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
      ),
    );
  }
}

