// Segment totals per layer.
//   dart run tool/layer_totals.dart
import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';

void main() {
  final bytes = File('tool/last_scene.bin').readAsBytesSync();
  final scene = DwgScene.fromBytes(bytes);
  final total = <int, int>{};
  scene.lineBatches.forEach((key, v) {
    final layer = DwgScene.batchLayer(key);
    total[layer] = (total[layer] ?? 0) + v.length ~/ 4;
  });
  final e = total.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  for (final x in e.take(12)) {
    final nm = x.key < scene.layers.length ? scene.layers[x.key].name : '?';
    print('$nm: ${x.value}');
  }
}
