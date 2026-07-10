// Diagnostic: dump scene stats from a pulled last_scene.bin.
//   dart run tool/dump_scene_info.dart
import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';

String hex(int rgb) => '#${(rgb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

void main() {
  final bytes = File('tool/last_scene.bin').readAsBytesSync();
  final scene = DwgScene.fromBytes(bytes);

  print('version=${scene.dwgVersion} insUnits=${scene.insUnits} '
      'hasError=${scene.hasError}');
  print('lines=${scene.lineSegmentCount} circles=${scene.circleCount} '
      'texts=${scene.texts.length} fills=${scene.fills.length} '
      'dots=${scene.dotCount} layers=${scene.layers.length}');
  final b = scene.bounds;
  print('bounds: X[${b.minX.toStringAsFixed(1)} .. ${b.maxX.toStringAsFixed(1)}] '
      'Y[${b.minY.toStringAsFixed(1)} .. ${b.maxY.toStringAsFixed(1)}]  '
      'W=${(b.maxX - b.minX).toStringAsFixed(1)} H=${(b.maxY - b.minY).toStringAsFixed(1)}');
  print('');

  print('=== LAYERS ===');
  for (var i = 0; i < scene.layers.length; i++) {
    print('[$i] ${scene.layers[i].name}');
  }
  print('');

  // Line segments grouped by color, with the layers each color appears on.
  final byColor = <int, int>{}; // rgb -> segment count
  final colorLayers = <int, Set<int>>{};
  scene.lineBatches.forEach((key, verts) {
    final layer = DwgScene.batchLayer(key);
    final rgb = DwgScene.batchColor(key);
    final segs = verts.length ~/ 4;
    byColor[rgb] = (byColor[rgb] ?? 0) + segs;
    (colorLayers[rgb] ??= {}).add(layer);
  });

  print('=== LINE COLORS (segment count) ===');
  final entries = byColor.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in entries) {
    final layerNames = colorLayers[e.key]!
        .map((i) => i < scene.layers.length ? scene.layers[i].name : '?')
        .take(6)
        .join(', ');
    print('${hex(e.key).padRight(9)} segs=${e.value.toString().padLeft(7)}  '
        'layers: $layerNames');
  }
  print('');

  // Text color/layer distribution.
  print('=== TEXT sample (first 8) ===');
  for (var i = 0; i < scene.texts.length && i < 8; i++) {
    final t = scene.texts[i];
    print('  "${t.value}"');
  }
}
