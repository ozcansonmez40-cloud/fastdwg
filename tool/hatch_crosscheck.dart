// Cross-check: AutoCAD's hatch inventory (hatches.txt: pat|layer|x0|y0|x1|y1)
// vs the scene — which hatches have NO geometry inside their bbox?
//   dart run tool/hatch_crosscheck.dart <path-to-hatches.txt>
import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';

void main(List<String> args) {
  final scene =
      DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  final layerIdx = <String, int>{};
  for (var i = 0; i < scene.layers.length; i++) {
    layerIdx[scene.layers[i].name.toUpperCase()] = i;
  }

  final lines = File(args[0]).readAsLinesSync();
  var checked = 0, missing = 0, noLayer = 0;
  final missingRows = <String>[];
  for (final row in lines) {
    final p = row.split('|');
    if (p.length < 6) continue;
    final pat = p[0], layer = p[1];
    final x0 = double.parse(p[2]), y0 = double.parse(p[3]);
    final x1 = double.parse(p[4]), y1 = double.parse(p[5]);
    checked++;
    final li = layerIdx[layer.toUpperCase()];
    if (li == null) {
      noLayer++;
      continue;
    }
    // Count scene segments on that layer with a midpoint inside the bbox
    // (small margin).
    final mx = (x1 - x0).abs() * 0.05 + 1, my = (y1 - y0).abs() * 0.05 + 1;
    var found = 0;
    scene.lineBatches.forEach((key, v) {
      if (DwgScene.batchLayer(key) != li || found > 0) return;
      for (var i = 0; i + 3 < v.length; i += 4) {
        final cx = (v[i] + v[i + 2]) / 2, cy = (v[i + 1] + v[i + 3]) / 2;
        if (cx >= x0 - mx && cx <= x1 + mx && cy >= y0 - my && cy <= y1 + my) {
          found++;
          break;
        }
      }
    });
    // Solid fills too.
    if (found == 0) {
      for (final f in scene.fills) {
        if (f.layer != li) continue;
        if (f.loops.isEmpty || f.loops[0].length < 2) continue;
        final cx = f.loops[0][0], cy = f.loops[0][1];
        if (cx >= x0 - mx && cx <= x1 + mx && cy >= y0 - my && cy <= y1 + my) {
          found++;
          break;
        }
      }
    }
    if (found == 0) {
      missing++;
      if (missingRows.length < 25) missingRows.add(row);
    }
  }
  print('checked=$checked missing=$missing layerNotFound=$noLayer');
  print('=== missing hatches (pat|layer|bbox) ===');
  missingRows.forEach(print);
}
