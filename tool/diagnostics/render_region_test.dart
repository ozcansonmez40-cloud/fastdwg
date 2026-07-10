// Render the meeting-table region with the REAL painter to confirm no blob.
import 'dart:io';

import 'package:dwgfast/data/models/dwg_scene.dart';
import 'package:dwgfast/shared/widgets/dwg_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('table region', () async {
    final scene =
        DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
    const minX = 66600.0, minY = 1400.0, maxX = 68800.0, maxY = 4400.0;
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
    File('tool/table_view.png').writeAsBytesSync(png);
    // ignore: avoid_print
    print('rendered ${pxW}x$pxH');
  });
}
