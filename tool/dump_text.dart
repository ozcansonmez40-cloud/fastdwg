import 'dart:io';
import 'dart:math';

import 'package:dwgfast/data/models/dwg_scene.dart';

void main(List<String> args) {
  final path = args.isNotEmpty ? args[0] : r'C:\Users\Acer\AppData\Local\Temp\last_scene.bin';
  final bytes = File(path).readAsBytesSync();
  final scene = DwgScene.fromBytes(bytes);
  stdout.writeln('texts=${scene.texts.length} lines=${scene.lineSegmentCount} '
      'circles=${scene.circleCount} fills=${scene.fills.length} '
      'layers=${scene.layers.length} ver=${scene.dwgVersion} err=${scene.hasError}');
  stdout.writeln('bounds=(${scene.bounds.minX},${scene.bounds.minY})-(${scene.bounds.maxX},${scene.bounds.maxY})');

  // Top fills by bbox area (find the big granite solid bases/stripes).
  final fillsByArea = [...scene.fills];
  fillsByArea.sort((a, b) {
    double area(DwgFill f) {
      var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
      for (final l in f.loops) {
        for (var i = 0; i + 1 < l.length; i += 2) {
          if (l[i] < x0) x0 = l[i];
          if (l[i] > x1) x1 = l[i];
          if (l[i + 1] < y0) y0 = l[i + 1];
          if (l[i + 1] > y1) y1 = l[i + 1];
        }
      }
      return (x1 - x0) * (y1 - y0);
    }
    return area(b).compareTo(area(a));
  });
  stdout.writeln('--- top 20 fills by area ---');
  for (final f in fillsByArea.take(20)) {
    var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    var pts = 0;
    for (final l in f.loops) {
      pts += l.length ~/ 2;
      for (var i = 0; i + 1 < l.length; i += 2) {
        if (l[i] < x0) x0 = l[i];
        if (l[i] > x1) x1 = l[i];
        if (l[i + 1] < y0) y0 = l[i + 1];
        if (l[i + 1] > y1) y1 = l[i + 1];
      }
    }
    stdout.writeln('  #${f.color.toRadixString(16).padLeft(6, '0')} loops=${f.loops.length} pts=$pts '
        'bbox=${(x1 - x0).toStringAsFixed(0)}x${(y1 - y0).toStringAsFixed(0)} @(${x0.toStringAsFixed(0)},${y0.toStringAsFixed(0)})');
  }

  final q = args.length > 1 ? args[1].toUpperCase() : 'DRAGOS';
  final hits = scene.texts
      .where((t) => t.value.toUpperCase().contains(q))
      .toList();
  stdout.writeln('--- texts containing "$q": ${hits.length} ---');
  for (final t in hits) {
    final ln = t.layer < scene.layers.length ? scene.layers[t.layer].name : '?';
    stdout.writeln('"${t.value}" x=${t.x.toStringAsFixed(2)} y=${t.y.toStringAsFixed(2)} '
        'h=${t.height.toStringAsFixed(2)} rot=${t.rotation.toStringAsFixed(3)} '
        'anchor=${t.anchor} color=${t.color?.toRadixString(16)} layer=$ln');
  }

  // Tallest texts (big title letters, if any are real TEXT entities).
  final tall = [...scene.texts]..sort((a, b) => b.height.compareTo(a.height));
  stdout.writeln('--- 20 tallest texts ---');
  for (final t in tall.take(20)) {
    stdout.writeln('h=${t.height.toStringAsFixed(2)} "${t.value}" @(${t.x.toStringAsFixed(1)},${t.y.toStringAsFixed(1)})');
  }

  // Count duplicate text entities (same value, within 5 units) — the doubling.
  var dupCount = 0;
  final dupExamples = <String>[];
  for (var i = 0; i < scene.texts.length; i++) {
    for (var j = i + 1; j < scene.texts.length; j++) {
      final a = scene.texts[i], b = scene.texts[j];
      final d = sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2));
      if (d < 5 && a.value == b.value) {
        dupCount++;
        if (dupExamples.length < 25) {
          dupExamples.add('"${a.value}" d=${d.toStringAsFixed(2)} '
              'h=${a.height.toStringAsFixed(1)}/${b.height.toStringAsFixed(1)} @(${a.x.toStringAsFixed(0)},${a.y.toStringAsFixed(0)})');
        }
      }
    }
  }
  stdout.writeln('--- duplicate text pairs (dist<5, same value): $dupCount ---');
  for (final e in dupExamples) {
    stdout.writeln(e);
  }

  // Locate a detail by anchor text (3rd arg) and characterize geometry around it.
  final anchorQ = args.length > 2 ? args[2].toUpperCase() : 'PEYZAJ UYGULAMA';
  final anchorTxt = scene.texts.firstWhere(
    (t) => t.value.toUpperCase().contains(anchorQ),
    orElse: () => scene.texts.first,
  );
  final bx = anchorTxt.x, by = anchorTxt.y;
  stdout.writeln('anchor "$anchorQ" → "${anchorTxt.value}" @(${bx.toStringAsFixed(0)},${by.toStringAsFixed(0)})');
  final r = args.length > 3 ? double.parse(args[3]) : 800.0; // box half-size
  stdout.writeln('--- geometry within $r of (${bx.toStringAsFixed(0)},${by.toStringAsFixed(0)}) ---');

  // Fills (solid hatches) overlapping the box, grouped by color.
  final fillByColor = <int, int>{};
  var fillsInBox = 0;
  for (final f in scene.fills) {
    var inBox = false;
    for (final loop in f.loops) {
      for (var i = 0; i + 1 < loop.length; i += 2) {
        if ((loop[i] - bx).abs() < r && (loop[i + 1] - by).abs() < r) {
          inBox = true;
          break;
        }
      }
      if (inBox) break;
    }
    if (inBox) {
      fillsInBox++;
      fillByColor[f.color] = (fillByColor[f.color] ?? 0) + 1;
    }
  }
  stdout.writeln('fills in box: $fillsInBox');
  fillByColor.forEach((c, n) => stdout.writeln('  fill color #${c.toRadixString(16).padLeft(6, '0')}: $n'));

  // Lines in the box, grouped by (layer,color).
  final lineByKey = <String, int>{};
  var linesInBox = 0;
  scene.lineBatches.forEach((key, m) {
    final layer = DwgScene.batchLayer(key);
    final color = DwgScene.batchColor(key);
    for (var i = 0; i + 3 < m.length; i += 4) {
      if ((m[i] - bx).abs() < r && (m[i + 1] - by).abs() < r) {
        linesInBox++;
        final ln = layer < scene.layers.length ? scene.layers[layer].name : '?';
        final k = '$ln/#${color.toRadixString(16).padLeft(6, '0')}';
        lineByKey[k] = (lineByKey[k] ?? 0) + 1;
      }
    }
  });
  stdout.writeln('line segments in box: $linesInBox');
  final sorted = lineByKey.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  for (final e in sorted.take(15)) {
    stdout.writeln('  ${e.key}: ${e.value}');
  }

  // Deep-dump the loop bboxes of the biggest multi-loop fill near the title,
  // to see whether round-letter counters exist as separate (nested) loops.
  DwgFill? biggest;
  var bestLoops = 0;
  for (final f in scene.fills) {
    var near = false;
    for (final loop in f.loops) {
      for (var i = 0; i + 1 < loop.length; i += 2) {
        if ((loop[i] - bx).abs() < r && (loop[i + 1] - by).abs() < r) { near = true; break; }
      }
      if (near) break;
    }
    if (near && f.loops.length > bestLoops) { bestLoops = f.loops.length; biggest = f; }
  }
  // Largest-area fill in the box (the big letters), for raster comparison.
  DwgFill? widest;
  var widestArea = 0.0;
  for (final f in scene.fills) {
    var near = false;
    var fx0 = double.infinity, fy0 = double.infinity, fx1 = -double.infinity, fy1 = -double.infinity;
    for (final loop in f.loops) {
      for (var i = 0; i + 1 < loop.length; i += 2) {
        if ((loop[i] - bx).abs() < r && (loop[i + 1] - by).abs() < r) near = true;
        if (loop[i] < fx0) fx0 = loop[i];
        if (loop[i] > fx1) fx1 = loop[i];
        if (loop[i + 1] < fy0) fy0 = loop[i + 1];
        if (loop[i + 1] > fy1) fy1 = loop[i + 1];
      }
    }
    final area = (fx1 - fx0) * (fy1 - fy0);
    if (near && area > widestArea) { widestArea = area; widest = f; }
  }
  if (widest != null) {
    stdout.writeln('=== WIDEST fill raster ===');
    _raster(widest);
  }

  // Target a single fill by coordinate (args[4]=tx, args[5]=ty): the fill whose
  // bbox centre is nearest. Rasters it + dumps each loop's winding signed-area
  // and max edge jump — to see why a round glyph fills solid (counter not carved).
  if (args.length > 5) {
    final tx = double.parse(args[4]), ty = double.parse(args[5]);
    DwgFill? target;
    var bestD = double.infinity;
    for (final f in scene.fills) {
      var cx = 0.0, cy = 0.0, np = 0;
      for (final l in f.loops) {
        for (var i = 0; i + 1 < l.length; i += 2) { cx += l[i]; cy += l[i + 1]; np++; }
      }
      if (np == 0) continue;
      cx /= np; cy /= np;
      final d = sqrt(pow(cx - tx, 2) + pow(cy - ty, 2));
      if (d < bestD) { bestD = d; target = f; }
    }
    if (target != null) {
      stdout.writeln('=== TARGET fill @($tx,$ty) dist=${bestD.toStringAsFixed(1)} loops=${target.loops.length} ===');
      for (var li = 0; li < target.loops.length; li++) {
        final l = target.loops[li];
        final n = l.length ~/ 2;
        var area = 0.0, maxj = 0.0;
        for (var i = 0; i < n; i++) {
          final ax = l[i * 2], ay = l[i * 2 + 1];
          final bx2 = l[((i + 1) % n) * 2], by2 = l[((i + 1) % n) * 2 + 1];
          area += ax * by2 - bx2 * ay;
          final j = sqrt(pow(bx2 - ax, 2) + pow(by2 - ay, 2));
          if (j > maxj) maxj = j;
        }
        stdout.writeln('  loop $li: pts=$n signedArea=${(area / 2).toStringAsFixed(1)} '
            'winding=${area > 0 ? "CCW" : "CW"} maxEdgeJump=${maxj.toStringAsFixed(1)}');
      }
      _raster(target);
    }
  }

  if (biggest != null) {
    _raster(biggest);
    stdout.writeln('--- per-loop bbox of biggest fill (loops=${biggest.loops.length}, color=#${biggest.color.toRadixString(16)}) ---');
    for (var li = 0; li < biggest.loops.length; li++) {
      final loop = biggest.loops[li];
      var lx0 = double.infinity, ly0 = double.infinity, lx1 = -double.infinity, ly1 = -double.infinity;
      for (var i = 0; i + 1 < loop.length; i += 2) {
        if (loop[i] < lx0) lx0 = loop[i];
        if (loop[i] > lx1) lx1 = loop[i];
        if (loop[i + 1] < ly0) ly0 = loop[i + 1];
        if (loop[i + 1] > ly1) ly1 = loop[i + 1];
      }
      stdout.writeln('  loop $li: pts=${loop.length ~/ 2} bbox=${(lx1 - lx0).toStringAsFixed(1)}x${(ly1 - ly0).toStringAsFixed(1)} @(${lx0.toStringAsFixed(0)},${ly0.toStringAsFixed(0)})');
    }

    // Inspect the single largest loop: max edge-length jump (tessellation bug
    // signature) and a sampling of points.
    var giant = 0;
    var giantArea = 0.0;
    for (var li = 0; li < biggest.loops.length; li++) {
      final loop = biggest.loops[li];
      var lx0 = double.infinity, ly0 = double.infinity, lx1 = -double.infinity, ly1 = -double.infinity;
      for (var i = 0; i + 1 < loop.length; i += 2) {
        if (loop[i] < lx0) lx0 = loop[i];
        if (loop[i] > lx1) lx1 = loop[i];
        if (loop[i + 1] < ly0) ly0 = loop[i + 1];
        if (loop[i + 1] > ly1) ly1 = loop[i + 1];
      }
      final area = (lx1 - lx0) * (ly1 - ly0);
      if (area > giantArea) { giantArea = area; giant = li; }
    }
    final loop = biggest.loops[giant];
    stdout.writeln('--- giant loop $giant raw geometry (pts=${loop.length ~/ 2}) ---');
    var maxJump = 0.0;
    var jumpAt = -1;
    for (var i = 2; i + 1 < loop.length; i += 2) {
      final dx = loop[i] - loop[i - 2], dy = loop[i + 1] - loop[i - 1];
      final d = sqrt(dx * dx + dy * dy);
      if (d > maxJump) { maxJump = d; jumpAt = i ~/ 2; }
    }
    stdout.writeln('  max edge jump=${maxJump.toStringAsFixed(1)} at idx=$jumpAt');
    // Median centroid + count of points far from it (the stray excursion).
    final xs = <double>[], ys = <double>[];
    for (var i = 0; i + 1 < loop.length; i += 2) { xs.add(loop[i]); ys.add(loop[i + 1]); }
    final sx = [...xs]..sort();
    final sy = [...ys]..sort();
    final mx = sx[sx.length ~/ 2], my = sy[sy.length ~/ 2];
    var farCount = 0;
    final farIdx = <int>[];
    for (var k = 0; k < xs.length; k++) {
      final d = sqrt(pow(xs[k] - mx, 2) + pow(ys[k] - my, 2));
      if (d > 100) { farCount++; if (farIdx.length < 30) farIdx.add(k); }
    }
    stdout.writeln('  median centroid=(${mx.toStringAsFixed(0)},${my.toStringAsFixed(0)}) farPts(>100)=$farCount idx=$farIdx');
    final step = (loop.length ~/ 2 / 16).ceil().clamp(1, 9999);
    final sb = StringBuffer();
    for (var i = 0; i + 1 < loop.length; i += 2 * step) {
      sb.write('(${loop[i].toStringAsFixed(0)},${loop[i + 1].toStringAsFixed(0)}) ');
    }
    stdout.writeln('  sample: $sb');

    // Verify the C++ split_solid_loop algorithm (ported) on every loop.
    stdout.writeln('--- split verification (loops that split) ---');
    for (var li = 0; li < biggest.loops.length; li++) {
      final pts = <List<double>>[];
      final lp = biggest.loops[li];
      for (var i = 0; i + 1 < lp.length; i += 2) {
        pts.add([lp[i], lp[i + 1]]);
      }
      final before = _bbox(pts);
      final pieces = _split(pts);
      if (pieces.length != 1 || pieces[0].length != pts.length) {
        final boxes = pieces.map((p) {
          final b = _bbox(p);
          return '${p.length}pts ${b[0].toStringAsFixed(0)}x${b[1].toStringAsFixed(0)}';
        }).join(', ');
        stdout.writeln('  loop $li (${pts.length}pts bbox ${before[0].toStringAsFixed(0)}x${before[1].toStringAsFixed(0)}) '
            '→ ${pieces.length} pieces: [$boxes]');
      }
    }
  }

  // Fill loop shapes in the box: loop count, point counts, bbox size.
  stdout.writeln('--- fill loop details in box (first 40) ---');
  var shown = 0;
  for (final f in scene.fills) {
    if (shown >= 40) break;
    var inBox = false;
    var fminx = double.infinity, fminy = double.infinity;
    var fmaxx = -double.infinity, fmaxy = -double.infinity;
    final ptCounts = <int>[];
    for (final loop in f.loops) {
      ptCounts.add(loop.length ~/ 2);
      for (var i = 0; i + 1 < loop.length; i += 2) {
        final x = loop[i], y = loop[i + 1];
        if ((x - bx).abs() < r && (y - by).abs() < r) inBox = true;
        if (x < fminx) fminx = x;
        if (y < fminy) fminy = y;
        if (x > fmaxx) fmaxx = x;
        if (y > fmaxy) fmaxy = y;
      }
    }
    if (!inBox) continue;
    shown++;
    stdout.writeln('  color=#${f.color.toRadixString(16).padLeft(6, '0')} loops=${f.loops.length} '
        'pts=$ptCounts bbox=${(fmaxx - fminx).toStringAsFixed(1)}x${(fmaxy - fminy).toStringAsFixed(1)} '
        '@(${fminx.toStringAsFixed(0)},${fminy.toStringAsFixed(0)})');
  }
}

// ASCII-rasterize a fill (its loops) under even-odd vs nonzero winding to see
// which rule renders a clean glyph. Model Y is up; we flip rows for display.
void _raster(DwgFill fill) {
  var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
  for (final loop in fill.loops) {
    for (var i = 0; i + 1 < loop.length; i += 2) {
      if (loop[i] < x0) x0 = loop[i];
      if (loop[i] > x1) x1 = loop[i];
      if (loop[i + 1] < y0) y0 = loop[i + 1];
      if (loop[i + 1] > y1) y1 = loop[i + 1];
    }
  }
  const cols = 80;
  final w = x1 - x0, h = y1 - y0;
  if (w <= 0 || h <= 0) return;
  final cell = w / cols;
  final rows = (h / cell).ceil().clamp(1, 60);
  stdout.writeln('raster ${cols}x$rows of fill bbox ${w.toStringAsFixed(0)}x${h.toStringAsFixed(0)} '
      'loops=${fill.loops.length}  [E]ven-odd | [N]onzero');
  for (var ry = 0; ry < rows; ry++) {
    final py = y1 - (ry + 0.5) * cell; // top row = max y
    final eo = StringBuffer(), nz = StringBuffer();
    for (var rx = 0; rx < cols; rx++) {
      final px = x0 + (rx + 0.5) * cell;
      var cross = 0, wind = 0;
      for (final loop in fill.loops) {
        final n = loop.length ~/ 2;
        for (var i = 0; i < n; i++) {
          final ax = loop[i * 2], ay = loop[i * 2 + 1];
          final bx2 = loop[((i + 1) % n) * 2], by2 = loop[((i + 1) % n) * 2 + 1];
          // Ray to +x from (px,py): does edge (a,b) cross horizontal line py?
          if ((ay > py) != (by2 > py)) {
            final t = (py - ay) / (by2 - ay);
            final ix = ax + t * (bx2 - ax);
            if (ix > px) {
              cross++;
              wind += by2 > ay ? 1 : -1;
            }
          }
        }
      }
      eo.write(cross.isOdd ? '#' : ' ');
      nz.write(wind != 0 ? '#' : ' ');
    }
    stdout.writeln('E|$eo');
    stdout.writeln('N|$nz');
  }
}

List<double> _bbox(List<List<double>> p) {
  var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
  for (final v in p) {
    if (v[0] < x0) x0 = v[0];
    if (v[0] > x1) x1 = v[0];
    if (v[1] < y0) y0 = v[1];
    if (v[1] > y1) y1 = v[1];
  }
  return [x1 - x0, y1 - y0];
}

List<List<List<double>>> _split(List<List<double>> poly) {
  final n = poly.length;
  if (n < 4) return [poly];
  final xs = [for (final v in poly) v[0]]..sort();
  final ys = [for (final v in poly) v[1]]..sort();
  final cx = xs[n ~/ 2], cy = ys[n ~/ 2];
  final rad = [for (final v in poly) sqrt(pow(v[0] - cx, 2) + pow(v[1] - cy, 2))]..sort();
  var medr = rad[n ~/ 2];
  if (medr < 1e-9) medr = 1e-9;
  final cut = medr * 8.0;
  final breaks = <int>[];
  for (var i = 0; i < n; i++) {
    final a = poly[i], b = poly[(i + 1) % n];
    if (sqrt(pow(b[0] - a[0], 2) + pow(b[1] - a[1], 2)) > cut) breaks.add(i);
  }
  if (breaks.isEmpty) return [poly];
  final arcs = <List<List<double>>>[];
  var bestArc = 0, bestSize = 0;
  for (var k = 0; k < breaks.length; k++) {
    final start = (breaks[k] + 1) % n;
    final end = breaks[(k + 1) % breaks.length];
    final arc = <List<double>>[];
    var i = start;
    while (true) {
      arc.add(poly[i]);
      if (i == end || arc.length > n) break;
      i = (i + 1) % n;
    }
    if (arc.length >= 3) {
      if (arc.length > bestSize) { bestSize = arc.length; bestArc = arcs.length; }
      arcs.add(arc);
    }
  }
  if (arcs.isEmpty) return [poly];
  final out = <List<List<double>>>[];
  for (var a = 0; a < arcs.length; a++) {
    var ax = 0.0, ay = 0.0;
    for (final p in arcs[a]) { ax += p[0]; ay += p[1]; }
    ax /= arcs[a].length;
    ay /= arcs[a].length;
    if (a == bestArc || sqrt(pow(ax - cx, 2) + pow(ay - cy, 2)) <= cut) {
      out.add(arcs[a]);
    }
  }
  return out.isEmpty ? [poly] : out;
}
