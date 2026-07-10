// Analyze solid fills in a pulled scene: dart run tool/dump_fills.dart
import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';

void main() {
  final bytes = File('tool/last_scene.bin').readAsBytesSync();
  final scene = DwgScene.fromBytes(bytes);
  print('fills=${scene.fills.length} layers=${scene.layers.length}');

  // Group fills by colour; track count + bbox-diagonal stats + layers.
  final byColor = <int, List<double>>{};
  final colorLayers = <int, Set<int>>{};
  for (final f in scene.fills) {
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final loop in f.loops) {
      for (var i = 0; i + 1 < loop.length; i += 2) {
        final x = loop[i], y = loop[i + 1];
        if (!x.isFinite || !y.isFinite) continue;
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
    final diag = (maxX > minX && maxY > minY)
        ? ((maxX - minX) * (maxX - minX) + (maxY - minY) * (maxY - minY))
        : 0.0;
    (byColor[f.color] ??= []).add(diag > 0 ? diag : 0);
    (colorLayers[f.color] ??= {}).add(f.layer);
  }

  final entries = byColor.entries.toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));
  for (final e in entries) {
    final diags = e.value.where((d) => d > 0).map((d) => d).toList()..sort();
    final med = diags.isEmpty ? 0.0 : diags[diags.length ~/ 2];
    final layerNames = colorLayers[e.key]!
        .map((i) => i < scene.layers.length ? scene.layers[i].name : '?')
        .take(4)
        .join(',');
    print('color=#${e.key.toRadixString(16).padLeft(6, '0')} '
        'count=${e.value.length} medDiag=${med == 0 ? 0 : med.toStringAsFixed(0)} '
        'layers=[$layerNames]');
  }
}
