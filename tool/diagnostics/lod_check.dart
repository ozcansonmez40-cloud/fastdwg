import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
import 'package:dwgfast/shared/widgets/dwg_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

// Renders the full-extents view before and after the LOD tiers are built and
// reports how many pixels differ — a sanity check that the pre-chained copies
// draw the same picture at that zoom.
void main() {
  test('lod visual parity at extents', () async {
    final s =
        DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
    final b = s.drawableBounds;
    const pxW = 1200;
    final pxH = (pxW * b.height / b.width).round();

    final sw = Stopwatch()..start();
    final before = await renderDwgRegionToPng(
        scene: s, region: b, pxW: pxW, pxH: pxH, hiddenLayers: {}, monochrome: false, backgroundIsWhite: false);
    final tBefore = sw.elapsedMilliseconds;

    await ensureSceneLod(s);

    sw.reset();
    final after = await renderDwgRegionToPng(
        scene: s, region: b, pxW: pxW, pxH: pxH, hiddenLayers: {}, monochrome: false, backgroundIsWhite: false);
    final tAfter = sw.elapsedMilliseconds;

    File('tool/lod_before.png').writeAsBytesSync(before);
    File('tool/lod_after.png').writeAsBytesSync(after);
    var diff = 0;
    final n = before.length < after.length ? before.length : after.length;
    for (var i = 0; i < n; i++) {
      if (before[i] != after[i]) diff++;
    }
    // PNG bytes aren't pixels, but identical output → identical bytes; small
    // byte diffs mean re-encoding noise, large means visual change. Report.
    // ignore: avoid_print
    print('LODCHECK renderMs before=$tBefore after=$tAfter '
        'byteDiff=$diff/${before.length} sizeB=${before.length} sizeA=${after.length}');
  });
}
