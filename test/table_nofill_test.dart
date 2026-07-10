// Render the meeting-table region with fills SUPPRESSED to see if the furniture
// also exists as line outlines (then the solid fills are the bug).
import 'dart:io';

import 'package:dwgfast/data/models/dwg_scene.dart';
import 'package:dwgfast/shared/widgets/dwg_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('table region no-fill', () async {
    final full =
        DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
    final scene = DwgScene(
      lineBatches: full.lineBatches,
      lineSegmentCount: full.lineSegmentCount,
      circleCoords: full.circleCoords,
      circleColors: full.circleColors,
      circleLayers: full.circleLayers,
      texts: full.texts,
      bounds: full.bounds,
      dotCoords: full.dotCoords,
      dotColors: full.dotColors,
      dotLayers: full.dotLayers,
      fills: const [], // <-- suppress all fills
      layers: full.layers,
    );
    const minX = 67300.0, minY = 2400.0, maxX = 68100.0, maxY = 3400.0;
    const pxW = 900;
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
    File('tool/table_nofill.png').writeAsBytesSync(png);
  });
}
