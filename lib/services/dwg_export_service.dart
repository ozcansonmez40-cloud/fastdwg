import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:share_plus/share_plus.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4;

import '../data/models/dwg_scene.dart';

/// Exports a region of a [DwgScene] as a **vector** PDF and opens the Android
/// share sheet with it.
///
/// The PDF is drawn as real geometry (lines, circles, hatch fills, and text),
/// the way AutoCAD's "plot to PDF" does — so it stays crisp at any zoom instead
/// of being a flattened screenshot. It is a black-on-white-paper monochrome
/// plot (like AutoCAD's monochrome.ctb) — every entity prints black regardless
/// of its screen colour.
///
/// The geometry can run to hundreds of thousands of entities, so the PDF is
/// assembled on a background isolate (via [compute]); the UI thread only loads
/// the font, writes the file, and opens the share sheet — it never blocks.
class DwgExportService {
  ByteData? _fontData; // Roboto, loaded once and cached on the main isolate

  /// [paper] is 'fit' (huge page, content fills it — the original behaviour),
  /// 'a4' or 'a3'. [scaleDenom] (e.g. 100 for 1:100) plots at TRUE scale on
  /// that paper using [insUnits] to know what one model unit is; null = fit
  /// the region to the page.
  Future<void> shareRegion({
    required DwgScene scene,
    required DwgBounds region,
    required Set<int> hiddenLayers,
    required String baseName,
    bool showLineWeights = true,
    String paper = 'fit',
    int? scaleDenom,
    int insUnits = 0,
  }) async {
    _fontData ??= await rootBundle.load('assets/fonts/Roboto-Regular.ttf');

    final job = _PdfJob(
      scene: scene,
      region: region,
      hiddenLayers: hiddenLayers,
      fontBytes: _fontData!.buffer.asUint8List(),
      showLineWeights: showLineWeights,
      paper: paper,
      scaleDenom: scaleDenom,
      insUnits: insUnits,
    );
    // Heavy: build the whole vector PDF off the UI thread.
    final pdfBytes = await compute(_renderVectorPdf, job);

    final dir = await getTemporaryDirectory();
    final pdfFile = File('${dir.path}/${_safeName(baseName)}.pdf');
    await pdfFile.writeAsBytes(pdfBytes, flush: true);

    await Share.shareXFiles(
      [XFile(pdfFile.path, mimeType: 'application/pdf')],
      subject: baseName,
    );
  }

  String _safeName(String name) {
    var base = name;
    final dot = base.lastIndexOf('.');
    if (dot > 0) base = base.substring(0, dot);
    base = base.replaceAll(RegExp(r'[^\w\-]+'), '_').replaceAll(RegExp(r'_+'), '_');
    base = base.replaceAll(RegExp(r'^_|_$'), '');
    return base.isEmpty ? 'drawing' : base;
  }
}

/// Immutable bundle of everything the background isolate needs. All fields are
/// sendable across isolates (typed arrays / primitives / plain objects).
class _PdfJob {
  const _PdfJob({
    required this.scene,
    required this.region,
    required this.hiddenLayers,
    required this.fontBytes,
    required this.showLineWeights,
    required this.paper,
    required this.scaleDenom,
    required this.insUnits,
  });

  final DwgScene scene;
  final DwgBounds region;
  final Set<int> hiddenLayers;
  final Uint8List fontBytes;
  final bool showLineWeights;
  final String paper; // 'fit' | 'a4' | 'a3'
  final int? scaleDenom; // 100 → 1:100; null → fit region to page
  final int insUnits; // $INSUNITS code, for true-scale mm conversion
}

/// Millimetres represented by one raw model unit (mirror of the viewer's
/// dwgUnitMm — duplicated here so the isolate stays free of dart:ui imports).
double _unitMm(int insUnits) {
  switch (insUnits) {
    case 1:
      return 25.4; // inches
    case 2:
      return 304.8; // feet
    case 4:
      return 1.0; // mm
    case 5:
      return 10.0; // cm
    case 6:
      return 1000.0; // m
    case 14:
      return 100.0; // dm
    default:
      return 1.0;
  }
}

const double _ptPerMm = 72.0 / 25.4;

/// Longest side of the PDF page, in points. Vector content stays sharp
/// regardless, but a larger page raises the model→point scale so fine text
/// clears the cull threshold and the fit-view rasterisation stays crisp.
const double _pdfMaxSide = 8000.0;
const double _pdfMargin = 24.0;

/// Builds the vector PDF. Runs on a background isolate — must be a top-level
/// function and touch nothing UI-related (the `pdf` package is pure Dart, so
/// this is safe). Everything prints black on white paper (monochrome plot).
Future<Uint8List> _renderVectorPdf(_PdfJob job) async {
  final scene = job.scene;
  final region = job.region;
  final hiddenLayers = job.hiddenLayers;
  final ink = PdfColor.fromInt(0xFF000000); // all entities print black

  final rw = region.width;
  final rh = region.height;
  final bool realPaper = job.paper == 'a4' || job.paper == 'a3';
  final double pageW, pageH, margin;
  if (realPaper) {
    // Real sheet: A4 210×297mm / A3 297×420mm, oriented to the region.
    final shortMm = job.paper == 'a3' ? 297.0 : 210.0;
    final longMm = job.paper == 'a3' ? 420.0 : 297.0;
    final landscape = rw >= rh;
    pageW = (landscape ? longMm : shortMm) * _ptPerMm;
    pageH = (landscape ? shortMm : longMm) * _ptPerMm;
    margin = 8.0 * _ptPerMm; // 8mm plot margin
  } else {
    if (rw >= rh) {
      pageW = _pdfMaxSide;
      pageH = (_pdfMaxSide * rh / rw).clamp(1.0, _pdfMaxSide);
    } else {
      pageH = _pdfMaxSide;
      pageW = (_pdfMaxSide * rw / rh).clamp(1.0, _pdfMaxSide);
    }
    margin = _pdfMargin;
  }

  final pdf = PdfDocument();
  final page = PdfPage(pdf, pageFormat: PdfPageFormat(pageW, pageH));
  final g = page.getGraphics();
  final font = PdfTtfFont(pdf, ByteData.sublistView(job.fontBytes));

  // Model → PDF transform. PDF's origin is bottom-left with Y up, which matches
  // model space, so (unlike the screen) Y is NOT flipped.
  final availW = pageW - 2 * margin;
  final availH = pageH - 2 * margin;
  // True plot scale when requested (1:denom): one model unit is unitMm real
  // millimetres, so on paper it spans unitMm/denom mm. Otherwise fit-to-page.
  final double scale;
  if (realPaper && job.scaleDenom != null && job.scaleDenom! > 0) {
    scale = _unitMm(job.insUnits) / job.scaleDenom! * _ptPerMm;
  } else {
    scale = (availW / rw < availH / rh) ? availW / rw : availH / rh;
  }
  final ox = margin + (availW - rw * scale) / 2 - region.minX * scale;
  final oy = margin + (availH - rh * scale) / 2 - region.minY * scale;
  double tx(double x) => x * scale + ox;
  double ty(double y) => y * scale + oy;

  // Cull anything outside the exported region: for "select area"/"visible"
  // exports the scene holds far more geometry than the page shows, and emitting
  // it all into the content stream was the main slowdown (and bloated the file).
  // A small margin keeps entities that straddle the edge. (For a whole-drawing
  // export the region == the bounds, so nothing extra is dropped.)
  final mx = region.width * 0.02, my = region.height * 0.02;
  final clipMinX = region.minX - mx, clipMaxX = region.maxX + mx;
  final clipMinY = region.minY - my, clipMaxY = region.maxY + my;
  bool boxOutside(double aMinX, double aMinY, double aMaxX, double aMaxY) =>
      aMaxX < clipMinX || aMinX > clipMaxX || aMaxY < clipMinY || aMinY > clipMaxY;

  // Segments shorter than ~⅓pt on the page are sub-pixel: invisible but still
  // cost two path ops each. Dropping them thins out dense drawings massively.
  final minLenSq = (0.33 / scale) * (0.33 / scale);

  // Page stays white (PDF default) — a proper white-paper plot. On a REAL
  // sheet the default pen is a hairline (0.3pt ≈ 0.1mm, what AutoCAD plots for
  // unweighted layers): dense plans at A3 fit / 1:200 turn into solid black
  // blobs with anything fatter, because hatch spacing drops below the pen
  // width. The huge fit page keeps the heavier 0.65pt so lines survive
  // rasterised previews. Layers with an explicit lineweight plot at their
  // true width, capped so nothing is absurd.
  final defaultLineW = realPaper ? 0.3 : 0.65;
  final layers = scene.layers;
  final showLineWeights = job.showLineWeights;
  double lineWidthForLayer(int layerIdx) {
    if (!showLineWeights) return defaultLineW;
    if (layerIdx < 0 || layerIdx >= layers.length) return defaultLineW;
    final mm = layers[layerIdx].lineWeightMm;
    if (mm <= 0.25) return defaultLineW;
    if (realPaper) {
      // A real sheet plots TRUE lineweights, like AutoCAD: 0.35mm ≈ 1pt.
      return (mm * _ptPerMm).clamp(defaultLineW, 5.67); // cap 2mm
    }
    // The 8000pt page makes a true-scale plot width (mm×2.835 ≈ 1pt) almost
    // invisible, so use a heavier multiplier for clear hierarchy (0.35mm wall
    // ≈ 2.5pt), capped so it never blobs.
    return (mm * 7.0).clamp(defaultLineW, 5.0);
  }

  g.setLineWidth(defaultLineW);

  // ── Solid hatch fills (even-odd) ──
  for (final fill in scene.fills) {
    if (hiddenLayers.contains(fill.layer)) continue;
    if (boxOutside(fill.minX, fill.minY, fill.maxX, fill.maxY)) continue;
    var any = false;
    for (final loop in fill.loops) {
      if (loop.length < 6) continue;
      g.moveTo(tx(loop[0]), ty(loop[1]));
      for (var i = 2; i + 1 < loop.length; i += 2) {
        g.lineTo(tx(loop[i]), ty(loop[i + 1]));
      }
      any = true;
    }
    if (!any) continue;
    g.setFillColor(ink);
    g.fillPath(evenOdd: true);
  }

  // ── Lines (one stroked path per colour batch) ──
  scene.lineBatches.forEach((key, model) {
    if (hiddenLayers.contains(DwgScene.batchLayer(key))) return;
    var any = false;
    // Sub-threshold segments are CHAINED like the viewer does, not dropped: a
    // smoothed contour is thousands of tiny stream-order segments, and
    // dropping each one individually erased whole curves from the plot.
    var chainX = double.nan, chainY = double.nan; // pending chain start
    var prevX2 = double.nan, prevY2 = double.nan; // last raw endpoint
    for (var i = 0; i + 3 < model.length; i += 4) {
      final x1 = model[i], y1 = model[i + 1];
      final x2 = model[i + 2], y2 = model[i + 3];
      final gx = x1 - prevX2, gy = y1 - prevY2;
      final continues = !chainX.isNaN &&
          (gx * gx + gy * gy < minLenSq || (x1 == prevX2 && y1 == prevY2));
      final sx = continues ? chainX : x1;
      final sy = continues ? chainY : y1;
      prevX2 = x2;
      prevY2 = y2;
      final dx = sx - x2, dy = sy - y2;
      if (!(dx * dx + dy * dy >= minLenSq)) {
        chainX = sx;
        chainY = sy;
        continue;
      }
      chainX = double.nan;
      // Segment bbox vs. region (skip lines entirely off-page).
      final loX = sx < x2 ? sx : x2, hiX = sx < x2 ? x2 : sx;
      final loY = sy < y2 ? sy : y2, hiY = sy < y2 ? y2 : sy;
      if (boxOutside(loX, loY, hiX, hiY)) continue;
      g.moveTo(tx(sx), ty(sy));
      g.lineTo(tx(x2), ty(y2));
      any = true;
    }
    if (!any) return;
    g.setStrokeColor(ink);
    g.setLineWidth(lineWidthForLayer(DwgScene.batchLayer(key)));
    g.strokePath();
  });

  // ── DOT/DASHDOT linetype marks (never emitted as segments) ──
  if (scene.dotCount > 0) {
    final dc = scene.dotCoords;
    final dotR = defaultLineW * 0.8; // pen-width dot, like a plotted DOT mark
    var anyDot = false;
    for (var i = 0; i < scene.dotCount; i++) {
      if (hiddenLayers.contains(scene.dotLayers[i])) continue;
      final x = dc[i * 2], y = dc[i * 2 + 1];
      if (boxOutside(x, y, x, y)) continue;
      g.drawEllipse(tx(x), ty(y), dotR, dotR);
      anyDot = true;
    }
    if (anyDot) {
      g.setFillColor(ink);
      g.fillPath();
    }
  }

  // ── Circles ──
  final cc = scene.circleCoords;
  for (var i = 0; i < scene.circleCount; i++) {
    if (hiddenLayers.contains(scene.circleLayers[i])) continue;
    final cx = cc[i * 3], cy = cc[i * 3 + 1], rModel = cc[i * 3 + 2];
    if (boxOutside(cx - rModel, cy - rModel, cx + rModel, cy + rModel)) continue;
    final r = rModel * scale;
    if (r < 0.2) continue;
    g.setStrokeColor(ink);
    g.setLineWidth(lineWidthForLayer(scene.circleLayers[i]));
    g.drawEllipse(tx(cx), ty(cy), r, r);
    g.strokePath();
  }

  // ── Text ──
  for (final t in scene.texts) {
    if (hiddenLayers.contains(t.layer)) continue;
    if (boxOutside(t.x, t.y, t.x, t.y)) continue;
    final s = t.value.trim();
    if (s.isEmpty) continue;
    final size = t.height * scale;
    // On a real sheet small annotation text is legitimate (2mm ≈ 5.7pt at
    // scale, sub-pt at 1:500) — keep more of it than on the huge fit page.
    if (size < (realPaper ? 0.4 : 1.0)) continue;
    final halign = t.anchor & 0x0F;
    final valign = (t.anchor >> 4) & 0x0F;
    // Width/vertical metrics are only needed for non-left / non-baseline anchors;
    // most labels are left+baseline, so skip the per-string metrics work there.
    double adx = 0.0, ady = 0.0;
    if (halign != 0 || valign != 0) {
      final m = font.stringMetrics(s);
      final w = m.width * size;
      final ascent = m.ascent * size;
      final descent = m.descent * size; // negative
      adx = halign == 1 ? -w / 2 : (halign == 2 ? -w : 0.0);
      ady = switch (valign) {
        1 => -descent, // bottom
        2 => -(ascent + descent) / 2, // middle
        3 => -ascent, // top
        _ => 0.0, // baseline
      };
    }
    g.setFillColor(ink);
    if (t.rotation != 0) {
      g.saveContext();
      g.setTransform(
        Matrix4.translationValues(tx(t.x), ty(t.y), 0)..rotateZ(t.rotation),
      );
      g.drawString(font, size, s, adx, ady);
      g.restoreContext();
    } else {
      g.drawString(font, size, s, tx(t.x) + adx, ty(t.y) + ady);
    }
  }

  // Plot stamp: scale + sheet in the bottom-right corner of a true-scale plot,
  // like a title block's scale field — so a print can be measured with a ruler.
  if (realPaper && job.scaleDenom != null && job.scaleDenom! > 0) {
    final stamp = '1:${job.scaleDenom}  ·  ${job.paper.toUpperCase()}';
    final m = font.stringMetrics(stamp);
    const stampSize = 9.0;
    g.setFillColor(ink);
    g.drawString(font, stampSize, stamp,
        pageW - margin - m.width * stampSize, margin * 0.35);
  }

  return pdf.save();
}
