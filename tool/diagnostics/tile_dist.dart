import 'dart:io';
import 'dart:math' as math;
import 'package:dwgfast/data/models/dwg_scene.dart';
import 'package:flutter_test/flutter_test.dart';

// Measures how drawing content is distributed over the drawableBounds — if
// stray far-away entities inflate the extents, a 16×16 grid over them puts
// nearly all segments in a couple of cells and the tile index filters nothing.
void main() {
  test('segment distribution over extents', () {
    final s =
        DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
    final b = s.drawableBounds;
    // ignore: avoid_print
    print('TILEDIST bounds=(${b.minX},${b.minY})-(${b.maxX},${b.maxY}) '
        'w=${b.width} h=${b.height} segs=${s.lineSegmentCount}');
    const g = 16;
    final cellW = b.width / g, cellH = b.height / g;
    final counts = List<int>.filled(g * g, 0);
    var long = 0;
    var mnX = double.infinity, mnY = double.infinity;
    var mxX = double.negativeInfinity, mxY = double.negativeInfinity;
    for (final m in s.lineBatches.values) {
      for (var i = 0; i + 3 < m.length; i += 4) {
        final x1 = m[i], y1 = m[i + 1], x2 = m[i + 2], y2 = m[i + 3];
        mnX = math.min(mnX, math.min(x1, x2));
        mxX = math.max(mxX, math.max(x1, x2));
        mnY = math.min(mnY, math.min(y1, y2));
        mxY = math.max(mxY, math.max(y1, y2));
        final tx0 = (((x1 < x2 ? x1 : x2) - b.minX) / cellW).floor();
        final tx1 = (((x1 > x2 ? x1 : x2) - b.minX) / cellW).floor();
        final ty0 = (((y1 < y2 ? y1 : y2) - b.minY) / cellH).floor();
        final ty1 = (((y1 > y2 ? y1 : y2) - b.minY) / cellH).floor();
        if (tx1 - tx0 > 1 || ty1 - ty0 > 1) {
          long++;
        } else {
          final cx =
              ((((x1 + x2) * 0.5) - b.minX) / cellW).floor().clamp(0, g - 1);
          final cy =
              ((((y1 + y2) * 0.5) - b.minY) / cellH).floor().clamp(0, g - 1);
          counts[cy * g + cx]++;
        }
      }
    }
    counts.sort();
    final top = counts.sublist(g * g - 8);
    // ignore: avoid_print
    print('TILEDIST contentBox=($mnX,$mnY)-($mxX,$mxY) long=$long '
        'top8cells=$top');
  });
}
