// Render the sofa cluster full vs with sub-threshold furniture segments culled.
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

// Build a scene copy where line segments on furnishing layers shorter than
// [thr] model units are dropped.
DwgScene cullTiny(DwgScene s, double thr) {
  bool furn(int li) {
    if (li < 0 || li >= s.layers.length) return false;
    final n = s.layers[li].name.toLowerCase();
    return n.contains('tefri') || n.contains('mefru') || n.contains('mobil');
  }

  final out = <int, Float32List>{};
  s.lineBatches.forEach((k, v) {
    final lay = DwgScene.batchLayer(k);
    if (!furn(lay)) {
      out[k] = v;
      return;
    }
    final keep = <double>[];
    for (var i = 0; i + 3 < v.length; i += 4) {
      final dx = v[i] - v[i + 2], dy = v[i + 1] - v[i + 3];
      if (dx * dx + dy * dy >= thr * thr) {
        keep.addAll([v[i], v[i + 1], v[i + 2], v[i + 3]]);
      }
    }
    if (keep.isNotEmpty) out[k] = Float32List.fromList(keep);
  });
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
  test('sofa cull', () async {
    final s = DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
    await render(s, 'sofa_full.png');
    await render(cullTiny(s, 3.0), 'sofa_cull3.png');
    await render(cullTiny(s, 6.0), 'sofa_cull6.png');
  });
}
