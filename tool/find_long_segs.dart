// Diagnostic: mid-length "chord" segments by layer (diagonal-artifact hunt).
//   dart run tool/find_long_segs.dart
import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';

void main() {
  final bytes = File('tool/last_scene.bin').readAsBytesSync();
  final scene = DwgScene.fromBytes(bytes);
  print('lines=${scene.lineSegmentCount} layers=${scene.layers.length}');

  // Chord suspects: 10k..400k units long. For each layer: how many, and the
  // total vs long ratio (a contour layer should have ~zero long straights).
  final total = <int, int>{};
  final long = <int, int>{};
  final samples = <int, List<String>>{};

  scene.lineBatches.forEach((key, v) {
    final layer = DwgScene.batchLayer(key);
    for (var i = 0; i + 3 < v.length; i += 4) {
      final dx = v[i + 2] - v[i], dy = v[i + 3] - v[i + 1];
      final len2 = dx * dx + dy * dy;
      total[layer] = (total[layer] ?? 0) + 1;
      if (len2 >= 10000 * 10000 && len2 <= 400000.0 * 400000.0) {
        long[layer] = (long[layer] ?? 0) + 1;
        final s = samples[layer] ??= [];
        if (s.length < 3) {
          s.add('(${v[i].toStringAsFixed(0)},${v[i + 1].toStringAsFixed(0)})->'
              '(${v[i + 2].toStringAsFixed(0)},${v[i + 3].toStringAsFixed(0)})');
        }
      }
    }
  });

  final le = long.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  print('=== segments 10k-400k units long, by layer ===');
  for (final e in le.take(15)) {
    final nm = e.key < scene.layers.length ? scene.layers[e.key].name : '?';
    print('$nm: long=${e.value} / total=${total[e.key]}  '
        'ex: ${samples[e.key]!.join(' ; ')}');
  }
}
