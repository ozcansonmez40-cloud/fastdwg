// List all solid fills whose bbox intersects a region, grouped by color+layer.
//   dart run tool/region_fills.dart minX minY maxX maxY
import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';

void main(List<String> a) {
  final scene =
      DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  final rx0 = double.parse(a[0]),
      ry0 = double.parse(a[1]),
      rx1 = double.parse(a[2]),
      ry1 = double.parse(a[3]);
  final byCL = <String, int>{};
  var total = 0;
  for (final f in scene.fills) {
    double x0 = 1e30, y0 = 1e30, x1 = -1e30, y1 = -1e30;
    for (final loop in f.loops) {
      for (var i = 0; i + 1 < loop.length; i += 2) {
        if (loop[i] < x0) x0 = loop[i];
        if (loop[i] > x1) x1 = loop[i];
        if (loop[i + 1] < y0) y0 = loop[i + 1];
        if (loop[i + 1] > y1) y1 = loop[i + 1];
      }
    }
    if (x1 < rx0 || x0 > rx1 || y1 < ry0 || y0 > ry1) continue;
    total++;
    final ln = f.layer < scene.layers.length ? scene.layers[f.layer].name : '?';
    final k = '#${(f.color & 0xFFFFFF).toRadixString(16).padLeft(6, '0')} $ln';
    byCL[k] = (byCL[k] ?? 0) + 1;
  }
  print('fills in region=$total');
  final e = byCL.entries.toList()..sort((x, y) => y.value.compareTo(x.value));
  for (final x in e) {
    print('  ${x.key}: ${x.value}');
  }
}
