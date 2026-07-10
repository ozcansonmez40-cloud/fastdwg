import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;

import '../../data/models/dwg_scene.dart';
import '../../theme/app_colors.dart';
import 'blueprint_background.dart';
import 'technical_chip.dart';

/// Zoom-independent level-of-detail copies of a scene's line batches.
///
/// The painter chains consecutive sub-pixel segments into chords at paint
/// time, but it still has to WALK every raw segment to do so — with the whole
/// drawing on screen that's millions of iterations per frame and pan/zoom at
/// extents feels heavy. This store runs the SAME chaining offline in model
/// space at a couple of fixed thresholds (preserving stream order, which the
/// chaining depends on) and the painter simply iterates the small pre-chained
/// copy whenever one pixel spans at least that many model units.
class _SceneLod {
  final List<double> thresholds = []; // coarsest → finest, model units
  final List<Map<int, Float32List>> tiers = [];
  bool ready = false;
  bool building = false;
}

final Expando<_SceneLod> _sceneLodStore = Expando<_SceneLod>();

/// Builds the LOD tiers for [scene] once, chunked so the UI stays responsive.
Future<void> ensureSceneLod(DwgScene scene) async {
  final lod = _sceneLodStore[scene] ??= _SceneLod();
  if (lod.ready || lod.building) return;
  lod.building = true;
  final b = scene.drawableBounds;
  final span = math.max(b.width, b.height);
  if (span <= 0 || scene.lineSegmentCount < 200000) {
    // Small drawings paint fast anyway — skip the extra memory.
    lod.building = false;
    lod.ready = true;
    return;
  }
  var sinceYield = 0;
  Future<void> maybeYield() async {
    if (++sinceYield >= 60000) {
      sinceYield = 0;
      await Future<void>.delayed(Duration.zero);
    }
  }

  // ~0.4px at full extents on a phone; ~0.4px at 4× zoom. Finer views use the
  // raw data (offscreen culling already keeps those frames cheap).
  for (final t in [span / 2500.0, span / 10000.0]) {
    final t2 = t * t;
    final tier = <int, Float32List>{};
    for (final e in scene.lineBatches.entries) {
      final m = e.value;
      final out = <double>[];
      var chainX = double.nan, chainY = double.nan;
      var prevX2 = double.nan, prevY2 = double.nan;
      for (var i = 0; i + 3 < m.length; i += 4) {
        final x1 = m[i], y1 = m[i + 1], x2 = m[i + 2], y2 = m[i + 3];
        final gx = x1 - prevX2, gy = y1 - prevY2;
        final continues = !chainX.isNaN &&
            (gx * gx + gy * gy < t2 || (x1 == prevX2 && y1 == prevY2));
        final sx = continues ? chainX : x1;
        final sy = continues ? chainY : y1;
        prevX2 = x2;
        prevY2 = y2;
        final dx = sx - x2, dy = sy - y2;
        if (!(dx * dx + dy * dy >= t2)) {
          chainX = sx;
          chainY = sy;
          await maybeYield();
          continue;
        }
        chainX = double.nan;
        out
          ..add(sx)
          ..add(sy)
          ..add(x2)
          ..add(y2);
        await maybeYield();
      }
      tier[e.key] = Float32List.fromList(out);
    }
    lod.thresholds.add(t);
    lod.tiers.add(tier);
  }
  lod.ready = true;
  lod.building = false;
}

/// The coarsest pre-chained copy safe for the current zoom (chains up to
/// [minModelLen] model units — at most ~one pixel on screen), or null to use
/// the raw batch.
Float32List? _lodPick(DwgScene scene, int key, double minModelLen) {
  final lod = _sceneLodStore[scene];
  if (lod == null || !lod.ready) return null;
  for (var i = 0; i < lod.thresholds.length; i++) {
    if (lod.thresholds[i] <= minModelLen) return lod.tiers[i][key];
  }
  return null;
}

/// Millimetres represented by ONE raw model unit, from the DWG header
/// $INSUNITS. When the drawing is unitless (0) or an unknown code we fall back
/// to millimetres, which was the previous fixed assumption.
double dwgUnitMm(int insUnits) {
  switch (insUnits) {
    case 1:
      return 25.4; // inches
    case 2:
      return 304.8; // feet
    case 3:
      return 1609344.0; // miles
    case 4:
      return 1.0; // millimetres
    case 5:
      return 10.0; // centimetres
    case 6:
      return 1000.0; // metres
    case 14:
      return 100.0; // decimetres
    default:
      return 1.0; // unitless / unknown → assume mm
  }
}

/// Multiplier to convert a RAW model-space length into the chosen display unit,
/// honouring the drawing's own base unit ($INSUNITS). 'u' = raw model units (no
/// conversion, matches the drawing's stored numbers). Area uses the square of
/// this. Example: a cm-based drawing ([insUnits]==5) → 'cm' = ×1, 'mm' = ×10,
/// 'm' = ×0.01 — so a 488 cm span reads 488 cm, not 48.8.
double dwgUnitFactor(String unit, [int insUnits = 0]) {
  if (unit == 'u') return 1.0;
  final mm = dwgUnitMm(insUnits);
  switch (unit) {
    case 'cm':
      return mm / 10.0;
    case 'm':
      return mm / 1000.0;
    case 'in':
      return mm / 25.4;
    case 'ft':
      return mm / 304.8;
    default: // 'mm'
      return mm;
  }
}

/// Maps a raw DWG entity colour to the colour actually painted, honouring the
/// monochrome ("Black/White") and background (black vs white paper) settings.
/// Shared by the on-screen painter and the export renderer so both look
/// identical. See [_DwgScenePainter] for the rationale behind each rule.
Color dwgEntityColor(
  int? rawColor,
  Color fallback, {
  required bool monochrome,
  required bool backgroundIsWhite,
}) {
  if (monochrome) {
    return backgroundIsWhite ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
  }
  if (rawColor == null) return fallback;
  final rgb = rawColor & 0xFFFFFF;
  if (backgroundIsWhite) {
    if (rgb == 0xFFFFFF) return const Color(0xFF000000);
    return Color(0xFF000000 | rgb);
  }
  if (rgb == 0x000000) return const Color(0xFFFFFFFF);
  return Color(0xFF000000 | rgb);
}

/// Renders a small PNG preview of [scene] for the recent-files list. Uses the
/// same painter as the live viewport, fit-to-extents with no pan/zoom, so the
/// thumbnail matches what the user first sees when opening the drawing. Runs
/// off-screen via a [ui.PictureRecorder]; returns null if the scene has no
/// drawable bounds or rasterisation fails.
Future<Uint8List?> renderSceneThumbnail(
  DwgScene scene, {
  Set<int> hiddenLayers = const {},
  int width = 360,
  int height = 240,
}) async {
  try {
    final bounds = scene.drawableBounds;
    if (!bounds.width.isFinite ||
        !bounds.height.isFinite ||
        bounds.width <= 0 ||
        bounds.height <= 0) {
      return null;
    }
    final size = Size(width.toDouble(), height.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // Dark blueprint backdrop so a sparse drawing still reads as a card.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF0B1A2B),
    );
    final transform = _computeTransform(size, bounds, 1.0, Offset.zero);
    _paintDwgScene(
      canvas,
      size,
      scene,
      transform,
      hiddenLayers: hiddenLayers,
      monochrome: false,
      backgroundIsWhite: false,
      strokeWidth: 1.0,
      showLineWeights: false,
      // fast: skips fills/text and uses a uniform hairline — at thumbnail scale
      // the line work alone conveys the plan, and it keeps generation cheap.
      fast: true,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    image.dispose();
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

/// Draws the whole DWG scene (solid fills, lines, circles, and — unless [fast] —
/// text) into [canvas] using [transform]. Factored out of [_DwgScenePainter] so
/// the export pipeline ([renderDwgRegionToPng]) renders pixel-identical output
/// at an arbitrary resolution. Does NOT paint measurement/draw overlays.
void _paintDwgScene(
  Canvas canvas,
  Size size,
  DwgScene scene,
  _ViewTransform transform, {
  required Set<int> hiddenLayers,
  required bool monochrome,
  required bool backgroundIsWhite,
  required double strokeWidth,
  bool showLineWeights = true,
  bool fast = false,
}) {
  final ax = transform.ax;
  final bx = transform.bx;
  final ay = transform.ay;
  final by = transform.by;
  Offset mapPoint(double x, double y) => transform.toScreen(x, y);

  final paint = Paint()
    ..strokeWidth = strokeWidth
    ..style = PaintingStyle.stroke
    // Round caps so the tiny/zero-length segments that DOT & DASHDOT linetypes
    // emit render as visible dots instead of vanishing (butt caps have no
    // extent). At hairline width the effect on normal line ends is negligible.
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.miter
    ..isAntiAlias = !fast;

  final viewW = size.width;
  final viewH = size.height;
  final minLenSq = fast ? 9.0 : 0.25;

  // Solid fills (hatches) first, as background. EVEN-ODD winding — the rule
  // AutoCAD uses for solid hatches, so nested glyph loops carve holes instead of
  // ballooning into a blob.
  if (!fast && scene.fills.isNotEmpty) {
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;
    // Companion stroke: wall/slab poché is a THIN band (30–50 model units).
    // When the fitted scale makes that band a fraction of a pixel wide, the GPU
    // fill rasteriser drops some of them and keeps others (pixel-grid snapping),
    // so an identical hatch shows on one wall and vanishes on the neighbour.
    // Stroking the same path in the same colour guarantees every fill leaves at
    // least a 1px mark, so thin poché stays continuous at any zoom.
    final fillStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..isAntiAlias = false;
    for (final fill in scene.fills) {
      if (hiddenLayers.contains(fill.layer)) continue;
      final path = Path()..fillType = PathFillType.evenOdd;
      var any = false;
      for (final loop in fill.loops) {
        if (loop.length < 6) continue;
        path.moveTo(ax * loop[0] + bx, ay * loop[1] + by);
        for (var i = 2; i + 1 < loop.length; i += 2) {
          path.lineTo(ax * loop[i] + bx, ay * loop[i + 1] + by);
        }
        path.close();
        any = true;
      }
      if (!any) continue;
      final col = dwgEntityColor(fill.color, AppColors.accentPrimary,
          monochrome: monochrome, backgroundIsWhite: backgroundIsWhite);
      fillPaint.color = col;
      canvas.drawPath(path, fillPaint);
      fillStroke.color = col;
      canvas.drawPath(path, fillStroke);
    }
  }

  // Lines are drawn one BATCH (one colour) per `drawRawPoints` call instead of
  // a `drawLine` per segment. A dense drawing can hold >1M segments; issuing a
  // million draw ops chokes the GPU surface queue (frames stall, the app
  // freezes). drawRawPoints(PointMode.lines, ...) hands the whole batch to the
  // engine in a single call — culling still happens here, just into a packed
  // buffer the GPU clips cheaply.
  // Per-layer lineweight → a constant screen stroke width (CAD shows lineweight
  // at a fixed thickness regardless of zoom). Heavier layers (walls, columns)
  // get a proportionally thicker pen, capped so it never looks absurd; layers
  // with no/default weight keep the base hairline.
  final layers = scene.layers;
  double widthForLayer(int layerIdx) {
    if (!showLineWeights) return strokeWidth;
    if (layerIdx < 0 || layerIdx >= layers.length) return strokeWidth;
    final mm = layers[layerIdx].lineWeightMm;
    // Default-weight layers keep the base hairline. Heavier layers map to an
    // ABSOLUTE logical-pixel width (the base stroke is sub-pixel, so a relative
    // multiple would round to the same 1px and show no difference) — ~6 px/mm
    // gives a clear hierarchy (0.35 mm wall ≈ 2.1 px), capped at 4 px.
    if (mm <= 0.25) return strokeWidth;
    final w = mm * 6.0;
    return w < strokeWidth ? strokeWidth : (w > 4.0 ? 4.0 : w);
  }

  // Model-space length of the paint-time cull threshold: when a pre-chained
  // LOD copy exists at (or below) this coarseness, iterate IT instead of the
  // raw millions of segments — same visual result, a fraction of the work.
  final minModelLen = ax.abs() <= 0 ? 0.0 : math.sqrt(minLenSq) / ax.abs();
  scene.lineBatches.forEach((key, rawModel) {
    if (hiddenLayers.contains(DwgScene.batchLayer(key))) return;
    final model = _lodPick(scene, key, minModelLen) ?? rawModel;
    if (model.isEmpty) return;
    final pts = Float32List(model.length); // upper bound: 4 floats / segment
    var w = 0;
    // Sub-pixel segments are CHAINED, not dropped: a smoothed contour is
    // thousands of tiny segments in stream order (the native writer emits
    // polylines consecutively), and culling each one individually erased the
    // whole curve when zoomed out. Accumulate along the chain and emit one
    // decimated segment as soon as the running chord clears the threshold.
    var chainX = double.nan, chainY = double.nan; // pending chain start
    var prevX2 = double.nan, prevY2 = double.nan; // last raw endpoint
    for (var i = 0; i + 3 < model.length; i += 4) {
      final x1 = ax * model[i] + bx;
      final y1 = ay * model[i + 1] + by;
      final x2 = ax * model[i + 2] + bx;
      final y2 = ay * model[i + 3] + by;
      // Continue the pending chain if this segment starts where the previous
      // one ended — exactly (shared polyline vertex) or within the cull
      // threshold (dash gaps: hatch/linetype dashes are written sequentially,
      // so sub-pixel dashes merge into one thin line instead of vanishing).
      final gx = x1 - prevX2, gy = y1 - prevY2;
      final continues = !chainX.isNaN &&
          (gx * gx + gy * gy < minLenSq || (x1 == prevX2 && y1 == prevY2));
      final sx = continues ? chainX : x1;
      final sy = continues ? chainY : y1;
      prevX2 = x2;
      prevY2 = y2;
      final dx = sx - x2;
      final dy = sy - y2;
      if (!(dx * dx + dy * dy >= minLenSq)) {
        // Still sub-threshold (or NaN): keep accumulating.
        chainX = sx;
        chainY = sy;
        continue;
      }
      chainX = double.nan;
      if ((sx < 0 && x2 < 0) ||
          (sx > viewW && x2 > viewW) ||
          (sy < 0 && y2 < 0) ||
          (sy > viewH && y2 > viewH)) {
        continue;
      }
      pts[w++] = sx;
      pts[w++] = sy;
      pts[w++] = x2;
      pts[w++] = y2;
    }
    if (w == 0) return;
    paint.color = dwgEntityColor(DwgScene.batchColor(key), AppColors.accentPrimary,
        monochrome: monochrome, backgroundIsWhite: backgroundIsWhite);
    paint.strokeWidth = fast ? strokeWidth : widthForLayer(DwgScene.batchLayer(key));
    canvas.drawRawPoints(
      ui.PointMode.lines,
      Float32List.view(pts.buffer, 0, w),
      paint,
    );
  });

  final circleCoords = scene.circleCoords;
  final circleColors = scene.circleColors;
  final circleLayers = scene.circleLayers;
  for (var i = 0; i < circleColors.length; i++) {
    if (hiddenLayers.contains(circleLayers[i])) continue;
    final ccx = ax * circleCoords[i * 3] + bx;
    final ccy = ay * circleCoords[i * 3 + 1] + by;
    final r = circleCoords[i * 3 + 2] * ax;
    if (r < 0.25) continue;
    if (ccx + r < 0 || ccx - r > viewW || ccy + r < 0 || ccy - r > viewH) {
      continue;
    }
    paint.color = dwgEntityColor(circleColors[i], AppColors.accentSecondary,
        monochrome: monochrome, backgroundIsWhite: backgroundIsWhite);
    paint.strokeWidth = fast ? strokeWidth : widthForLayer(circleLayers[i]);
    canvas.drawCircle(Offset(ccx, ccy), r, paint);
  }

  // DOT/DASHDOT linetype marks — drawn as fixed screen-size round points so they
  // stay visible at any zoom (a model-space segment shrinks below the cull
  // threshold when zoomed out). Grouped by colour for one draw call each.
  if (scene.dotCount > 0) {
    final dotCoords = scene.dotCoords;
    final dotColors = scene.dotColors;
    final dotLayers = scene.dotLayers;
    final dotPaint = Paint()
      ..strokeCap = StrokeCap.round
      // Tied to the hairline width with NO absolute floor: the main viewport
      // draws lines at 0.65 *physical* px, so a logical-px floor (2.0/1.3)
      // rendered dots several times fatter than the linework on a high-DPI
      // phone. ×3 ≈ 2 physical px: clearly visible as a dot, but still lighter
      // than before (was ~4 px) and subordinate to solid walls, like AutoCAD.
      ..strokeWidth = strokeWidth * 3.0;
    final byColor = <int, List<double>>{};
    for (var i = 0; i < dotColors.length; i++) {
      if (hiddenLayers.contains(dotLayers[i])) continue;
      final sx = ax * dotCoords[i * 2] + bx;
      final sy = ay * dotCoords[i * 2 + 1] + by;
      if (sx < 0 || sx > viewW || sy < 0 || sy > viewH) continue;
      (byColor[dotColors[i]] ??= <double>[])
        ..add(sx)
        ..add(sy);
    }
    byColor.forEach((color, pts) {
      dotPaint.color = dwgEntityColor(color, AppColors.accentPrimary,
          monochrome: monochrome, backgroundIsWhite: backgroundIsWhite);
      canvas.drawRawPoints(
          ui.PointMode.points, Float32List.fromList(pts), dotPaint);
    });
  }

  if (fast) return;

  for (final text in scene.texts) {
    if (hiddenLayers.contains(text.layer)) continue;
    final rawSize = text.height * ax;
    if (rawSize < 3) continue;
    final offset = mapPoint(text.x, text.y);
    if (offset.dx < -200 ||
        offset.dx > size.width + 200 ||
        offset.dy < -200 ||
        offset.dy > size.height + 200) {
      continue;
    }
    if (text.value.trim().isEmpty) continue;
    final fontSize = rawSize.clamp(3.0, 4000.0);
    final textColor = dwgEntityColor(text.color, AppColors.accentGlow,
            monochrome: monochrome, backgroundIsWhite: backgroundIsWhite)
        .withValues(alpha: 0.90);
    final painter = TextPainter(
      text: TextSpan(
        text: text.value,
        style: TextStyle(
          color: textColor,
          fontSize: fontSize,
          fontWeight: FontWeight.w400,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: double.maxFinite);

    final halign = text.anchor & 0x0F;
    final valign = (text.anchor >> 4) & 0x0F;
    final tw = painter.width;
    final th = painter.height;
    final baseline =
        painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    final adx = halign == 1 ? -tw / 2 : (halign == 2 ? -tw : 0.0);
    final ady = switch (valign) {
      1 => -th,
      2 => -th / 2,
      3 => 0.0,
      _ => -baseline,
    };

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    if (text.rotation != 0) canvas.rotate(-text.rotation);
    painter.paint(canvas, Offset(adx, ady));
    canvas.restore();
  }
}

/// Builds the model→pixel transform that fits model-space [region]
/// (minX/minY/maxX/maxY, Y-up) into a [pxW]×[pxH] image, centred, preserving
/// aspect (contain-fit). Y is flipped so model-top maps to image-top.
_ViewTransform _transformForRegion(DwgBounds region, int pxW, int pxH) {
  final rw = region.width;
  final rh = region.height;
  final scale = math.min(pxW / rw, pxH / rh);
  final offX = (pxW - rw * scale) / 2;
  final offY = (pxH - rh * scale) / 2;
  final ax = scale;
  final bx = offX - region.minX * scale;
  final ay = -scale;
  final by = offY + region.maxY * scale;
  return _ViewTransform(ax, bx, ay, by);
}

/// Renders model-space [region] of [scene] to a PNG of [pxW]×[pxH] pixels,
/// honouring layer visibility and the background/monochrome settings. Used by
/// the export pipeline; the visual result matches the on-screen viewport.
Future<Uint8List> renderDwgRegionToPng({
  required DwgScene scene,
  required DwgBounds region,
  required int pxW,
  required int pxH,
  required Set<int> hiddenLayers,
  required bool monochrome,
  required bool backgroundIsWhite,
}) async {
  final recorder = ui.PictureRecorder();
  final bounds = Rect.fromLTWH(0, 0, pxW.toDouble(), pxH.toDouble());
  final canvas = Canvas(recorder, bounds);
  canvas.drawRect(
    bounds,
    Paint()
      ..color = backgroundIsWhite ? const Color(0xFFFFFFFF) : const Color(0xFF000000),
  );
  final transform = _transformForRegion(region, pxW, pxH);
  // Stroke scaled to the output resolution so hairlines stay visible on a large
  // export instead of vanishing the way a sub-pixel device stroke would.
  final strokeWidth = math.max(1.0, pxW / 1600.0);
  _paintDwgScene(
    canvas,
    Size(pxW.toDouble(), pxH.toDouble()),
    scene,
    transform,
    hiddenLayers: hiddenLayers,
    monochrome: monochrome,
    backgroundIsWhite: backgroundIsWhite,
    strokeWidth: strokeWidth,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(pxW, pxH);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  return data!.buffer.asUint8List();
}

/// What the measure tool computes.
/// - [distance]: two points → straight length.
/// - [angle]: three points → angle at the middle (vertex) point.
/// - [area]: a polygon (3+ points) → area + perimeter.
enum MeasureType { distance, angle, area }

/// Free-hand draw tools (annotation geometry, no measurement readout).
enum DrawTool { polyline, rectangle, circle, arc }

/// Internal kind of an on-canvas shape — the union of measure types and draw
/// tools. Measure kinds carry a readout/label; draw kinds are plain geometry.
enum _Kind { distance, angle, area, polyline, rectangle, circle, arc }

_Kind _kindOfMeasure(MeasureType t) => switch (t) {
      MeasureType.distance => _Kind.distance,
      MeasureType.angle => _Kind.angle,
      MeasureType.area => _Kind.area,
    };

_Kind _kindOfDraw(DrawTool t) => switch (t) {
      DrawTool.polyline => _Kind.polyline,
      DrawTool.rectangle => _Kind.rectangle,
      DrawTool.circle => _Kind.circle,
      DrawTool.arc => _Kind.arc,
    };

/// Live measurement readout reported up to the viewer. All values are in raw
/// model (drawing) units; area is in units².
class MeasureResult {
  const MeasureResult({
    required this.type,
    required this.points,
    this.distance,
    this.area,
    this.perimeter,
    this.angleDeg,
  });

  final MeasureType type;
  final int points;
  final double? distance; // straight length, or chain total for continuous
  final double? area;
  final double? perimeter;
  final double? angleDeg;
}

/// One on-canvas measurement. Multiple of these persist so a new measurement
/// never wipes earlier ones. [kinds] holds the snap kind per point (-1 = free).
class _Measurement {
  _Measurement(this.kind, this.pts, this.kinds);
  final _Kind kind;
  final List<Offset> pts;
  final List<int> kinds;
  bool finalized = false;

  bool get isMeasure =>
      kind == _Kind.distance || kind == _Kind.angle || kind == _Kind.area;

  // Points are model (world) coords, so they round-trip across sessions.
  Map<String, dynamic> toJson() => {
        'k': kind.index,
        'f': finalized,
        'p': [for (final o in pts) o.dx, for (final o in pts) o.dy],
        's': kinds,
      };

  static _Measurement? fromJson(Map<String, dynamic> j) {
    final ki = j['k'];
    if (ki is! int || ki < 0 || ki >= _Kind.values.length) return null;
    final flat = (j['p'] as List?) ?? const [];
    final n = flat.length ~/ 2;
    if (n == 0) return null;
    final pts = <Offset>[];
    for (var i = 0; i < n; i++) {
      pts.add(Offset((flat[i] as num).toDouble(), (flat[n + i] as num).toDouble()));
    }
    final kinds = [for (final e in (j['s'] as List? ?? const [])) (e as num).toInt()];
    while (kinds.length < pts.length) {
      kinds.add(-1);
    }
    final m = _Measurement(_Kind.values[ki], pts, kinds)
      ..finalized = j['f'] as bool? ?? true;
    return m;
  }
}

/// Model→screen affine: screen = (ax·x + bx, ay·y + by). [ay] is negative
/// because model Y points up while screen Y points down.
class _ViewTransform {
  const _ViewTransform(this.ax, this.bx, this.ay, this.by);

  final double ax;
  final double bx;
  final double ay;
  final double by;

  Offset toScreen(double x, double y) => Offset(ax * x + bx, ay * y + by);

  Offset toModel(Offset screen) =>
      Offset((screen.dx - bx) / ax, (screen.dy - by) / ay);
}

/// Single source of truth for the pan/zoom transform, shared by the painter
/// (drawing) and the canvas state (mapping taps back to model space).
_ViewTransform _computeTransform(
  Size size,
  DwgBounds bounds,
  double viewScale,
  Offset viewOffset,
) {
  const padding = 18.0;
  final drawWidth = size.width - padding * 2;
  final drawHeight = size.height - padding * 2;
  final scale = (drawWidth / bounds.width < drawHeight / bounds.height)
      ? drawWidth / bounds.width
      : drawHeight / bounds.height;

  final scaledW = bounds.width * scale;
  final scaledH = bounds.height * scale;
  final originX = padding + (drawWidth - scaledW) / 2;
  final originY = size.height - padding - (drawHeight - scaledH) / 2;
  final cx = size.width / 2;
  final cy = size.height / 2;
  final ax = viewScale * scale;
  final bx = viewScale * (originX - bounds.minX * scale) +
      cx * (1 - viewScale) +
      viewOffset.dx;
  final ay = -viewScale * scale;
  final by = viewScale * (originY + bounds.minY * scale) +
      cy * (1 - viewScale) +
      viewOffset.dy;
  return _ViewTransform(ax, bx, ay, by);
}

/// A snapped position plus what kind of geometry it locked onto, so the overlay
/// can show the right marker. 0 = endpoint, 1 = midpoint, 2 = on-edge,
/// 3 = intersection of two edges; -1/none = free.
class _SnapHit {
  const _SnapHit(this.point, this.kind);
  final Offset point;
  final int kind;
  static const int endpoint = 0;
  static const int midpoint = 1;
  static const int edge = 2;
  static const int intersection = 3;
}

/// Spatial grid over the drawing's line segments (circle centres are stored as
/// zero-length segments). Lets the measure tool snap to the nearest endpoint,
/// segment midpoint, or point along an edge without scanning all geometry each
/// frame. Built once, lazily, the first time the measure tool is used.
class _SnapIndex {
  _SnapIndex._(this._cell, this._minX, this._minY, this._seg, this._cells);

  final double _cell;
  final double _minX;
  final double _minY;
  final Float32List _seg; // [x1,y1,x2,y2] per segment
  final Map<int, List<int>> _cells; // cellKey → segment indices

  static int _key(int cx, int cy) => (cx + 100000) * 1000000 + (cy + 100000);

  /// Builds the index in slices, yielding to the event loop every ~30k
  /// segments so a multi-million-segment drawing doesn't freeze the UI the
  /// moment Measure/Draw is opened (this build used to run synchronously and
  /// blocked the thread for hundreds of ms on big files).
  static Future<_SnapIndex> build(DwgScene scene) async {
    const sliceSize = 30000;
    var sinceYield = 0;
    Future<void> maybeYield() async {
      if (++sinceYield >= sliceSize) {
        sinceYield = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }

    final b = scene.drawableBounds;
    final span = b.width > b.height ? b.width : b.height;
    final cell = span <= 0 ? 1.0 : span / 400.0;
    final minX = b.minX, minY = b.minY;
    final seg = <double>[];
    final cells = <int, List<int>>{};

    void add(double x1, double y1, double x2, double y2) {
      if (!x1.isFinite || !y1.isFinite || !x2.isFinite || !y2.isFinite) return;
      final idx = seg.length ~/ 4;
      seg
        ..add(x1)
        ..add(y1)
        ..add(x2)
        ..add(y2);
      // Register the segment in every grid cell it crosses, so even a long edge
      // is found when the cursor is anywhere along it. Step ≈ one cell so no
      // cell is skipped (a low cap made long axis/dimension lines miss most of
      // their cells → the cursor's cell didn't list them → no intersection).
      // The grid is 400 cells/side so a full-diagonal line needs ~565 steps;
      // 2048 leaves margin while keeping pathological cases bounded.
      final dx = x2 - x1, dy = y2 - y1;
      final len = math.sqrt(dx * dx + dy * dy);
      final steps = len <= 0 ? 0 : math.min(2048, (len / cell).ceil());
      var lastKey = 1 << 62;
      for (var s = 0; s <= steps; s++) {
        final t = steps == 0 ? 0.0 : s / steps;
        final cx = ((x1 + dx * t - minX) / cell).floor();
        final cy = ((y1 + dy * t - minY) / cell).floor();
        final key = _key(cx, cy);
        if (key != lastKey) {
          (cells[key] ??= <int>[]).add(idx);
          lastKey = key;
        }
      }
    }

    for (final m in scene.lineBatches.values) {
      for (var i = 0; i + 3 < m.length; i += 4) {
        add(m[i], m[i + 1], m[i + 2], m[i + 3]);
        await maybeYield();
      }
    }
    final cc = scene.circleCoords;
    for (var i = 0; i < scene.circleCount; i++) {
      add(cc[i * 3], cc[i * 3 + 1], cc[i * 3], cc[i * 3 + 1]); // centre point
      await maybeYield();
    }
    return _SnapIndex._(cell, minX, minY, Float32List.fromList(seg), cells);
  }

  /// Best snap within [radius] model units of (x,y): an intersection of two
  /// edges wins, then endpoints, then midpoints, then on-edge points; ties
  /// break by distance.
  _SnapHit? nearest(double x, double y, double radius) {
    // Widen by one cell each side: when the snap radius is much smaller than a
    // grid cell the window collapses to a single cell, so a crossing right at a
    // cell boundary could miss one of its two lines. ±1 guarantees both are in.
    var c0x = ((x - radius - _minX) / _cell).floor() - 1;
    var c1x = ((x + radius - _minX) / _cell).floor() + 1;
    var c0y = ((y - radius - _minY) / _cell).floor() - 1;
    var c1y = ((y + radius - _minY) / _cell).floor() + 1;
    final ccx = ((x - _minX) / _cell).floor();
    final ccy = ((y - _minY) / _cell).floor();
    if (c1x - c0x > 16) { c0x = ccx - 8; c1x = ccx + 8; }
    if (c1y - c0y > 16) { c0y = ccy - 8; c1y = ccy + 8; }
    final r2 = radius * radius;
    // Per-kind best dist²: 0 end, 1 mid, 2 edge, 3 intersection.
    final best = <double>[r2, r2, r2, r2];
    final bx = <double>[0, 0, 0, 0];
    final by = <double>[0, 0, 0, 0];
    final found = <bool>[false, false, false, false];
    final seen = <int>{};
    final nb = <int>[]; // segment indices gathered in the search window

    void consider(int kind, double px, double py) {
      final dx = px - x, dy = py - y;
      final d2 = dx * dx + dy * dy;
      if (d2 < best[kind]) {
        best[kind] = d2;
        bx[kind] = px;
        by[kind] = py;
        found[kind] = true;
      }
    }

    // Cap the work per query: in a dense drawing zoomed out, the search window
    // can cover tens of thousands of segments, stalling a per-frame drag. We
    // scan cells CENTRE-OUT (concentric rings) and stop after a budget, so the
    // budget is always spent on the closest geometry first — capping in raw
    // row-major order could exhaust it on far corner cells and miss the nearest
    // snap entirely (which dropped snapping completely when zoomed out).
    var visited = 0;
    var budgetLeft = true;
    void processCell(int cx, int cy) {
      final list = _cells[_key(cx, cy)];
      if (list == null) return;
      for (final si in list) {
        if (!seen.add(si)) continue;
        if (++visited > 6000) {
          budgetLeft = false;
          return;
        }
        final ax = _seg[si * 4], ay = _seg[si * 4 + 1];
        final bx2 = _seg[si * 4 + 2], by2 = _seg[si * 4 + 3];
        consider(_SnapHit.endpoint, ax, ay);
        consider(_SnapHit.endpoint, bx2, by2);
        final ex = bx2 - ax, ey = by2 - ay;
        final elen2 = ex * ex + ey * ey;
        if (elen2 > 1e-9) {
          consider(_SnapHit.midpoint, (ax + bx2) * 0.5, (ay + by2) * 0.5);
          var tc = ((x - ax) * ex + (y - ay) * ey) / elen2;
          if (tc < 0) tc = 0;
          if (tc > 1) tc = 1;
          final fx = ax + ex * tc, fy = ay + ey * tc;
          final ddx = fx - x, ddy = fy - y;
          if (ddx * ddx + ddy * ddy <= r2) nb.add(si);
          if (tc > 0.02 && tc < 0.98) {
            consider(_SnapHit.edge, fx, fy);
          }
        }
      }
    }

    final maxRing = math.max(
      math.max(ccx - c0x, c1x - ccx),
      math.max(ccy - c0y, c1y - ccy),
    );
    for (var ring = 0; ring <= maxRing && budgetLeft; ring++) {
      for (var cx = ccx - ring; cx <= ccx + ring && budgetLeft; cx++) {
        if (cx < c0x || cx > c1x) continue;
        for (var cy = ccy - ring; cy <= ccy + ring && budgetLeft; cy++) {
          if (cy < c0y || cy > c1y) continue;
          // Only the cells on this ring's boundary (skip the already-scanned
          // interior).
          if (ring > 0 &&
              cx != ccx - ring &&
              cx != ccx + ring &&
              cy != ccy - ring &&
              cy != ccy + ring) {
            continue;
          }
          processCell(cx, cy);
        }
      }
    }

    // Apparent intersections: cross every near-cursor candidate against every
    // other and keep crossings inside both segments and within the snap radius.
    // Highest priority so corners where two lines meet snap cleanly even if no
    // vertex sits exactly there. nb already holds only lines passing within the
    // radius, so this stays a handful of pairs; cap is just a safety net.
    final cap = nb.length > 64 ? 64 : nb.length;
    for (var i = 0; i < cap; i++) {
      final a = nb[i];
      final ax = _seg[a * 4], ay = _seg[a * 4 + 1];
      final r1x = _seg[a * 4 + 2] - ax, r1y = _seg[a * 4 + 3] - ay;
      if (r1x * r1x + r1y * r1y < 1e-9) continue; // point (circle centre)
      for (var j = i + 1; j < cap; j++) {
        final c = nb[j];
        final cx2 = _seg[c * 4], cy2 = _seg[c * 4 + 1];
        final r2x = _seg[c * 4 + 2] - cx2, r2y = _seg[c * 4 + 3] - cy2;
        if (r2x * r2x + r2y * r2y < 1e-9) continue;
        final denom = r1x * r2y - r1y * r2x;
        if (denom.abs() < 1e-12) continue; // parallel / collinear
        final dpx = cx2 - ax, dpy = cy2 - ay;
        final tt = (dpx * r2y - dpy * r2x) / denom;
        final uu = (dpx * r1y - dpy * r1x) / denom;
        if (tt < -0.002 || tt > 1.002 || uu < -0.002 || uu > 1.002) continue;
        consider(_SnapHit.intersection, ax + r1x * tt, ay + r1y * tt);
      }
    }

    // Priority: intersection, then endpoint, midpoint, on-edge.
    const order = [_SnapHit.intersection, _SnapHit.endpoint, _SnapHit.midpoint, _SnapHit.edge];
    for (final k in order) {
      if (found[k]) return _SnapHit(Offset(bx[k], by[k]), k);
    }
    return null;
  }
}

/// A photo pinned to a model-space point, for drawing the marker and hit-testing
/// taps. Kept lightweight (no image data) — the viewer owns the full records.
class PhotoMarker {
  const PhotoMarker(this.id, this.point);
  final String id;
  final Offset point; // model coords
}

class DwgViewport extends StatelessWidget {
  const DwgViewport({
    super.key,
    this.showOverview = true,
    this.title = 'SITE PLAN / A-102',
    this.scene,
    this.hiddenLayers = const {},
    this.measureMode = false,
    this.measureType = MeasureType.distance,
    this.drawMode = false,
    this.drawTool = DrawTool.polyline,
    this.measureClearToken = 0,
    this.measureUndoToken = 0,
    this.armed = false,
    this.onShapeCompleted,
    this.onMeasureResult,
    this.monochrome = false,
    this.backgroundIsWhite = false,
    this.commentColor = const Color(0xFFFFB300),
    this.unit = 'u',
    this.insUnits = 0,
    this.showLineWeights = true,
    this.focusTarget,
    this.focusSpan = 0,
    this.focusToken = 0,
    this.fitToken = 0,
    this.initialAnnotations,
    this.onAnnotationsChanged,
    this.exportSelectMode = false,
    this.onExportRectSelected,
    this.onVisibleBoundsChanged,
    this.photos = const [],
    this.photoMode = false,
    this.onPhotoPlace,
    this.onPhotoTap,
  });

  final bool showOverview;
  final String title;
  final DwgScene? scene;

  /// Photos pinned to model points: drawn as markers and tappable to open.
  final List<PhotoMarker> photos;

  /// When true, a tap on empty space drops a new photo pin (via [onPhotoPlace]).
  final bool photoMode;

  /// Called with the model-space point where a new photo should be placed.
  final ValueChanged<Offset>? onPhotoPlace;

  /// Called with a photo id when its marker is tapped (to open/delete it).
  final ValueChanged<String>? onPhotoTap;

  /// Whether the active sub-tool captures taps. When false (panel still open
  /// but no sub-tool armed) a tap SELECTS an existing shape instead of drawing,
  /// so it can be deleted.
  final bool armed;

  /// Called when the user finishes one shape/measurement so the tool can turn
  /// itself off (press the tool again to draw another).
  final VoidCallback? onShapeCompleted;

  /// When true, dragging draws an export-selection rectangle (instead of
  /// panning); the chosen model-space region is reported via
  /// [onExportRectSelected].
  final bool exportSelectMode;

  /// Reports the model-space region the user boxed in export-select mode.
  final ValueChanged<DwgBounds>? onExportRectSelected;

  /// Reports the currently visible model-space region whenever pan/zoom changes
  /// (used to export exactly what's on screen). Called off the build phase; the
  /// listener should just store the value, not call setState.
  final ValueChanged<DwgBounds>? onVisibleBoundsChanged;

  /// Drawing color = Black/White (force monochrome geometry).
  final bool monochrome;

  /// Background black (false) vs white (true).
  final bool backgroundIsWhite;

  /// Measure/draw overlay colour.
  final Color commentColor;

  /// Unit suffix for measurement labels (u / mm / cm / m).
  final String unit;

  /// Effective base unit ($INSUNITS code) used to convert raw lengths.
  final int insUnits;

  /// Whether per-layer lineweights are drawn (toggleable in Settings).
  final bool showLineWeights;

  /// Search "zoom to": bump [focusToken] to centre [focusTarget] (model coords)
  /// so [focusSpan] model units fit the view, with a flashing marker.
  final Offset? focusTarget;
  final double focusSpan;
  final int focusToken;

  /// Bump to animate the view to zoom-extents (fit the whole drawing).
  final int fitToken;

  /// Persisted annotations (JSON) restored on open + a change callback to save.
  final String? initialAnnotations;
  final ValueChanged<String>? onAnnotationsChanged;

  /// Indices into [DwgScene.layers] that are currently toggled off.
  final Set<int> hiddenLayers;

  /// When true, taps place measurement points instead of being ignored.
  final bool measureMode;

  /// Distance / angle / area measurement.
  final MeasureType measureType;

  /// When true, taps place draw-shape points.
  final bool drawMode;

  /// Polyline / rectangle / circle / arc.
  final DrawTool drawTool;

  /// Bumping this value clears all measurements (wired to a button).
  final int measureClearToken;

  /// Bumping this value removes the last placed point (undo button).
  final int measureUndoToken;

  /// Reports the current measurement, or null when there is nothing to show.
  final ValueChanged<MeasureResult?>? onMeasureResult;

  @override
  Widget build(BuildContext context) {
    final isNativeScene = scene != null;

    return ClipRRect(
      borderRadius: BorderRadius.circular(isNativeScene ? 0 : 20),
      child: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: isNativeScene
                  ? (backgroundIsWhite ? const Color(0xFFFFFFFF) : const Color(0xFF000000))
                  : AppColors.bgMain,
              child: scene == null
                  ? BlueprintBackground(
                      child: CustomPaint(painter: _LineworkPainter()),
                    )
                  : _InteractiveDwgCanvas(
                      scene: scene!,
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
                      monochrome: monochrome,
                      backgroundIsWhite: backgroundIsWhite,
                      commentColor: commentColor,
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
                      photos: photos,
                      photoMode: photoMode,
                      onPhotoPlace: onPhotoPlace,
                      onPhotoTap: onPhotoTap,
                    ),
              ),
            ),
          Positioned(
            left: 16,
            top: 14,
            child: scene == null
                ? TechnicalChip(label: title, icon: Icons.architecture_outlined)
                : const SizedBox.shrink(),
          ),
          if (showOverview)
            Positioned(
              right: 14,
              top: 14,
              width: 92,
              height: 86,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.bgDeep.withValues(alpha: 0.84),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.border),
                ),
                child: CustomPaint(painter: _MiniMapPainter()),
              ),
            ),
          if (!isNativeScene)
            Positioned(
              left: 28,
              right: 28,
              bottom: 24,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 170) {
                    return const SizedBox.shrink();
                  }

                  return Row(
                    children: [
                      Expanded(
                        child: Container(height: 1, color: AppColors.accentSecondary),
                      ),
                      const SizedBox(width: 10),
                      const TechnicalChip(label: '12.40 m', icon: Icons.straighten),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Container(height: 1, color: AppColors.accentSecondary),
                      ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _InteractiveDwgCanvas extends StatefulWidget {
  const _InteractiveDwgCanvas({
    required this.scene,
    this.hiddenLayers = const {},
    this.measureMode = false,
    this.measureType = MeasureType.distance,
    this.drawMode = false,
    this.drawTool = DrawTool.polyline,
    this.measureClearToken = 0,
    this.measureUndoToken = 0,
    this.armed = false,
    this.onShapeCompleted,
    this.onMeasureResult,
    this.monochrome = false,
    this.backgroundIsWhite = false,
    this.commentColor = const Color(0xFFFFB300),
    this.unit = 'u',
    this.insUnits = 0,
    this.showLineWeights = true,
    this.focusTarget,
    this.focusSpan = 0,
    this.focusToken = 0,
    this.fitToken = 0,
    this.initialAnnotations,
    this.onAnnotationsChanged,
    this.exportSelectMode = false,
    this.onExportRectSelected,
    this.onVisibleBoundsChanged,
    this.photos = const [],
    this.photoMode = false,
    this.onPhotoPlace,
    this.onPhotoTap,
  });

  final List<PhotoMarker> photos;
  final bool photoMode;
  final ValueChanged<Offset>? onPhotoPlace;
  final ValueChanged<String>? onPhotoTap;

  final DwgScene scene;
  final Set<int> hiddenLayers;
  final bool measureMode;
  final MeasureType measureType;
  final bool armed;
  final VoidCallback? onShapeCompleted;
  final bool drawMode;
  final DrawTool drawTool;
  final int measureClearToken;
  final int measureUndoToken;
  final ValueChanged<MeasureResult?>? onMeasureResult;
  final bool monochrome;
  final bool backgroundIsWhite;
  final Color commentColor;
  final String unit;
  final int insUnits;
  final bool showLineWeights;
  // Search "zoom to": when [focusToken] changes, smoothly centre [focusTarget]
  // (model coords) so [focusSpan] model units fit the view, and flash a marker.
  final Offset? focusTarget;
  final double focusSpan;
  final int focusToken;
  // Bump to animate the view back to zoom-extents (fit the whole drawing).
  final int fitToken;
  // Persisted annotations: a JSON string of saved shapes loaded once on open,
  // and a callback fired (debounced to post-frame) whenever they change.
  final String? initialAnnotations;
  final ValueChanged<String>? onAnnotationsChanged;
  final bool exportSelectMode;
  final ValueChanged<DwgBounds>? onExportRectSelected;
  final ValueChanged<DwgBounds>? onVisibleBoundsChanged;

  @override
  State<_InteractiveDwgCanvas> createState() => _InteractiveDwgCanvasState();
}

class _InteractiveDwgCanvasState extends State<_InteractiveDwgCanvas>
    with SingleTickerProviderStateMixin {
  // Zoom from screen-center: screen = (fitted - center) * viewScale + center + viewOffset
  double _scale = 1.0;
  Offset _offset = Offset.zero;

  // "Zoom to search result" animation: lerps _scale/_offset to a target.
  AnimationController? _focusCtl;
  double _focusFromScale = 1, _focusToScale = 1;
  Offset _focusFromOffset = Offset.zero, _focusToOffset = Offset.zero;
  // A flashing marker at the focused model point (cleared after the flash).
  Offset? _focusHighlight;
  int _focusFlash = 0; // 0..1000 opacity driver during the focus animation

  double _gestureStartScale = 1;
  Offset _gestureStartOffset = Offset.zero;
  Offset _gestureFocal = Offset.zero;

  // Canvas size, tracked during layout.
  double _canvasW = 0;
  double _canvasH = 0;

  // While a gesture is in flight we draw a lighter frame (no anti-aliasing, no
  // text, coarser culling) for fluidity, then a full crisp frame once it ends.
  bool _interacting = false;

  // Persisted measurements (each its own line / polygon). A new measurement is
  // appended instead of wiping the previous, so taking a second measurement
  // never throws away the first. The last entry is the one being built.
  final List<_Measurement> _measurements = [];
  int _measureRevision = 0; // bumped on any change so the painter repaints
  _ViewTransform? _transform;

  // Snap-to-geometry support. Index built lazily on first measure use.
  _SnapIndex? _snapIndex;
  bool _snapIndexBuilding = false;

  // ── Gesture-time raster reuse ──
  // Painting the full scene live during a pan/zoom costs a per-frame walk over
  // every segment; fully zoomed out that's the whole drawing and frames blow
  // past 16ms. Instead, after each settled full-quality frame the scene layer
  // is snapshotted to an image; DURING a gesture the painter just transforms
  // that snapshot (one drawImageRect) and the real geometry is repainted once
  // when the finger lifts.
  final GlobalKey _sceneKey = GlobalKey();
  ui.Image? _frozen;
  double _frozenScale = 1.0;
  Offset _frozenOffset = Offset.zero;
  Size _frozenSize = Size.zero;
  int _frozenParams = 0; // appearance key the snapshot was taken under
  bool _capturing = false;

  int _appearanceKey() => Object.hash(
        identityHashCode(widget.scene),
        Object.hashAllUnordered(widget.hiddenLayers),
        widget.monochrome,
        widget.backgroundIsWhite,
        widget.showLineWeights,
      );

  /// Snapshot the settled scene layer (post-frame; no-op while interacting or
  /// when the current view already matches the stored snapshot).
  void _scheduleFreeze() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _interacting || _capturing) return;
      final params = _appearanceKey();
      if (_frozen != null &&
          _frozenScale == _scale &&
          _frozenOffset == _offset &&
          _frozenSize == Size(_canvasW, _canvasH) &&
          _frozenParams == params) {
        return;
      }
      final ro = _sceneKey.currentContext?.findRenderObject();
      if (ro is! RenderRepaintBoundary) return;
      _capturing = true;
      // Remember the view the snapshot belongs to BEFORE the async gap.
      final snapScale = _scale;
      final snapOffset = _offset;
      final snapSize = Size(_canvasW, _canvasH);
      try {
        final img = await ro.toImage(
            pixelRatio: MediaQuery.of(context).devicePixelRatio);
        if (!mounted) {
          img.dispose();
          return;
        }
        _frozen?.dispose();
        _frozen = img;
        _frozenScale = snapScale;
        _frozenOffset = snapOffset;
        _frozenSize = snapSize;
        _frozenParams = params;
      } catch (_) {
        // Capture is best-effort; gestures just fall back to live painting.
      } finally {
        _capturing = false;
      }
    });
  }
  // Tight bounds of the drawing's main content, for the fit button (cached).
  DwgBounds? _fitBounds;
  int _dragMeas = -1; // measurement being dragged
  int _dragPt = -1; // its point index
  (int, int) _dragCandidate = (-1, -1); // point the finger landed on (maybe drag)
  int _selectedShape = -1; // long-pressed shape showing a delete button
  static const double _snapPx = 22.0; // snap radius in screen pixels
  static const double _grabPx = 30.0; // how close a drag must start to a point
  static const double _dragSlop = 6.0; // movement before a grab becomes a drag
  static const double _dragLift = 68.0; // lift the point above the finger

  // Export-select rectangle (screen coords) while the user drags a box.
  Offset? _exportStart;
  Offset? _exportCurrent;
  // Last reported visible model bounds, to avoid redundant callbacks.
  DwgBounds? _lastVisible;

  // Magnifier loupe: while dragging a measure/draw point, show a zoomed circle
  // of the area under the (lifted) point so the user can place it precisely.
  Offset? _loupeModel; // model-space focus the loupe is centred on
  int _loupeKind = -1; // snap kind at that point (for the marker)
  double _loupeFingerX = 0; // finger x, to flip the loupe to the opposite side

  Map<int, Float32List> get _lineBatches => widget.scene.lineBatches;

  _Measurement? get _active => _measurements.isEmpty ? null : _measurements.last;

  bool _annotationsLoaded = false;

  @override
  void initState() {
    super.initState();
    _focusCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..addListener(_onFocusTick);
    _loadAnnotations(widget.initialAnnotations);
    // Build the zoomed-out LOD copies off the first frame (chunked async) so
    // pan/zoom at extents iterates thousands of pre-chained chords instead of
    // millions of raw segments.
    ensureSceneLod(widget.scene);
    // First settled frame → first gesture snapshot.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleFreeze();
    });
  }

  // Saved shapes are restored once (model coords, so they line up after reopen).
  void _loadAnnotations(String? json) {
    if (_annotationsLoaded) return;
    _annotationsLoaded = true;
    if (json == null || json.trim().isEmpty) return;
    try {
      final list = jsonDecode(json) as List;
      for (final e in list) {
        final m = _Measurement.fromJson(e as Map<String, dynamic>);
        if (m != null) _measurements.add(m);
      }
      _measureRevision++;
    } catch (_) {
      // Corrupt/old saved data — ignore, start clean.
    }
  }

  // Push the current finalized shapes up to be saved (post-frame so we never
  // call the parent's setState mid-build).
  void _persistAnnotations() {
    final cb = widget.onAnnotationsChanged;
    if (cb == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final list = [
        for (final m in _measurements)
          if (m.finalized) m.toJson(),
      ];
      cb(jsonEncode(list));
    });
  }

  @override
  void dispose() {
    _focusCtl?.dispose();
    _frozen?.dispose();
    super.dispose();
  }

  void _onFocusTick() {
    final c = _focusCtl;
    if (c == null) return;
    final e = Curves.easeInOutCubic.transform(c.value);
    setState(() {
      _scale = _focusFromScale + (_focusToScale - _focusFromScale) * e;
      _offset = Offset.lerp(_focusFromOffset, _focusToOffset, e)!;
      // Marker flashes in over the first half, then fades out.
      _focusFlash = ((c.value < 0.5 ? c.value / 0.5 : 1 - (c.value - 0.5) / 0.5) *
              1000)
          .round();
      if (c.isCompleted) {
        _focusFlash = 0;
        _focusHighlight = null;
      }
    });
    // Focus/restore animation finished → the next frame is full quality;
    // snapshot it for the next gesture.
    if (c.isCompleted) _scheduleFreeze();
  }

  // Smoothly centre [m] (model coords) so [span] model units fit the view.
  void _startFocus(Offset m, double span) {
    if (_canvasW <= 0 || _canvasH <= 0) return;
    final bounds = widget.scene.drawableBounds;
    const padding = 18.0;
    final drawW = _canvasW - padding * 2, drawH = _canvasH - padding * 2;
    final baseScale = (drawW / bounds.width < drawH / bounds.height)
        ? drawW / bounds.width
        : drawH / bounds.height;
    final originX = padding + (drawW - bounds.width * baseScale) / 2;
    final originY = _canvasH - padding - (drawH - bounds.height * baseScale) / 2;
    final cx = _canvasW / 2, cy = _canvasH / 2;

    // Pick a zoom so ~[span] model units of height fill the view (fallback to a
    // sensible window when the text height is unknown), clamped to gesture caps.
    final wantSpan = span > 0 ? span : bounds.height / 12;
    var vs = _canvasH / (baseScale * wantSpan);
    vs = vs.clamp(0.02, 200000.0).toDouble();

    // Offset that lands model point m at the canvas centre for this zoom.
    final ox = vs * (cx - baseScale * m.dx - originX + bounds.minX * baseScale);
    final oy = vs * (cy + baseScale * m.dy - originY - bounds.minY * baseScale);

    _animateView(vs, Offset(ox, oy), m);
  }

  // Frames model-box [b] tightly in the view (centred, filling it minus a small
  // margin) by animating scale + offset there.
  void _fitToBounds(DwgBounds b) {
    if (_canvasW <= 0 || _canvasH <= 0) return;
    final db = widget.scene.drawableBounds;
    const padding = 18.0;
    final drawW = _canvasW - padding * 2, drawH = _canvasH - padding * 2;
    if (drawW <= 0 || drawH <= 0 || b.width <= 0 || b.height <= 0) return;
    final baseScale = (drawW / db.width < drawH / db.height)
        ? drawW / db.width
        : drawH / db.height;
    final targetScale = (drawW / b.width < drawH / b.height)
        ? drawW / b.width
        : drawH / b.height;
    final vs = (targetScale / baseScale).clamp(0.02, 200000.0).toDouble();
    final originX = padding + (drawW - db.width * baseScale) / 2;
    final originY = _canvasH - padding - (drawH - db.height * baseScale) / 2;
    final cx = _canvasW / 2, cy = _canvasH / 2;
    final mx = (b.minX + b.maxX) / 2, my = (b.minY + b.maxY) / 2;
    final ox = vs * (cx - baseScale * mx - originX + db.minX * baseScale);
    final oy = vs * (cy + baseScale * my - originY - db.minY * baseScale);
    _animateView(vs, Offset(ox, oy), null);
  }

  // Tight bounds of the drawing's MAIN cluster: bins all geometry into a grid
  // and keeps the cells holding a meaningful share (≥2% of the densest), so a
  // detached far sub-plan doesn't keep the main plan tiny. Falls back to the
  // full drawable bounds for ordinary single-view drawings.
  DwgBounds _computeFitBounds() {
    final scene = widget.scene;
    final db = scene.drawableBounds;
    final fw = db.width, fh = db.height;
    if (fw <= 0 || fh <= 0) return db;
    const grid = 120;
    final counts = Int32List(grid * grid);
    var maxC = 0, total = 0;
    void bin(double x, double y) {
      if (!x.isFinite || !y.isFinite) return;
      var gx = ((x - db.minX) / fw * (grid - 1)).floor();
      var gy = ((y - db.minY) / fh * (grid - 1)).floor();
      gx = gx < 0 ? 0 : (gx >= grid ? grid - 1 : gx);
      gy = gy < 0 ? 0 : (gy >= grid ? grid - 1 : gy);
      final c = ++counts[gy * grid + gx];
      if (c > maxC) maxC = c;
      total++;
    }

    scene.lineBatches.forEach((_, m) {
      for (var i = 0; i + 1 < m.length; i += 2) {
        bin(m[i], m[i + 1]);
      }
    });
    final cc = scene.circleCoords;
    for (var i = 0; i < scene.circleCount; i++) {
      bin(cc[i * 3], cc[i * 3 + 1]);
    }
    for (final t in scene.texts) {
      bin(t.x, t.y);
    }
    if (total < 200 || maxC == 0) return db;

    final thr = maxC * 0.02;
    var gx0 = grid, gy0 = grid, gx1 = -1, gy1 = -1;
    for (var gy = 0; gy < grid; gy++) {
      for (var gx = 0; gx < grid; gx++) {
        if (counts[gy * grid + gx] < thr) continue;
        if (gx < gx0) gx0 = gx;
        if (gx > gx1) gx1 = gx;
        if (gy < gy0) gy0 = gy;
        if (gy > gy1) gy1 = gy;
      }
    }
    if (gx1 < gx0 || gy1 < gy0) return db;
    final cw = fw / grid, ch = fh / grid;
    final pad = 0.5; // half-cell margin
    return DwgBounds(
      minX: db.minX + (gx0 - pad) * cw,
      minY: db.minY + (gy0 - pad) * ch,
      maxX: db.minX + (gx1 + 1 + pad) * cw,
      maxY: db.minY + (gy1 + 1 + pad) * ch,
    );
  }

  // Animates the view (scale + offset) to a target; optional [highlight] flashes
  // a marker at a model point. Shared by search "zoom to" and the fit button.
  void _animateView(double toScale, Offset toOffset, Offset? highlight) {
    _focusFromScale = _scale;
    _focusToScale = toScale;
    _focusFromOffset = _offset;
    _focusToOffset = toOffset;
    _focusHighlight = highlight;
    _focusCtl
      ?..reset()
      ..forward();
  }

  @override
  void didUpdateWidget(_InteractiveDwgCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Saved annotations may arrive after first build (loaded async); take them
    // the first time they're non-null.
    if (!_annotationsLoaded && widget.initialAnnotations != null) {
      _loadAnnotations(widget.initialAnnotations);
    }
    if (widget.focusToken != oldWidget.focusToken && widget.focusTarget != null) {
      // Defer to post-frame so _canvasW/_canvasH are valid even on first focus.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startFocus(widget.focusTarget!, widget.focusSpan);
      });
    }
    if (widget.fitToken != oldWidget.fitToken) {
      // Zoom-to-extents: frame the drawing's MAIN content tightly (so it fills
      // the screen) instead of the raw extents — a multi-plan sheet's full
      // bounds would just reproduce the small opening view.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fitToBounds(_fitBounds ??= _computeFitBounds());
      });
    }
    // Build the snap index ahead of the first tap (off the gesture path) so the
    // first measurement/draw doesn't hitch on a big drawing.
    final enteredTool = (!oldWidget.measureMode && widget.measureMode) ||
        (!oldWidget.drawMode && widget.drawMode);
    if (enteredTool) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureSnapIndex();
      });
    }
    // NB: these run during the parent's build, so we mutate state directly (the
    // following build() picks it up) and defer the parent callback to post-frame
    // — calling onMeasureResult here would be "setState during build". Items
    // persist when leaving a tool; only an explicit Clear/Undo removes them.
    final cleared = oldWidget.measureClearToken != widget.measureClearToken;
    final undo = oldWidget.measureUndoToken != widget.measureUndoToken;
    if (cleared) {
      // Scoped clear: wipe only the active category (measure vs draw) so
      // measuring doesn't erase your drawings and vice-versa.
      final removeMeasure = widget.measureMode;
      final before = _measurements.length;
      _measurements.removeWhere((m) => m.isMeasure == removeMeasure);
      if (_measurements.length != before) _measureRevision++;
      _dragMeas = -1;
      _dragPt = -1;
      _selectedShape = -1;
      _reportAfterFrame();
      _persistAnnotations();
    } else if (undo) {
      _selectedShape = -1;
      final m = _active;
      if (m != null) {
        m.finalized = false;
        if (m.pts.isNotEmpty) {
          m.pts.removeLast();
          m.kinds.removeLast();
        }
        if (m.pts.isEmpty) _measurements.removeLast();
        _measureRevision++;
        _reportAfterFrame();
        _persistAnnotations();
      }
    }
    if (!identical(oldWidget.scene, widget.scene)) {
      _snapIndex = null;
      _fitBounds = null;
      _frozen?.dispose();
      _frozen = null;
      ensureSceneLod(widget.scene);
    }
    // Appearance changed (layer toggled, colours, lineweights) or a new scene
    // arrived: the next full-quality frame differs — re-snapshot it.
    if (!identical(oldWidget.scene, widget.scene) ||
        !setEquals(oldWidget.hiddenLayers, widget.hiddenLayers) ||
        oldWidget.monochrome != widget.monochrome ||
        oldWidget.backgroundIsWhite != widget.backgroundIsWhite ||
        oldWidget.showLineWeights != widget.showLineWeights) {
      _scheduleFreeze();
    }
  }

  void _reportAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reportMeasurement();
    });
  }

  /// Kicks off the chunked snap-index build once; concurrent calls no-op.
  void _ensureSnapIndex() {
    if (_snapIndex != null || _snapIndexBuilding) return;
    _snapIndexBuilding = true;
    final scene = widget.scene;
    _SnapIndex.build(scene).then((idx) {
      _snapIndexBuilding = false;
      // The scene may have been swapped while building — only keep a match.
      if (mounted && identical(widget.scene, scene)) _snapIndex = idx;
    });
  }

  // Snaps a screen position to the nearest endpoint / midpoint / edge.
  // While the index is still building (first second on a huge drawing) the
  // raw tap point is used — no freeze, snapping kicks in as soon as it's ready.
  ({Offset point, int kind}) _snap(Offset screenPos) {
    final t = _transform;
    if (t == null) return (point: Offset.zero, kind: -1);
    final model = t.toModel(screenPos);
    final idx = _snapIndex;
    if (idx == null) {
      _ensureSnapIndex();
      return (point: model, kind: -1);
    }
    final hit = idx.nearest(model.dx, model.dy, _snapPx / t.ax.abs());
    if (hit == null) return (point: model, kind: -1);
    return (point: hit.point, kind: hit.kind);
  }

  // (measurement, point) within [_grabPx] of a screen position, or (-1,-1).
  (int, int) _pointNear(Offset screenPos) {
    final t = _transform;
    if (t == null) return (-1, -1);
    var bestD2 = _grabPx * _grabPx;
    var bm = -1, bp = -1;
    for (var mi = 0; mi < _measurements.length; mi++) {
      final pts = _measurements[mi].pts;
      for (var pi = 0; pi < pts.length; pi++) {
        final sp = t.toScreen(pts[pi].dx, pts[pi].dy);
        final d2 = (sp - screenPos).distanceSquared;
        if (d2 <= bestD2) {
          bestD2 = d2;
          bm = mi;
          bp = pi;
        }
      }
    }
    return (bm, bp);
  }

  // The shape kind for whichever tool is active (measure or draw), or null.
  _Kind? get _activeKind {
    if (!widget.armed) return null; // sub-tool not armed → taps select, not draw
    if (widget.measureMode) return _kindOfMeasure(widget.measureType);
    if (widget.drawMode) return _kindOfDraw(widget.drawTool);
    return null;
  }

  bool get _toolActive => widget.measureMode || widget.drawMode;

  void _reportMeasurement() {
    final m = _active;
    if (m == null || !m.isMeasure) {
      widget.onMeasureResult?.call(null);
      return;
    }
    final pts = m.pts;
    if (m.kind == _Kind.distance) {
      widget.onMeasureResult?.call(MeasureResult(
        type: MeasureType.distance,
        points: pts.length,
        distance: pts.length >= 2 ? (pts[1] - pts[0]).distance : null,
      ));
      return;
    }
    if (m.kind == _Kind.angle) {
      double? deg;
      if (pts.length >= 3) {
        final v = pts[1]; // vertex is the middle point
        final a = pts[0] - v, b = pts[2] - v;
        final la = a.distance, lb = b.distance;
        if (la > 1e-9 && lb > 1e-9) {
          final cos = ((a.dx * b.dx + a.dy * b.dy) / (la * lb)).clamp(-1.0, 1.0);
          deg = math.acos(cos) * 180.0 / math.pi;
        }
      }
      widget.onMeasureResult?.call(MeasureResult(
        type: MeasureType.angle,
        points: pts.length,
        angleDeg: deg,
      ));
      return;
    }
    // Area
    double? perimeter, area;
    if (pts.length >= 2) {
      var p = 0.0;
      for (var i = 0; i + 1 < pts.length; i++) {
        p += (pts[i + 1] - pts[i]).distance;
      }
      if (pts.length >= 3) p += (pts.first - pts.last).distance; // closing edge
      perimeter = p;
    }
    if (pts.length >= 3) {
      var a = 0.0;
      for (var i = 0; i < pts.length; i++) {
        final c = pts[i], n = pts[(i + 1) % pts.length];
        a += c.dx * n.dy - n.dx * c.dy;
      }
      area = a.abs() / 2;
    }
    widget.onMeasureResult?.call(MeasureResult(
      type: MeasureType.area,
      points: pts.length,
      area: area,
      perimeter: perimeter,
    ));
  }

  static double _distToSeg(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 < 1e-9) return (p - a).distance;
    var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2;
    t = t.clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  // The shape whose geometry is closest to a screen position (within 32px).
  int _shapeNear(Offset pos) {
    final t = _transform;
    if (t == null) return -1;
    var best = -1;
    var bestD = 32.0;
    for (var mi = 0; mi < _measurements.length; mi++) {
      final m = _measurements[mi];
      final sp = [for (final p in m.pts) t.toScreen(p.dx, p.dy)];
      if (sp.isEmpty) continue;
      var d = double.infinity;
      if (sp.length == 1) {
        d = (sp[0] - pos).distance;
      } else {
        for (var i = 0; i + 1 < sp.length; i++) {
          d = math.min(d, _distToSeg(pos, sp[i], sp[i + 1]));
        }
        if (m.kind == _Kind.area && sp.length >= 3) {
          d = math.min(d, _distToSeg(pos, sp.last, sp.first));
        }
      }
      if (d < bestD) {
        bestD = d;
        best = mi;
      }
    }
    return best;
  }

  // Long-press selects the shape under the finger and shows a delete button.
  void _selectShapeNear(Offset pos) {
    final idx = _shapeNear(pos);
    setState(() {
      _selectedShape = idx;
      _measureRevision++;
    });
  }

  // Screen position of the delete button for the selected shape (above it).
  Offset? _deleteButtonCenter() {
    final t = _transform;
    if (t == null || _selectedShape < 0 || _selectedShape >= _measurements.length) {
      return null;
    }
    final pts = _measurements[_selectedShape].pts;
    if (pts.isEmpty) return null;
    // Anchor to the topmost point so the button clears the shape.
    var top = t.toScreen(pts.first.dx, pts.first.dy);
    for (final p in pts) {
      final s = t.toScreen(p.dx, p.dy);
      if (s.dy < top.dy) top = s;
    }
    return top + const Offset(0, -34);
  }

  void _deleteSelectedShape() {
    if (_selectedShape < 0 || _selectedShape >= _measurements.length) return;
    setState(() {
      _measurements.removeAt(_selectedShape);
      _selectedShape = -1;
      _measureRevision++;
    });
    _reportMeasurement();
    _persistAnnotations();
  }

  // Id of a photo marker within tap range of a screen point, or null.
  String? _photoNear(Offset pos) {
    final t = _transform;
    if (t == null || widget.photos.isEmpty) return null;
    var bestD2 = 28.0 * 28.0;
    String? id;
    for (final ph in widget.photos) {
      final sp = t.toScreen(ph.point.dx, ph.point.dy);
      final d2 = (sp - pos).distanceSquared;
      if (d2 <= bestD2) {
        bestD2 = d2;
        id = ph.id;
      }
    }
    return id;
  }

  void _handleCanvasTap(Offset pos) {
    // When a shape is selected, a tap either hits its delete button (remove just
    // that shape) or lands elsewhere (deselect) — it never places a new point.
    if (_selectedShape != -1) {
      final btn = _deleteButtonCenter();
      if (btn != null && (pos - btn).distance <= 26) {
        _deleteSelectedShape();
      } else {
        setState(() {
          _selectedShape = -1;
          _measureRevision++;
        });
      }
      return;
    }
    // Photo mode: EVERY tap drops a new pin (so you can add many in a row).
    // Pin viewing is handled below only when not placing.
    if (widget.photoMode) {
      final t = _transform;
      if (t != null) widget.onPhotoPlace?.call(t.toModel(pos));
      return;
    }
    // Otherwise a tap on a photo marker opens it (when no sub-tool is armed).
    if (!widget.armed) {
      final pid = _photoNear(pos);
      if (pid != null) {
        widget.onPhotoTap?.call(pid);
        return;
      }
    }
    _handleMeasureTap(pos);
  }

  void _handleMeasureTap(Offset pos) {
    if (_transform == null) return;
    final kind = _activeKind;
    if (kind == null) {
      // No sub-tool armed → a tap selects the nearest shape (so it can be
      // deleted via its ✕ button). Tapping empty space deselects.
      final idx = _shapeNear(pos);
      setState(() {
        _selectedShape = idx;
        _measureRevision++;
      });
      return;
    }
    final s = _snap(pos);
    var completed = false; // shape finished this tap → turn the tool off
    setState(() {
      final act = _active;
      // Fixed-point shapes complete at their cap; area/polyline complete when
      // the user closes/finishes them.
      final cap = switch (kind) {
        _Kind.distance => 2,
        _Kind.angle => 3,
        _Kind.rectangle => 2,
        _Kind.circle => 2,
        _Kind.arc => 3,
        _ => 0, // area / polyline: unbounded
      };
      final sameOpen = act != null && act.kind == kind && !act.finalized;
      if (cap > 0) {
        if (act == null || !sameOpen || act.pts.length >= cap) {
          _measurements.add(_Measurement(kind, [s.point], [s.kind]));
        } else {
          act.pts.add(s.point);
          act.kinds.add(s.kind);
        }
        final a2 = _active;
        if (a2 != null && a2.pts.length >= cap) {
          a2.finalized = true;
          completed = true; // last point placed → done
        }
      } else if (kind == _Kind.area) {
        if (act == null || !sameOpen) {
          _measurements.add(_Measurement(kind, [s.point], [s.kind]));
        } else {
          // Close by tapping near the FIRST point (connects last → first).
          final firstScreen =
              _transform!.toScreen(act.pts.first.dx, act.pts.first.dy);
          if (act.pts.length >= 3 && (firstScreen - pos).distance < _grabPx * 1.6) {
            act.finalized = true;
            completed = true;
          } else {
            act.pts.add(s.point);
            act.kinds.add(s.kind);
          }
        }
      } else {
        // Polyline: tap points; tap near the LAST point again to finish.
        if (act == null || !sameOpen) {
          _measurements.add(_Measurement(kind, [s.point], [s.kind]));
        } else {
          final lastScreen =
              _transform!.toScreen(act.pts.last.dx, act.pts.last.dy);
          if (act.pts.length >= 2 && (lastScreen - pos).distance < _grabPx * 1.6) {
            act.finalized = true;
            completed = true;
          } else {
            act.pts.add(s.point);
            act.kinds.add(s.kind);
          }
        }
      }
      _measureRevision++;
    });
    _reportMeasurement();
    // One shape finished → tell the viewer to turn the tool off (press it again
    // to draw/measure another). Deferred so it runs after this frame's setState.
    if (completed && widget.onShapeCompleted != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onShapeCompleted!();
      });
    }
    if (completed) _persistAnnotations(); // a shape just finalized → save it
  }

  // The model-space region currently filling the canvas (for "export visible").
  DwgBounds? _visibleBounds() {
    final t = _transform;
    if (t == null || _canvasW <= 0 || _canvasH <= 0) return null;
    final a = t.toModel(Offset.zero);
    final b = t.toModel(Offset(_canvasW, _canvasH));
    return DwgBounds(
      minX: math.min(a.dx, b.dx),
      minY: math.min(a.dy, b.dy),
      maxX: math.max(a.dx, b.dx),
      maxY: math.max(a.dy, b.dy),
    );
  }

  // Reports the visible region up (off the build phase) when it has changed.
  void _maybeReportVisible() {
    if (widget.onVisibleBoundsChanged == null) return;
    final vb = _visibleBounds();
    if (vb == null) return;
    final last = _lastVisible;
    if (last != null &&
        last.minX == vb.minX &&
        last.minY == vb.minY &&
        last.maxX == vb.maxX &&
        last.maxY == vb.maxY) {
      return;
    }
    _lastVisible = vb;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onVisibleBoundsChanged!(vb);
    });
  }

  @override
  Widget build(BuildContext context) {
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        _canvasW = constraints.maxWidth;
        _canvasH = constraints.maxHeight;
        _transform = _computeTransform(
          Size(_canvasW, _canvasH),
          widget.scene.drawableBounds,
          _scale,
          _offset,
        );
        _maybeReportVisible();

        // Scale bar: pick a round real-world length whose on-screen width is
        // ~90 px, so the user always has a sense of real size at any zoom.
        double? scalePx;
        String? scaleLabel;
        final st = _transform;
        if (st != null) {
          final pxPerModel = st.ax.abs();
          final factor = dwgUnitFactor(widget.unit, widget.insUnits);
          if (pxPerModel.isFinite && pxPerModel > 0 && factor > 0) {
            final targetDisplay = 90.0 * factor / pxPerModel;
            if (targetDisplay.isFinite && targetDisplay > 0) {
              final nice = _niceScaleLength(targetDisplay);
              final px = nice / factor * pxPerModel;
              if (px.isFinite && px > 10 && px < 420) {
                scalePx = px;
                final u = widget.unit == 'u' ? 'u' : widget.unit;
                final n = nice >= 1 ? nice.toStringAsFixed(0) : nice.toStringAsFixed(2);
                scaleLabel = '$n $u';
              }
            }
          }
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Selecting/deleting a shape works even when no tool is active (panel
          // closed): a tap or long-press picks the nearest shape so its ✕ can
          // delete it. Only export-rectangle mode owns taps exclusively.
          onLongPressStart: widget.exportSelectMode
              ? null
              : (details) => _selectShapeNear(details.localPosition),
          onTapUp: widget.exportSelectMode
              ? null
              : (details) => _handleCanvasTap(details.localPosition),
          onDoubleTap: () {
            setState(() {
              if (_scale < 8.0) {
                _scale *= 2.5;
              } else if (_scale < 80.0) {
                _scale *= 2.0;
              } else {
                _scale = 1.0;
                _offset = Offset.zero;
              }
            });
            _scheduleFreeze();
          },
          onScaleStart: (details) {
            if (widget.exportSelectMode) {
              setState(() {
                _exportStart = details.localFocalPoint;
                _exportCurrent = details.localFocalPoint;
              });
              return;
            }
            // Remember which point the finger landed on, but don't move it yet:
            // a stationary tap must still place a NEW point (via onTapUp). Only
            // once the finger actually moves does it become a drag.
            _dragMeas = -1;
            _dragPt = -1;
            _dragCandidate = (_toolActive && details.pointerCount == 1)
                ? _pointNear(details.localFocalPoint)
                : (-1, -1);
            _gestureStartScale = _scale;
            _gestureStartOffset = _offset;
            _gestureFocal = details.localFocalPoint;
            if (!_interacting) setState(() => _interacting = true);
          },
          onScaleUpdate: (details) {
            if (widget.exportSelectMode) {
              setState(() => _exportCurrent = details.localFocalPoint);
              return;
            }
            final focal = details.localFocalPoint;
            // Promote a grabbed point to an active drag once it clears the slop.
            if (_dragMeas == -1 &&
                _dragCandidate.$1 != -1 &&
                (focal - _gestureFocal).distance > _dragSlop) {
              _dragMeas = _dragCandidate.$1;
              _dragPt = _dragCandidate.$2;
            }
            if (_dragMeas != -1) {
              setState(() {
                // Lift the controlled point above the fingertip so the finger
                // never hides where it lands (a crosshair marks the exact spot).
                final s = _snap(focal.translate(0, -_dragLift));
                _measurements[_dragMeas].pts[_dragPt] = s.point;
                _measurements[_dragMeas].kinds[_dragPt] = s.kind;
                // Feed the magnifier loupe so the user sees a zoomed view of
                // exactly where the point is snapping.
                _loupeModel = s.point;
                _loupeKind = s.kind;
                _loupeFingerX = focal.dx;
                _measureRevision++;
              });
              _reportMeasurement();
              return;
            }
            // Finger rests on a point but hasn't moved enough yet → don't pan.
            if (_dragCandidate.$1 != -1) return;
            setState(() {
              final cx = _canvasW / 2;
              final cy = _canvasH / 2;
              final nextScale =
                  (_gestureStartScale * details.scale).clamp(0.02, 200000.0).toDouble();
              // Keep the focal point fixed on screen while scaling + panning.
              final ratio = nextScale / _gestureStartScale;
              _scale = nextScale;
              _offset = Offset(
                details.localFocalPoint.dx -
                    cx -
                    (_gestureFocal.dx - cx - _gestureStartOffset.dx) * ratio,
                details.localFocalPoint.dy -
                    cy -
                    (_gestureFocal.dy - cy - _gestureStartOffset.dy) * ratio,
              );
            });
          },
          onScaleEnd: (_) {
            if (widget.exportSelectMode) {
              final s = _exportStart;
              final c = _exportCurrent;
              final t = _transform;
              setState(() {
                _exportStart = null;
                _exportCurrent = null;
              });
              if (s != null && c != null && t != null && (s - c).distance > 12) {
                final m0 = t.toModel(s);
                final m1 = t.toModel(c);
                widget.onExportRectSelected?.call(DwgBounds(
                  minX: math.min(m0.dx, m1.dx),
                  minY: math.min(m0.dy, m1.dy),
                  maxX: math.max(m0.dx, m1.dx),
                  maxY: math.max(m0.dy, m1.dy),
                ));
              }
              return;
            }
            final wasDragging = _dragMeas != -1;
            _dragMeas = -1;
            _dragPt = -1;
            _dragCandidate = (-1, -1);
            _loupeModel = null; // hide the magnifier when the drag ends
            if (_interacting) setState(() => _interacting = false);
            // The settled full-quality frame paints now; snapshot it for the
            // next gesture. (Captures are event-driven — gesture end, focus
            // end, view/appearance change — never per-build, so the GPU isn't
            // saturated with readbacks.)
            _scheduleFreeze();
            if (wasDragging) _persistAnnotations(); // a point was moved → save
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Bottom layer: the (heavy) static drawing. Its own RepaintBoundary
              // so moving a measurement point does NOT repaint the >1M-segment
              // geometry — only the light overlay above redraws.
              RepaintBoundary(
                key: _sceneKey,
                child: CustomPaint(
                  isComplex: true,
                  painter: _DwgScenePainter(
                    scene: widget.scene,
                    lineBatches: _lineBatches,
                    hiddenLayers: widget.hiddenLayers,
                    devicePixelRatio: devicePixelRatio,
                    viewScale: _scale,
                    viewOffset: _offset,
                    // Gestures AND the focus/restore animation ride the
                    // snapshot; full quality returns on the settled frame.
                    fast: _interacting || (_focusCtl?.isAnimating ?? false),
                    monochrome: widget.monochrome,
                    backgroundIsWhite: widget.backgroundIsWhite,
                    showLineWeights: widget.showLineWeights,
                    // Snapshot reuse only when it matches the current look and
                    // canvas — otherwise the painter falls back to live paint.
                    frozen: (_frozen != null &&
                            _frozenParams == _appearanceKey() &&
                            _frozenSize == Size(_canvasW, _canvasH))
                        ? _frozen
                        : null,
                    frozenScale: _frozenScale,
                    frozenOffset: _frozenOffset,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
              // Top layer: measurements / draw shapes / search marker.
              RepaintBoundary(
                child: CustomPaint(
                  painter: _MeasureOverlayPainter(
                    scene: widget.scene,
                    viewScale: _scale,
                    viewOffset: _offset,
                    measurements: _measurements,
                    measureRevision: _measureRevision,
                    dragMeas: _dragMeas,
                    dragPt: _dragPt,
                    selectedShape: _selectedShape,
                    commentColor: widget.commentColor,
                    unit: widget.unit,
                    insUnits: widget.insUnits,
                    focusHighlight: _focusHighlight,
                    focusFlash: _focusFlash,
                    photoPoints: [for (final ph in widget.photos) ph.point],
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
              if (widget.exportSelectMode &&
                  _exportStart != null &&
                  _exportCurrent != null)
                Positioned.fromRect(
                  rect: Rect.fromPoints(_exportStart!, _exportCurrent!),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.accentPrimary.withValues(alpha: 0.12),
                      border: Border.all(color: AppColors.accentPrimary, width: 1.5),
                    ),
                  ),
                ),
              // Scale bar (bottom-left, clear of the fit button on the right).
              if (scalePx != null && scaleLabel != null)
                Positioned(
                  left: 14,
                  bottom: 96,
                  child: IgnorePointer(
                    child: _ScaleBar(pxLength: scalePx, label: scaleLabel),
                  ),
                ),
              // Magnifier loupe while dragging a point. Sits below the floating
              // top bar (which would otherwise cover it) and flips to the side
              // opposite the finger.
              if (_loupeModel != null && _transform != null)
                Positioned(
                  top: 118,
                  left: _loupeFingerX > _canvasW / 2 ? 14 : null,
                  right: _loupeFingerX > _canvasW / 2 ? null : 14,
                  child: IgnorePointer(
                    child: ClipOval(
                      child: SizedBox(
                        width: 132,
                        height: 132,
                        child: CustomPaint(
                          painter: _LoupePainter(
                            scene: widget.scene,
                            hiddenLayers: widget.hiddenLayers,
                            focusModel: _loupeModel!,
                            baseAx: _transform!.ax,
                            monochrome: widget.monochrome,
                            backgroundIsWhite: widget.backgroundIsWhite,
                            commentColor: widget.commentColor,
                            snapKind: _loupeKind,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A round real-world scale length and its on-screen width, drawn as a labelled
/// bar with end ticks (CAD-style). Width is given in logical pixels.
class _ScaleBar extends StatelessWidget {
  const _ScaleBar({required this.pxLength, required this.label});

  final double pxLength;
  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.bgDeep.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 5, 8, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            CustomPaint(
              size: Size(pxLength, 7),
              painter: _ScaleBarTickPainter(),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScaleBarTickPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = AppColors.accentPrimary
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.square;
    final y = size.height - 1;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), p); // base line
    canvas.drawLine(const Offset(0, 0), Offset(0, y), p); // left tick
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, y), p); // right tick
    canvas.drawLine(Offset(size.width / 2, y - 3), Offset(size.width / 2, y), p);
  }

  @override
  bool shouldRepaint(covariant _ScaleBarTickPainter oldDelegate) => false;
}

/// Magnifier: draws the scene zoomed around [focusModel] (the snapped point)
/// with a crosshair + snap marker, so the user can place a point precisely even
/// though the fingertip covers it.
class _LoupePainter extends CustomPainter {
  _LoupePainter({
    required this.scene,
    required this.hiddenLayers,
    required this.focusModel,
    required this.baseAx,
    required this.monochrome,
    required this.backgroundIsWhite,
    required this.commentColor,
    required this.snapKind,
  });

  final DwgScene scene;
  final Set<int> hiddenLayers;
  final Offset focusModel;
  final double baseAx;
  final bool monochrome;
  final bool backgroundIsWhite;
  final Color commentColor;
  final int snapKind;

  static const double _zoom = 2.6;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final ax = baseAx.abs() * _zoom;
    if (!ax.isFinite || ax <= 0) return;
    final ay = -ax;
    final t = _ViewTransform(
      ax,
      c.dx - ax * focusModel.dx,
      ay,
      c.dy - ay * focusModel.dy,
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = backgroundIsWhite ? const Color(0xFFFFFFFF) : const Color(0xFF000000),
    );
    _paintDwgScene(
      canvas,
      size,
      scene,
      t,
      hiddenLayers: hiddenLayers,
      monochrome: monochrome,
      backgroundIsWhite: backgroundIsWhite,
      strokeWidth: 1.3,
      showLineWeights: false,
    );
    // Crosshair at the centre (where the point will land).
    final cross = Paint()
      ..color = commentColor.withValues(alpha: 0.9)
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(c.dx - 12, c.dy), Offset(c.dx + 12, c.dy), cross);
    canvas.drawLine(Offset(c.dx, c.dy - 12), Offset(c.dx, c.dy + 12), cross);
    // Snap marker (matches the overlay's markers): only when actually snapped.
    if (snapKind >= 0) {
      final mk = Paint()
        ..color = commentColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6;
      canvas.drawCircle(c, 6, mk);
    }
    // Rim.
    canvas.drawCircle(
      c,
      size.width / 2 - 1,
      Paint()
        ..color = AppColors.accentPrimary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _LoupePainter old) =>
      old.focusModel != focusModel ||
      old.snapKind != snapKind ||
      old.baseAx != baseAx ||
      old.hiddenLayers != hiddenLayers;
}

/// Rounds a length up/down to a "nice" 1/2/5×10ⁿ value for the scale bar.
double _niceScaleLength(double x) {
  final exp = (math.log(x) / math.ln10).floor();
  final p = math.pow(10, exp).toDouble();
  final f = x / p;
  final nf = f < 1.5
      ? 1.0
      : f < 3.5
          ? 2.0
          : f < 7.5
              ? 5.0
              : 10.0;
  return nf * p;
}

class _LineworkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = AppColors.accentPrimary.withValues(alpha: 0.72)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final muted = Paint()
      ..color = AppColors.accentSecondary.withValues(alpha: 0.36)
      ..strokeWidth = 0.9
      ..style = PaintingStyle.stroke;

    final rect = Rect.fromLTWH(
      size.width * 0.12,
      size.height * 0.22,
      size.width * 0.58,
      size.height * 0.46,
    );
    canvas.drawRect(rect, line);
    canvas.drawLine(rect.topLeft, rect.bottomRight, muted);
    canvas.drawLine(rect.topRight, rect.bottomLeft, muted);
    canvas.drawRect(rect.deflate(28), muted);
    canvas.drawCircle(rect.center, rect.shortestSide * 0.16, muted);

    final path = Path()
      ..moveTo(size.width * 0.18, size.height * 0.78)
      ..lineTo(size.width * 0.44, size.height * 0.72)
      ..lineTo(size.width * 0.74, size.height * 0.82)
      ..lineTo(size.width * 0.88, size.height * 0.62);
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _MiniMapPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.accentSecondary.withValues(alpha: 0.65)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawRect(Offset.zero & size, paint);
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.18, size.height * 0.22, size.width * 0.54, size.height * 0.42),
      paint,
    );
    canvas.drawCircle(Offset(size.width * 0.70, size.height * 0.70), 9, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _DwgScenePainter extends CustomPainter {
  const _DwgScenePainter({
    required this.scene,
    required this.lineBatches,
    required this.hiddenLayers,
    required this.devicePixelRatio,
    required this.viewScale,
    required this.viewOffset,
    this.fast = false,
    this.monochrome = false,
    this.backgroundIsWhite = false,
    this.showLineWeights = true,
    this.frozen,
    this.frozenScale = 1.0,
    this.frozenOffset = Offset.zero,
  });

  final DwgScene scene;
  final Map<int, Float32List> lineBatches;
  final Set<int> hiddenLayers;
  final double devicePixelRatio;
  final double viewScale;
  final Offset viewOffset;
  // True during an active gesture: trade quality for a lighter, smoother frame.
  final bool fast;
  // Snapshot of the last settled frame + the view it was rendered at. During a
  // gesture the painter transforms this image (one draw op) instead of walking
  // millions of segments — zoomed-out pans stay at 60fps on huge drawings.
  final ui.Image? frozen;
  final double frozenScale;
  final Offset frozenOffset;
  // Drawing-color = Black/White: force all geometry to one contrasting colour.
  final bool monochrome;
  // Background is white (vs black) — flips entity-colour adjustments.
  final bool backgroundIsWhite;
  // Whether per-layer lineweights are rendered (vs. a uniform hairline).
  final bool showLineWeights;

  @override
  void paint(Canvas canvas, Size size) {
    // Gesture frames: reproject the settled snapshot instead of live geometry.
    final img = frozen;
    if (fast && img != null) {
      final t2 =
          _computeTransform(size, scene.drawableBounds, viewScale, viewOffset);
      final t1 = _computeTransform(
          size, scene.drawableBounds, frozenScale, frozenOffset);
      if (t1.ax != 0) {
        final k = t2.ax / t1.ax;
        final dx = t2.bx - k * t1.bx;
        final dy = t2.by - k * t1.by;
        canvas.drawImageRect(
          img,
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          Rect.fromLTWH(dx, dy, size.width * k, size.height * k),
          Paint()..filterQuality = FilterQuality.low,
        );
        return;
      }
    }
    // Model → screen affine, fitted to the current pan/zoom.
    final transform =
        _computeTransform(size, scene.drawableBounds, viewScale, viewOffset);
    // Geometry + text (shared with the export renderer so both look identical).
    _paintDwgScene(
      canvas,
      size,
      scene,
      transform,
      hiddenLayers: hiddenLayers,
      monochrome: monochrome,
      backgroundIsWhite: backgroundIsWhite,
      strokeWidth: 0.65 / devicePixelRatio,
      showLineWeights: showLineWeights,
      fast: fast,
    );
  }

  @override
  bool shouldRepaint(covariant _DwgScenePainter oldDelegate) {
    return oldDelegate.scene != scene ||
        !identical(oldDelegate.lineBatches, lineBatches) ||
        !setEquals(oldDelegate.hiddenLayers, hiddenLayers) ||
        oldDelegate.devicePixelRatio != devicePixelRatio ||
        oldDelegate.viewScale != viewScale ||
        oldDelegate.viewOffset != viewOffset ||
        oldDelegate.fast != fast ||
        oldDelegate.monochrome != monochrome ||
        oldDelegate.backgroundIsWhite != backgroundIsWhite ||
        oldDelegate.showLineWeights != showLineWeights ||
        !identical(oldDelegate.frozen, frozen) ||
        oldDelegate.frozenScale != frozenScale ||
        oldDelegate.frozenOffset != frozenOffset;
  }
}

/// Light overlay layer: measurements, draw shapes, snap markers, the selected-
/// shape delete button, and the search "zoom to" flash. Lives in its own
/// RepaintBoundary so dragging a point never repaints the heavy geometry.
class _MeasureOverlayPainter extends CustomPainter {
  const _MeasureOverlayPainter({
    required this.scene,
    required this.viewScale,
    required this.viewOffset,
    required this.measurements,
    required this.measureRevision,
    required this.dragMeas,
    required this.dragPt,
    required this.selectedShape,
    required this.commentColor,
    required this.unit,
    required this.insUnits,
    required this.focusHighlight,
    required this.focusFlash,
    required this.photoPoints,
  });

  final DwgScene scene;
  final double viewScale;
  final Offset viewOffset;
  final List<_Measurement> measurements;
  final int measureRevision;
  final int dragMeas;
  final int dragPt;
  final int selectedShape;
  final Color commentColor;
  final String unit;
  final int insUnits;
  final Offset? focusHighlight;
  final int focusFlash;
  final List<Offset> photoPoints; // model coords of pinned photos

  @override
  void paint(Canvas canvas, Size size) {
    final transform =
        _computeTransform(size, scene.drawableBounds, viewScale, viewOffset);
    if (measurements.isNotEmpty) {
      _paintMeasure(canvas, transform.toScreen, size);
    }
    if (photoPoints.isNotEmpty) {
      _paintPhotoPins(canvas, transform.toScreen, size);
    }
    // Flashing ring at a "zoom to search result" target.
    final fh = focusHighlight;
    if (fh != null && focusFlash > 0) {
      final o = transform.toScreen(fh.dx, fh.dy);
      final a = (focusFlash / 1000).clamp(0.0, 1.0);
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..isAntiAlias = true
        ..color = const Color(0xFFFFB300).withValues(alpha: a);
      canvas.drawCircle(o, 26, ring);
      canvas.drawCircle(
          o, 12, Paint()..color = const Color(0xFFFFB300).withValues(alpha: a * 0.35));
    }
  }

  // Draws a camera pin at each pinned photo's model point, numbered in order.
  void _paintPhotoPins(
      Canvas canvas, Offset Function(double, double) map, Size size) {
    final white = Paint()..color = Colors.white;
    for (var i = 0; i < photoPoints.length; i++) {
      final p = map(photoPoints[i].dx, photoPoints[i].dy);
      if (p.dx < -30 || p.dx > size.width + 30 || p.dy < -30 || p.dy > size.height + 30) {
        continue;
      }
      canvas.drawCircle(p + const Offset(0, 1), 13, Paint()..color = const Color(0x55000000));
      canvas.drawCircle(p, 13, Paint()..color = commentColor);
      canvas.drawCircle(
        p,
        13,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white,
      );
      // Camera glyph: body + viewfinder bump + lens.
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: p, width: 14, height: 9), const Radius.circular(2)),
        white,
      );
      canvas.drawRect(
          Rect.fromCenter(center: p + const Offset(0, -5.5), width: 5, height: 3), white);
      canvas.drawCircle(p, 2.6, Paint()..color = commentColor);
      // Index badge (top-right).
      final tp = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: const TextStyle(
              color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final badge = p + const Offset(11, -11);
      canvas.drawCircle(badge, 8, Paint()..color = const Color(0xFF15323F));
      canvas.drawCircle(
          badge, 8, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.2..color = Colors.white);
      tp.paint(canvas, badge - Offset(tp.width / 2, tp.height / 2));
    }
  }

  // Draws every persisted measurement: distance lines with a midpoint label,
  // and area polygons (translucent fill + perimeter) with a centroid label.
  // Snap markers reflect what each point locked onto (endpoint/midpoint/edge).
  void _paintMeasure(
      Canvas canvas, Offset Function(double, double) mapPoint, Size size) {
    final accent = commentColor;
    const snapColor = Color(0xFF31E0C8);
    final stroke = Paint()
      ..color = accent
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    final snapStroke = Paint()
      ..color = snapColor
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    void drawDashed(Offset a, Offset b) {
      final dir = b - a;
      final len = dir.distance;
      if (len <= 1e-3) return;
      final unit = dir / len;
      const dash = 8.0, gap = 5.0;
      var t = 0.0;
      while (t < len) {
        canvas.drawLine(a + unit * t, a + unit * (t + dash).clamp(0.0, len), stroke);
        t += dash + gap;
      }
    }

    void drawLabel(String text, Offset center) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(
            color: Color(0xFF1A1A1A),
            fontSize: 13,
            fontWeight: FontWeight.w700,
            height: 1.15,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout();
      final box =
          Rect.fromCenter(center: center, width: tp.width + 14, height: tp.height + 8);
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(6)),
        Paint()..color = accent,
      );
      tp.paint(canvas, box.topLeft + const Offset(7, 4));
    }

    // Marker shaped by snap kind: square = endpoint, triangle = midpoint,
    // X = on-edge, diamond = intersection, plain cross = free.
    void drawMarker(Offset o, int kind, bool dragging) {
      final p = (kind >= 0) ? snapStroke : stroke;
      const r = 6.0;
      canvas.drawLine(Offset(o.dx - r - 3, o.dy), Offset(o.dx + r + 3, o.dy), p);
      canvas.drawLine(Offset(o.dx, o.dy - r - 3), Offset(o.dx, o.dy + r + 3), p);
      const s = 7.0;
      if (kind == _SnapHit.endpoint) {
        canvas.drawRect(Rect.fromCenter(center: o, width: s * 2, height: s * 2), p);
      } else if (kind == _SnapHit.midpoint) {
        final path = Path()
          ..moveTo(o.dx, o.dy - s)
          ..lineTo(o.dx + s, o.dy + s)
          ..lineTo(o.dx - s, o.dy + s)
          ..close();
        canvas.drawPath(path, p);
      } else if (kind == _SnapHit.edge) {
        canvas.drawLine(Offset(o.dx - s, o.dy - s), Offset(o.dx + s, o.dy + s), p);
        canvas.drawLine(Offset(o.dx - s, o.dy + s), Offset(o.dx + s, o.dy - s), p);
      } else if (kind == _SnapHit.intersection) {
        final path = Path()
          ..moveTo(o.dx, o.dy - s)
          ..lineTo(o.dx + s, o.dy)
          ..lineTo(o.dx, o.dy + s)
          ..lineTo(o.dx - s, o.dy)
          ..close();
        canvas.drawPath(path, p);
      } else {
        canvas.drawCircle(o, r, p);
      }
      if (dragging) {
        canvas.drawCircle(o, r + 6, snapStroke);
      }
    }

    for (var mi = 0; mi < measurements.length; mi++) {
      final m = measurements[mi];
      final sp = m.pts.map((p) => mapPoint(p.dx, p.dy)).toList(growable: false);
      if (sp.isEmpty) continue;

      switch (m.kind) {
        case _Kind.area:
          if (sp.length >= 3) {
            final path = Path()..moveTo(sp[0].dx, sp[0].dy);
            for (var i = 1; i < sp.length; i++) {
              path.lineTo(sp[i].dx, sp[i].dy);
            }
            path.close();
            canvas.drawPath(path, Paint()..color = accent.withValues(alpha: 0.18));
          }
          for (var i = 0; i + 1 < sp.length; i++) {
            canvas.drawLine(sp[i], sp[i + 1], stroke);
          }
          if (sp.length >= 3) {
            drawDashed(sp.last, sp.first);
            var cx = 0.0, cy = 0.0;
            for (final p in sp) {
              cx += p.dx;
              cy += p.dy;
            }
            var a2 = 0.0;
            for (var i = 0; i < m.pts.length; i++) {
              final c = m.pts[i], n = m.pts[(i + 1) % m.pts.length];
              a2 += c.dx * n.dy - n.dx * c.dy;
            }
            final f = dwgUnitFactor(unit, insUnits);
            drawLabel('${_formatDistance(a2.abs() / 2 * f * f)} $unit²',
                Offset(cx / sp.length, cy / sp.length));
          }

        case _Kind.angle:
          for (var i = 0; i + 1 < sp.length; i++) {
            canvas.drawLine(sp[i], sp[i + 1], stroke);
          }
          if (sp.length >= 3) {
            final v = sp[1];
            final a0 = math.atan2(sp[0].dy - v.dy, sp[0].dx - v.dx);
            final a1 = math.atan2(sp[2].dy - v.dy, sp[2].dx - v.dx);
            var sweep = a1 - a0;
            while (sweep <= -math.pi) {
              sweep += 2 * math.pi;
            }
            while (sweep > math.pi) {
              sweep -= 2 * math.pi;
            }
            canvas.drawArc(Rect.fromCircle(center: v, radius: 26), a0, sweep, false, stroke);
            final mv = m.pts[1];
            final va = m.pts[0] - mv, vb = m.pts[2] - mv;
            final la = va.distance, lb = vb.distance;
            if (la > 1e-9 && lb > 1e-9) {
              final deg = math.acos(
                      ((va.dx * vb.dx + va.dy * vb.dy) / (la * lb)).clamp(-1.0, 1.0)) *
                  180.0 /
                  math.pi;
              final bis = a0 + sweep / 2;
              drawLabel('${deg.toStringAsFixed(1)}°',
                  v + Offset(math.cos(bis), math.sin(bis)) * 46);
            }
          }

        case _Kind.distance:
          if (sp.length >= 2) {
            drawDashed(sp[0], sp[1]);
            drawLabel(
                '${_formatDistance((m.pts[1] - m.pts[0]).distance * dwgUnitFactor(unit, insUnits))} $unit',
                (sp[0] + sp[1]) / 2);
          }

        // ── Draw tools: plain geometry, no measurement label ──
        case _Kind.polyline:
          for (var i = 0; i + 1 < sp.length; i++) {
            canvas.drawLine(sp[i], sp[i + 1], stroke);
          }

        case _Kind.rectangle:
          if (sp.length >= 2) {
            canvas.drawRect(Rect.fromPoints(sp[0], sp[1]), stroke);
          }

        case _Kind.circle:
          if (sp.length >= 2) {
            canvas.drawCircle(sp[0], (sp[1] - sp[0]).distance, stroke);
          }

        case _Kind.arc:
          if (sp.length >= 3) {
            _drawArc3(canvas, sp[0], sp[1], sp[2], stroke);
          } else {
            for (var i = 0; i + 1 < sp.length; i++) {
              canvas.drawLine(sp[i], sp[i + 1], stroke);
            }
          }
      }

      for (var pi = 0; pi < sp.length; pi++) {
        drawMarker(sp[pi], m.kinds[pi], mi == dragMeas && pi == dragPt);
      }
    }

    // Full-canvas crosshair through the point being dragged, so its exact
    // landing is visible even though the finger is held below it.
    if (dragMeas >= 0 &&
        dragMeas < measurements.length &&
        dragPt >= 0 &&
        dragPt < measurements[dragMeas].pts.length) {
      final p = measurements[dragMeas].pts[dragPt];
      final o = mapPoint(p.dx, p.dy);
      final cross = Paint()
        ..color = snapColor.withValues(alpha: 0.55)
        ..strokeWidth = 1.0
        ..isAntiAlias = true;
      canvas.drawLine(Offset(0, o.dy), Offset(size.width, o.dy), cross);
      canvas.drawLine(Offset(o.dx, 0), Offset(o.dx, size.height), cross);
    }

    // Selected shape: halo its points and draw a red ✕ delete button above it.
    if (selectedShape >= 0 && selectedShape < measurements.length) {
      final sp = [
        for (final p in measurements[selectedShape].pts) mapPoint(p.dx, p.dy)
      ];
      if (sp.isNotEmpty) {
        final halo = Paint()
          ..color = snapColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..isAntiAlias = true;
        for (final o in sp) {
          canvas.drawCircle(o, 9, halo);
        }
        var top = sp.first;
        for (final o in sp) {
          if (o.dy < top.dy) top = o;
        }
        final btn = top + const Offset(0, -34);
        canvas.drawCircle(btn, 16, Paint()..color = const Color(0xFFE53935));
        canvas.drawCircle(
            btn,
            16,
            Paint()
              ..color = const Color(0xFFFFFFFF)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
        final xp = Paint()
          ..color = const Color(0xFFFFFFFF)
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true;
        canvas.drawLine(btn + const Offset(-5, -5), btn + const Offset(5, 5), xp);
        canvas.drawLine(btn + const Offset(-5, 5), btn + const Offset(5, -5), xp);
      }
    }
  }

  // Draws the circular arc through three screen points (a → b → c).
  static void _drawArc3(Canvas canvas, Offset a, Offset b, Offset c, Paint paint) {
    final d = 2 *
        (a.dx * (b.dy - c.dy) + b.dx * (c.dy - a.dy) + c.dx * (a.dy - b.dy));
    if (d.abs() < 1e-6) {
      canvas.drawLine(a, b, paint);
      canvas.drawLine(b, c, paint);
      return;
    }
    final a2 = a.dx * a.dx + a.dy * a.dy;
    final b2 = b.dx * b.dx + b.dy * b.dy;
    final c2 = c.dx * c.dx + c.dy * c.dy;
    final ux = (a2 * (b.dy - c.dy) + b2 * (c.dy - a.dy) + c2 * (a.dy - b.dy)) / d;
    final uy = (a2 * (c.dx - b.dx) + b2 * (a.dx - c.dx) + c2 * (b.dx - a.dx)) / d;
    final center = Offset(ux, uy);
    final r = (a - center).distance;
    double norm(double x) {
      while (x < 0) {
        x += 2 * math.pi;
      }
      while (x >= 2 * math.pi) {
        x -= 2 * math.pi;
      }
      return x;
    }

    final s0 = math.atan2(a.dy - uy, a.dx - ux);
    final sweepCcw = norm(math.atan2(c.dy - uy, c.dx - ux) - s0);
    final bRel = norm(math.atan2(b.dy - uy, b.dx - ux) - s0);
    final sweep = bRel <= sweepCcw ? sweepCcw : sweepCcw - 2 * math.pi;
    canvas.drawArc(Rect.fromCircle(center: center, radius: r), s0, sweep, false, paint);
  }

  static String _formatDistance(double v) {
    if (!v.isFinite) return '–';
    if (v >= 100) return v.toStringAsFixed(1);
    if (v >= 1) return v.toStringAsFixed(2);
    return v.toStringAsFixed(4);
  }

  @override
  bool shouldRepaint(covariant _MeasureOverlayPainter oldDelegate) {
    return oldDelegate.scene != scene ||
        oldDelegate.viewScale != viewScale ||
        oldDelegate.viewOffset != viewOffset ||
        oldDelegate.measureRevision != measureRevision ||
        oldDelegate.dragMeas != dragMeas ||
        oldDelegate.dragPt != dragPt ||
        oldDelegate.selectedShape != selectedShape ||
        oldDelegate.commentColor != commentColor ||
        oldDelegate.unit != unit ||
        oldDelegate.insUnits != insUnits ||
        oldDelegate.focusHighlight != focusHighlight ||
        oldDelegate.focusFlash != focusFlash ||
        !listEquals(oldDelegate.photoPoints, photoPoints);
  }
}
