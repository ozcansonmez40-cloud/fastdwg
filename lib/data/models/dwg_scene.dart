import 'dart:convert';
import 'dart:typed_data';

/// Binary scene decoded from the native DWG parser. Geometry is kept in packed
/// typed arrays (not per-entity objects) so large drawings stay memory-lean.
class DwgScene {
  const DwgScene({
    required this.lineBatches,
    required this.lineSegmentCount,
    required this.circleCoords,
    required this.circleColors,
    required this.circleLayers,
    required this.texts,
    required this.bounds,
    required this.dotCoords,
    required this.dotColors,
    required this.dotLayers,
    this.fills = const [],
    this.layers = const [DwgLayer(name: '0')],
    this.nativeEntityCount = 0,
    this.hasError = false,
    this.dwgVersion,
    this.insUnits = 0,
  });

  /// Line segments grouped by (layer, color). Each key is
  /// `(layerIndex << 24) | rgb`; each value is a flat list of
  /// `[x1, y1, x2, y2, ...]` in model coordinates (4 floats per segment).
  final Map<int, Float32List> lineBatches;
  final int lineSegmentCount;

  /// Circles packed as `[cx, cy, r, ...]` (3 floats each); colors/layers parallel.
  final Float32List circleCoords;
  final Int32List circleColors;
  final Int32List circleLayers;

  final List<DwgText> texts;

  /// Filled regions (solid hatches). Each loop is a flat `[x,y,...]` polygon;
  /// multiple loops in one fill are filled with nonzero winding (AutoCAD's hatch
  /// rule) so oppositely-wound inner loops are holes while self-intersecting
  /// glyph outlines (signage) still fill solid instead of shredding.
  final List<DwgFill> fills;

  /// DOT/DASHDOT linetype marks, drawn as fixed-size screen points (so they stay
  /// visible at any zoom). `dotCoords` is packed `[x, y, ...]` (2 floats each);
  /// `dotColors`/`dotLayers` run parallel, one per point.
  final Float32List dotCoords;
  final Int32List dotColors;
  final Int32List dotLayers;

  int get dotCount => dotColors.length;

  final DwgBounds bounds;

  /// Real AutoCAD layer table (index-aligned with the layer ids carried by
  /// lines/circles/texts).
  final List<DwgLayer> layers;
  final int nativeEntityCount;
  final bool hasError;
  final String? dwgVersion;

  /// DWG header $INSUNITS (0=unitless, 1=in, 2=ft, 4=mm, 5=cm, 6=m, ...).
  /// Tells the measure tool how big one raw model unit is, so mm/cm/m readouts
  /// match the drawing's own dimensions instead of assuming millimetres.
  final int insUnits;

  static int batchLayer(int key) => (key >> 24) & 0xFFFF;
  static int batchColor(int key) => key & 0xFFFFFF;

  /// True when the batch holds hatch-pattern lines (flag bit set by the native
  /// parser in the color's spare top byte). Hatches always draw/plot with a
  /// thin pen — a layer lineweight on dense hatching turns it into a black blob.
  static bool batchIsHatch(int key) => (key >> 40) != 0;

  int get circleCount => circleColors.length;

  DwgBounds get drawableBounds => bounds;

  int get entityCount {
    final drawable = lineSegmentCount + circleCount + texts.length;
    return drawable > 0 ? drawable : nativeEntityCount;
  }

  /// Bounding box of everything on one layer, or null if the layer is empty.
  /// One-off linear walk over the packed arrays — used by "zoom to layer".
  DwgBounds? layerBounds(int li) {
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    void pt(double x, double y) {
      if (!x.isFinite || !y.isFinite) return;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }

    lineBatches.forEach((key, m) {
      if (batchLayer(key) != li) return;
      for (var i = 0; i + 1 < m.length; i += 2) {
        pt(m[i], m[i + 1]);
      }
    });
    for (var i = 0; i < circleLayers.length; i++) {
      if (circleLayers[i] != li) continue;
      final r = circleCoords[i * 3 + 2];
      pt(circleCoords[i * 3] - r, circleCoords[i * 3 + 1] - r);
      pt(circleCoords[i * 3] + r, circleCoords[i * 3 + 1] + r);
    }
    for (final t in texts) {
      if (t.layer == li) pt(t.x, t.y);
    }
    for (var i = 0; i < dotLayers.length; i++) {
      if (dotLayers[i] == li) pt(dotCoords[i * 2], dotCoords[i * 2 + 1]);
    }
    for (final f in fills) {
      if (f.layer != li) continue;
      pt(f.minX, f.minY);
      pt(f.maxX, f.maxY);
    }
    if (!minX.isFinite || !maxX.isFinite) return null;
    return DwgBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY);
  }

  static const int _magic = 0x35574446; // "FDW5"

  factory DwgScene.empty() {
    return DwgScene(
      lineBatches: const {},
      lineSegmentCount: 0,
      circleCoords: Float32List(0),
      circleColors: Int32List(0),
      circleLayers: Int32List(0),
      texts: const [],
      fills: const [],
      dotCoords: Float32List(0),
      dotColors: Int32List(0),
      dotLayers: Int32List(0),
      bounds: const DwgBounds(minX: 0, minY: 0, maxX: 100, maxY: 100),
    );
  }

  /// Parses the packed little-endian buffer produced by `fastdwg_native.cpp`.
  /// A truncated or corrupt buffer (app killed mid-write, cache eviction)
  /// yields an empty scene instead of throwing, so callers fall back to
  /// re-parsing the DWG rather than crashing.
  factory DwgScene.fromBytes(Uint8List bytes) {
    try {
      return DwgScene._parse(bytes);
    } on RangeError {
      return DwgScene.empty();
    } on ArgumentError {
      return DwgScene.empty();
    }
  }

  static DwgScene _parse(Uint8List bytes) {
    if (bytes.length < 8) return DwgScene.empty();
    final bd = ByteData.sublistView(bytes);
    var o = 0;

    final magic = bd.getUint32(o, Endian.little);
    o += 4;
    if (magic != _magic) return DwgScene.empty();

    final err = bd.getUint32(o, Endian.little);
    o += 4;
    final hMinX = bd.getFloat32(o, Endian.little);
    final hMinY = bd.getFloat32(o + 4, Endian.little);
    final hMaxX = bd.getFloat32(o + 8, Endian.little);
    final hMaxY = bd.getFloat32(o + 12, Endian.little);
    o += 16;
    final vlen = bd.getUint16(o, Endian.little);
    o += 2;
    if (o + vlen > bytes.length) return DwgScene.empty();
    final version = utf8.decode(bytes.sublist(o, o + vlen), allowMalformed: true);
    o += vlen;
    final insUnits = bd.getUint16(o, Endian.little);
    o += 2;
    final entityCount = bd.getUint32(o, Endian.little);
    o += 4;

    // ── Layers ──
    final layerCount = bd.getUint16(o, Endian.little);
    o += 2;
    final layers = <DwgLayer>[];
    for (var i = 0; i < layerCount; i++) {
      final nl = bd.getUint16(o, Endian.little);
      o += 2;
      if (o + nl + 7 > bytes.length) return DwgScene.empty();
      final name = utf8.decode(bytes.sublist(o, o + nl), allowMalformed: true);
      o += nl;
      final rgb = bd.getUint32(o, Endian.little);
      final visible = bd.getUint8(o + 4) != 0;
      final lineWeight = bd.getInt16(o + 5, Endian.little);
      o += 7;
      layers.add(DwgLayer(
        name: name,
        color: rgb & 0xFFFFFF,
        visible: visible,
        lineWeight: lineWeight,
      ));
    }

    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    void include(double x, double y) {
      // Skip NaN/±Infinity coordinates — a single bad value would poison the
      // bounds (and later make the density-grid `.floor()` throw "Infinity or
      // NaN toInt", which silently aborted the whole decode).
      if (!x.isFinite || !y.isFinite) return;
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }

    // ── Lines (grouped by layer+color) ──
    final lineCount = bd.getUint32(o, Endian.little);
    o += 4;
    const lineStride = 22; // 4×f32 + u32 color + u16 layer
    // Validate the section fits BEFORE sizing lists from the count — a corrupt
    // count would otherwise request a multi-GB allocation.
    if (o + lineCount * lineStride > bytes.length) return DwgScene.empty();
    // First pass: count segments per (layer,color) so each list is sized exactly.
    final groupCounts = <int, int>{};
    var scan = o;
    for (var i = 0; i < lineCount; i++) {
      final raw = bd.getUint32(scan + 16, Endian.little);
      final l = bd.getUint16(scan + 20, Endian.little);
      // Hatch flag (color top byte) rides above layer+rgb in the batch key.
      final key = ((raw >> 24) << 40) | (l << 24) | (raw & 0xFFFFFF);
      groupCounts[key] = (groupCounts[key] ?? 0) + 1;
      scan += lineStride;
    }
    final batches = <int, Float32List>{};
    final cursor = <int, int>{};
    groupCounts.forEach((key, n) {
      batches[key] = Float32List(n * 4);
      cursor[key] = 0;
    });
    for (var i = 0; i < lineCount; i++) {
      final x1 = bd.getFloat32(o, Endian.little);
      final y1 = bd.getFloat32(o + 4, Endian.little);
      final x2 = bd.getFloat32(o + 8, Endian.little);
      final y2 = bd.getFloat32(o + 12, Endian.little);
      final raw = bd.getUint32(o + 16, Endian.little);
      final l = bd.getUint16(o + 20, Endian.little);
      o += lineStride;
      final key = ((raw >> 24) << 40) | (l << 24) | (raw & 0xFFFFFF);
      final b = batches[key]!;
      var k = cursor[key]!;
      b[k++] = x1;
      b[k++] = y1;
      b[k++] = x2;
      b[k++] = y2;
      cursor[key] = k;
      include(x1, y1);
      include(x2, y2);
    }

    // ── Circles ──
    final circleCount = bd.getUint32(o, Endian.little);
    o += 4;
    if (o + circleCount * 18 > bytes.length) return DwgScene.empty();
    final circleCoords = Float32List(circleCount * 3);
    final circleColors = Int32List(circleCount);
    final circleLayers = Int32List(circleCount);
    for (var i = 0; i < circleCount; i++) {
      final cx = bd.getFloat32(o, Endian.little);
      final cy = bd.getFloat32(o + 4, Endian.little);
      final r = bd.getFloat32(o + 8, Endian.little);
      final c = bd.getUint32(o + 12, Endian.little);
      final l = bd.getUint16(o + 16, Endian.little);
      o += 18;
      circleCoords[i * 3] = cx;
      circleCoords[i * 3 + 1] = cy;
      circleCoords[i * 3 + 2] = r;
      circleColors[i] = c & 0xFFFFFF;
      circleLayers[i] = l;
      include(cx - r, cy - r);
      include(cx + r, cy + r);
    }

    // ── Texts ──
    final textCount = bd.getUint32(o, Endian.little);
    o += 4;
    final texts = <DwgText>[];
    for (var i = 0; i < textCount; i++) {
      if (o + 25 > bytes.length) return DwgScene.empty();
      final x = bd.getFloat32(o, Endian.little);
      final y = bd.getFloat32(o + 4, Endian.little);
      final h = bd.getFloat32(o + 8, Endian.little);
      final rot = bd.getFloat32(o + 12, Endian.little);
      final c = bd.getUint32(o + 16, Endian.little);
      final anchor = bd.getUint8(o + 20);
      final l = bd.getUint16(o + 21, Endian.little);
      final len = bd.getUint16(o + 23, Endian.little);
      o += 25;
      if (o + len > bytes.length) return DwgScene.empty();
      final value = utf8.decode(bytes.sublist(o, o + len), allowMalformed: true);
      o += len;
      texts.add(DwgText(
        x: x,
        y: y,
        height: h,
        rotation: rot,
        value: value,
        color: c & 0xFFFFFF,
        anchor: anchor,
        layer: l,
      ));
      include(x, y);
    }

    // ── Fills (solid hatches) ──
    final fillCount = bd.getUint32(o, Endian.little);
    o += 4;
    final fills = <DwgFill>[];
    for (var i = 0; i < fillCount; i++) {
      if (o + 8 > bytes.length) return DwgScene.empty();
      final c = bd.getUint32(o, Endian.little);
      final l = bd.getUint16(o + 4, Endian.little);
      final numLoops = bd.getUint16(o + 6, Endian.little);
      o += 8;
      final loops = <Float32List>[];
      // Track the fill's bbox so we can detect text-background masks below.
      var fminX = double.infinity, fminY = double.infinity;
      var fmaxX = -double.infinity, fmaxY = -double.infinity;
      for (var j = 0; j < numLoops; j++) {
        if (o + 4 > bytes.length) return DwgScene.empty();
        final np = bd.getUint32(o, Endian.little);
        o += 4;
        if (o + np * 8 > bytes.length) return DwgScene.empty();
        final loop = Float32List(np * 2);
        for (var k = 0; k < np; k++) {
          final px = bd.getFloat32(o, Endian.little);
          final py = bd.getFloat32(o + 4, Endian.little);
          o += 8;
          loop[k * 2] = px;
          loop[k * 2 + 1] = py;
          include(px, py);
          if (px.isFinite && py.isFinite) {
            if (px < fminX) fminX = px;
            if (py < fminY) fminY = py;
            if (px > fmaxX) fmaxX = px;
            if (py > fmaxY) fmaxY = py;
          }
        }
        loops.add(loop);
      }
      fills.add(DwgFill(
        color: c & 0xFFFFFF,
        layer: l,
        loops: loops,
        minX: fminX,
        minY: fminY,
        maxX: fmaxX,
        maxY: fmaxY,
      ));
    }

    // ── Dots (DOT/DASHDOT linetype marks) ── appended after fills. Guarded so
    // an older scene without this section (or a truncated buffer) just yields no
    // dots instead of poisoning the whole decode.
    var dotCoords = Float32List(0);
    var dotColors = Int32List(0);
    var dotLayers = Int32List(0);
    if (o + 4 <= bytes.length) {
      final dotCount = bd.getUint32(o, Endian.little);
      o += 4;
      const dotStride = 14; // f32 x + f32 y + u32 color + u16 layer
      if (dotCount > 0 && o + dotCount * dotStride <= bytes.length) {
        dotCoords = Float32List(dotCount * 2);
        dotColors = Int32List(dotCount);
        dotLayers = Int32List(dotCount);
        for (var i = 0; i < dotCount; i++) {
          final px = bd.getFloat32(o, Endian.little);
          final py = bd.getFloat32(o + 4, Endian.little);
          dotColors[i] = bd.getUint32(o + 8, Endian.little) & 0xFFFFFF;
          dotLayers[i] = bd.getUint16(o + 12, Endian.little);
          o += dotStride;
          dotCoords[i * 2] = px;
          dotCoords[i * 2 + 1] = py;
          include(px, py);
        }
      }
    }

    // Drop solid-hatch fills on furnishing layers (chairs, tables, sofas).
    // Furniture blocks in this drawing class carry a decorative SOLID hatch over
    // geometry that is ALSO fully drawn as line outlines. AutoCAD plots the
    // outlines; the solid fill just paints an opaque blob over the furniture —
    // the meeting-table "tefrişler" layer rendered as one salmon mass covering a
    // perfectly good outlined conference table + chairs. The outlines already
    // convey the furniture, so the fills are pure noise. Matched by layer name
    // so structural poché (walls DUVAR, columns kolon) keeps its fills.
    if (fills.isNotEmpty && layers.isNotEmpty) {
      bool isFurnishing(int li) {
        if (li < 0 || li >= layers.length) return false;
        final n = layers[li].name.toLowerCase();
        // tefriş/tefrişler/TEFRIS/MTX-TEFRIS, mefruşat, mobilya, furniture.
        return n.contains('tefri') ||
            n.contains('mefru') ||
            n.contains('mobil') ||
            n.contains('furnit') ||
            n.contains('furnish');
      }

      fills.removeWhere((f) => isFurnishing(f.layer));
    }

    // Drop text-background masks: solid fills whose box wraps a text insertion
    // point are highlight rectangles behind a label (and the reference CAD
    // doesn't plot them), so they paint blocks over the artwork. Structural
    // fills (columns, shear walls) contain no text and are kept. A spatial grid
    // over text points keeps this near-O(fills).
    if (fills.isNotEmpty && texts.isNotEmpty) {
      const tg = 128;
      var tMinX = double.infinity, tMinY = double.infinity;
      var tMaxX = -double.infinity, tMaxY = -double.infinity;
      for (final t in texts) {
        if (!t.x.isFinite || !t.y.isFinite) continue;
        if (t.x < tMinX) tMinX = t.x;
        if (t.y < tMinY) tMinY = t.y;
        if (t.x > tMaxX) tMaxX = t.x;
        if (t.y > tMaxY) tMaxY = t.y;
      }
      final tw = tMaxX - tMinX, th = tMaxY - tMinY;
      if (tw > 0 && th > 0) {
        final cells = <int, List<int>>{}; // cellKey → text indices
        int cellOf(double x, double y) {
          var gx = ((x - tMinX) / tw * (tg - 1)).floor().clamp(0, tg - 1);
          var gy = ((y - tMinY) / th * (tg - 1)).floor().clamp(0, tg - 1);
          return gy * tg + gx;
        }

        for (var i = 0; i < texts.length; i++) {
          final t = texts[i];
          if (t.value.trim().isEmpty || !t.x.isFinite || !t.y.isFinite) continue;
          (cells[cellOf(t.x, t.y)] ??= []).add(i);
        }
        bool wrapsText(DwgFill f) {
          if (!f.minX.isFinite || f.maxX <= f.minX || f.maxY <= f.minY) {
            return false;
          }
          final gx0 = ((f.minX - tMinX) / tw * (tg - 1)).floor().clamp(0, tg - 1);
          final gx1 = ((f.maxX - tMinX) / tw * (tg - 1)).floor().clamp(0, tg - 1);
          final gy0 = ((f.minY - tMinY) / th * (tg - 1)).floor().clamp(0, tg - 1);
          final gy1 = ((f.maxY - tMinY) / th * (tg - 1)).floor().clamp(0, tg - 1);
          for (var gy = gy0; gy <= gy1; gy++) {
            for (var gx = gx0; gx <= gx1; gx++) {
              final list = cells[gy * tg + gx];
              if (list == null) continue;
              for (final ti in list) {
                final t = texts[ti];
                if (t.x >= f.minX &&
                    t.x <= f.maxX &&
                    t.y >= f.minY &&
                    t.y <= f.maxY) {
                  return true;
                }
              }
            }
          }
          return false;
        }

        // Restrict to pure-green (#00FF00) fills: in this drawing the bogus
        // text-background masks are green, while real material hatches (stone,
        // steel) are brown/grey/blue — so this can never strip a material fill.
        // Green structural fills (columns, shear walls) wrap no text and stay.
        fills.removeWhere((f) => (f.color & 0xFFFFFF) == 0x00FF00 && wrapsText(f));
      }
    }

    DwgBounds bounds;
    if (minX.isFinite && maxX > minX && maxY > minY) {
      bounds = DwgBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY);
    } else {
      bounds = DwgBounds(minX: hMinX, minY: hMinY, maxX: hMaxX, maxY: hMaxY);
    }

    // Density-trimmed bounds: a few stray entities far from the drawing inflate
    // the extents and make the real content open up tiny. Bin all geometry into
    // a grid and keep only the cells that hold a meaningful share of it, so the
    // initial fit frames the drawing instead of empty space.
    if (minX.isFinite && maxX > minX && maxY > minY) {
      const grid = 160;
      final counts = Int32List(grid * grid);
      final fullW = maxX - minX, fullH = maxY - minY;
      var total = 0, maxCount = 0;
      void bin(double x, double y) {
        if (!x.isFinite || !y.isFinite) return; // ignore stray NaN/Inf coords
        var gx = ((x - minX) / fullW * (grid - 1)).floor();
        var gy = ((y - minY) / fullH * (grid - 1)).floor();
        gx = gx < 0 ? 0 : (gx >= grid ? grid - 1 : gx);
        gy = gy < 0 ? 0 : (gy >= grid ? grid - 1 : gy);
        final c = ++counts[gy * grid + gx];
        if (c > maxCount) maxCount = c;
        total++;
      }

      batches.forEach((_, m) {
        for (var i = 0; i + 1 < m.length; i += 2) {
          bin(m[i], m[i + 1]);
        }
      });
      for (var i = 0; i < circleColors.length; i++) {
        bin(circleCoords[i * 3], circleCoords[i * 3 + 1]);
      }
      for (final t in texts) {
        bin(t.x, t.y);
      }

      if (total > 200 && maxCount > 0) {
        // Trim only the SPARSEST cells that together hold a tiny fraction
        // (0.2%) of all geometry — those are stray entities far from the
        // drawing. Anything more substantial (even a small, detached sub-plan)
        // survives and stays framed. (The old rule keyed the cutoff to the
        // densest cell, so a very dense main plan trimmed away legitimate
        // smaller plans elsewhere on the sheet.)
        final occupied = <int>[];
        for (var i = 0; i < counts.length; i++) {
          if (counts[i] > 0) occupied.add(i);
        }
        occupied.sort((a, b) => counts[a] - counts[b]);
        final dropBudget = (total * 0.002).floor();
        var dropped = 0;
        var firstKeep = 0;
        while (firstKeep < occupied.length) {
          final c = counts[occupied[firstKeep]];
          if (dropped + c > dropBudget) break;
          dropped += c;
          firstKeep++;
        }
        var gx0 = grid, gy0 = grid, gx1 = -1, gy1 = -1;
        for (var k = firstKeep; k < occupied.length; k++) {
          final idx = occupied[k];
          final gx = idx % grid;
          final gy = idx ~/ grid;
          if (gx < gx0) gx0 = gx;
          if (gx > gx1) gx1 = gx;
          if (gy < gy0) gy0 = gy;
          if (gy > gy1) gy1 = gy;
        }
        if (gx1 >= gx0 && gy1 >= gy0) {
          final cw = fullW / grid, ch = fullH / grid;
          final pad = 0.02; // small margin around the content
          final tminX = minX + (gx0 - pad) * cw;
          final tmaxX = minX + (gx1 + 1 + pad) * cw;
          final tminY = minY + (gy0 - pad) * ch;
          final tmaxY = minY + (gy1 + 1 + pad) * ch;
          if (tmaxX > tminX && tmaxY > tminY) {
            bounds = DwgBounds(
              minX: tminX,
              minY: tminY,
              maxX: tmaxX,
              maxY: tmaxY,
            );
          }
        }
      }
    }

    return DwgScene(
      lineBatches: batches,
      lineSegmentCount: lineCount,
      circleCoords: circleCoords,
      circleColors: circleColors,
      circleLayers: circleLayers,
      texts: texts,
      fills: fills,
      dotCoords: dotCoords,
      dotColors: dotColors,
      dotLayers: dotLayers,
      bounds: bounds,
      layers: layers.isEmpty ? const [DwgLayer(name: '0')] : layers,
      nativeEntityCount: entityCount,
      hasError: err != 0,
      dwgVersion: version,
      insUnits: insUnits,
    );
  }
}

class DwgText {
  const DwgText({
    required this.x,
    required this.y,
    required this.value,
    this.height = 12,
    this.rotation = 0,
    this.color,
    this.anchor = 0,
    this.layer = 0,
  });

  final double x;
  final double y;
  final String value;
  final double height;
  final double rotation;
  final int? color;
  // (valign << 4) | halign — halign 0=left 1=center 2=right,
  // valign 0=baseline 1=bottom 2=middle 3=top.
  final int anchor;
  final int layer;
}

class DwgFill {
  const DwgFill({
    required this.color,
    required this.layer,
    required this.loops,
    this.minX = double.infinity,
    this.minY = double.infinity,
    this.maxX = double.negativeInfinity,
    this.maxY = double.negativeInfinity,
  });

  final int color;
  final int layer;
  // Each loop is a flat polygon `[x0,y0,x1,y1,...]` in model coordinates.
  final List<Float32List> loops;
  // Bounding box (model coords) — used to detect text-background masks.
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;
}

class DwgLayer {
  const DwgLayer({
    required this.name,
    this.color = 0xFFFFFF,
    this.visible = true,
    this.lineWeight = -1,
  });

  final String name;
  final int color;
  final bool visible;

  /// DWG $LWEIGHT code for this layer. LibreDWG returns the AutoCAD lineweight
  /// INDEX (0..23) into the standard width table — NOT a millimetre value — and
  /// special codes 29=BYLAYER, 30=BYBLOCK, 31=default, plus negatives. See
  /// [lineWeightMm] for the conversion.
  final int lineWeight;

  /// Standard AutoCAD lineweights in millimetres, indexed by the DWG code.
  static const List<double> _lwMm = [
    0.00, 0.05, 0.09, 0.13, 0.15, 0.18, 0.20, 0.25, 0.30, 0.35, 0.40, 0.50,
    0.53, 0.60, 0.70, 0.80, 0.90, 1.00, 1.06, 1.20, 1.40, 1.58, 2.00, 2.11,
  ];

  /// Line width in millimetres, or 0 when the layer uses the default weight
  /// (codes 29/30/31, negatives, or out-of-range → default hairline).
  double get lineWeightMm =>
      (lineWeight >= 0 && lineWeight < _lwMm.length) ? _lwMm[lineWeight] : 0.0;
}

class DwgBounds {
  const DwgBounds({
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
  });

  final double minX;
  final double minY;
  final double maxX;
  final double maxY;

  double get width => (maxX - minX).abs() <= 0 ? 1 : (maxX - minX).abs();
  double get height => (maxY - minY).abs() <= 0 ? 1 : (maxY - minY).abs();
}
