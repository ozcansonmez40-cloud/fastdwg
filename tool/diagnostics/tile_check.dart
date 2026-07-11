import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
import 'package:dwgfast/shared/widgets/dwg_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

// Renders a ZOOMED-IN region (5% of extents, centred) before and after the
// tile index is built and reports byte diff + render time — a sanity check
// that walking only viewport cells draws the same picture, faster.
void main() {
  test('tile index visual parity zoomed in', () async {
    final s =
        DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
    final b = s.drawableBounds;
    final cx = (b.minX + b.maxX) / 2, cy = (b.minY + b.maxY) / 2;
    final hw = b.width * 0.025, hh = b.height * 0.025;
    final region = DwgBounds(
        minX: cx - hw, minY: cy - hh, maxX: cx + hw, maxY: cy + hh);
    const pxW = 1200;
    final pxH = (pxW * region.height / region.width).round();

    final sw = Stopwatch()..start();
    final before = await renderDwgRegionToPng(
        scene: s, region: region, pxW: pxW, pxH: pxH, hiddenLayers: {}, monochrome: false, backgroundIsWhite: false);
    final tBefore = sw.elapsedMilliseconds;

    await ensureSceneTiles(s);

    sw.reset();
    final after = await renderDwgRegionToPng(
        scene: s, region: region, pxW: pxW, pxH: pxH, hiddenLayers: {}, monochrome: false, backgroundIsWhite: false);
    final tAfter = sw.elapsedMilliseconds;

    File('tool/tile_before.png').writeAsBytesSync(before);
    File('tool/tile_after.png').writeAsBytesSync(after);
    var diff = 0;
    final n = before.length < after.length ? before.length : after.length;
    for (var i = 0; i < n; i++) {
      if (before[i] != after[i]) diff++;
    }
    // ignore: avoid_print
    print('TILECHECK renderMs before=$tBefore after=$tAfter '
        'byteDiff=$diff/${before.length} sizeB=${before.length} sizeA=${after.length}');
  });
}
