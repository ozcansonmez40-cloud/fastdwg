// Where do DUVAR fills exist along X? Cluster fills by X to find which copies
// of the repeated stair section have wall fills and which don't.
//   dart run tool/fill_inspect.dart
import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';

void main() {
  final scene =
      DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  var duvar = -1;
  for (var i = 0; i < scene.layers.length; i++) {
    if (scene.layers[i].name.toUpperCase() == 'DUVAR') duvar = i;
  }
  print('fills=${scene.fills.length} duvarLayer=$duvar');

  // All fills: bucket centers by 50k X bands, list DUVAR separately.
  final all = <int, int>{};
  final duvarBand = <int, int>{};
  for (final f in scene.fills) {
    if (f.loops.isEmpty || f.loops[0].length < 2) continue;
    final cx = f.loops[0][0];
    final band = (cx / 50000).floor();
    all[band] = (all[band] ?? 0) + 1;
    if (f.layer == duvar) duvarBand[band] = (duvarBand[band] ?? 0) + 1;
  }
  print('=== fill count by X band (50k) — all / DUVAR ===');
  final keys = all.keys.toList()..sort();
  for (final k in keys) {
    print('x≈${k * 50}k: ${all[k]} / ${duvarBand[k] ?? 0}');
  }

  // Lines on DUVAR by X band, to see where wall GEOMETRY exists.
  final lineBand = <int, int>{};
  scene.lineBatches.forEach((key, v) {
    if (DwgScene.batchLayer(key) != duvar) return;
    for (var i = 0; i + 3 < v.length; i += 4) {
      final band = (v[i] / 50000).floor();
      lineBand[band] = (lineBand[band] ?? 0) + 1;
    }
  });
  print('=== DUVAR line segments by X band ===');
  final lk = lineBand.keys.toList()..sort();
  for (final k in lk) {
    print('x≈${k * 50}k: ${lineBand[k]}');
  }
}
