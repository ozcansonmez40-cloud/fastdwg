import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
import 'package:dwgfast/shared/widgets/dwg_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('corridor band', () async {
    final s = DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
    // Wide strip covering both office rows + the corridor between them.
    const minX = 66200.0, minY = 2150.0, maxX = 69200.0, maxY = 3200.0;
    const pxW = 1900;
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
    File('tool/corridor_view.png').writeAsBytesSync(png);
  });
}
