import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
import 'package:dwgfast/shared/widgets/dwg_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desk region', () async {
    final s = DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
    // desk sits above the armchairs in MÜDÜR O.
    const minX = 68010.0, minY = 2930.0, maxX = 68320.0, maxY = 3110.0;
    const pxW = 1400;
    final pxH = (pxW * (maxY - minY) / (maxX - minX)).round();
    final png = await renderDwgRegionToPng(
      scene: s,
      region: const DwgBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY),
      pxW: pxW,
      pxH: pxH,
      hiddenLayers: {},
      monochrome: false,
      backgroundIsWhite: false,
    );
    File('tool/desk_view.png').writeAsBytesSync(png);
  });
}
