import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
import 'package:dwgfast/shared/widgets/dwg_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

// Prints drawableBounds vs computeContentBounds for a scene bin and renders
// the content box to a PNG — eyeball check that "open on content" frames the
// actual drawing. Scene path via FIT_SCENE env or tool/last_scene.bin.
void main() {
  test('content bounds framing', () async {
    final path = Platform.environment['FIT_SCENE'] ?? 'tool/last_scene.bin';
    final s = DwgScene.fromBytes(File(path).readAsBytesSync());
    final db = s.drawableBounds;
    final cb = computeContentBounds(s);
    // ignore: avoid_print
    print('FITCHECK db=(${db.minX},${db.minY})-(${db.maxX},${db.maxY}) '
        'w=${db.width} h=${db.height}');
    // ignore: avoid_print
    print('FITCHECK cb=(${cb.minX},${cb.minY})-(${cb.maxX},${cb.maxY}) '
        'w=${cb.width} h=${cb.height} '
        'shrink=${(cb.width / db.width * 100).toStringAsFixed(1)}% x '
        '${(cb.height / db.height * 100).toStringAsFixed(1)}%');
    const pxW = 900;
    final pxH = (pxW * cb.height / cb.width).clamp(100, 2400).round();
    final png = await renderDwgRegionToPng(
        scene: s,
        region: cb,
        pxW: pxW,
        pxH: pxH,
        hiddenLayers: {},
        monochrome: false,
        backgroundIsWhite: false);
    File('tool/fit_content.png').writeAsBytesSync(png);
    // ignore: avoid_print
    print('FITCHECK wrote tool/fit_content.png ${png.length}B');
  });
}
