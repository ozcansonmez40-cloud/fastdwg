// Render the sofa cluster full vs with near-duplicate segments deduped.
import 'dart:io';
import 'dart:typed_data';

import 'package:dwgfast/data/models/dwg_scene.dart';
import 'package:dwgfast/shared/widgets/dwg_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

const minX = 68000.0, minY = 2400.0, maxX = 68760.0, maxY = 3060.0;
const pxW = 1000;

Future<void> render(DwgScene scene, String name) async {
  final pxH = (pxW * (maxY - minY) / (maxX - minX)).round();
  final png = await renderDwgRegionToPng(
    scene: scene,
    region: const DwgBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY),
    pxW: pxW,
    pxH: pxH,
    hiddenLayers: {},
    monochrome: false,
    backgroundIsWhite: false,
  );
  File('tool/$name').writeAsBytesSync(png);
}

DwgScene dedup(DwgScene s, double q) {
  final out = <int, Float32List>{};
  var removed = 0, kept = 0;
  s.lineBatches.forEach((k, v) {
    final seen = <String>{};
    final keep = <double>[];
    for (var i = 0; i + 3 < v.length; i += 4) {
      var x1 = v[i], y1 = v[i + 1], x2 = v[i + 2], y2 = v[i + 3];
      // order endpoints so A-B == B-A
      if (x2 < x1 || (x2 == x1 && y2 < y1)) {
        final tx = x1, ty = y1;
        x1 = x2; y1 = y2; x2 = tx; y2 = ty;
      }
      String qz(double a) => (a / q).roundToDouble().toStringAsFixed(0);
      final key = '${qz(x1)},${qz(y1)},${qz(x2)},${qz(y2)}';
      if (seen.add(key)) {
        keep.addAll([v[i], v[i + 1], v[i + 2], v[i + 3]]);
        kept++;
      } else {
        removed++;
      }
    }
    if (keep.isNotEmpty) out[k] = Float32List.fromList(keep);
  });
  // ignore: avoid_print
  print('dedup q=$q kept=$kept removed=$removed');
  return DwgScene(
    lineBatches: out,
    lineSegmentCount: s.lineSegmentCount,
    circleCoords: s.circleCoords,
    circleColors: s.circleColors,
    circleLayers: s.circleLayers,
    texts: s.texts,
    bounds: s.bounds,
    dotCoords: s.dotCoords,
    dotColors: s.dotColors,
    dotLayers: s.dotLayers,
    fills: s.fills,
    layers: s.layers,
  );
}

void main() {
  test('sofa dedup', () async {
    final s = DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
    await render(dedup(s, 0.5), 'sofa_dedup05.png');
    await render(dedup(s, 2.0), 'sofa_dedup2.png');
  });
}
