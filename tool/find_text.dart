// Find text entities matching a substring, print their world positions.
//   dart run tool/find_text.dart SIRKUL
import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';

void main(List<String> a) {
  final scene =
      DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  final needle = a.isNotEmpty ? a[0].toUpperCase() : 'SIRK';
  var n = 0;
  for (final t in scene.texts) {
    if (t.value.toUpperCase().contains(needle)) {
      print('"${t.value}" @ (${t.x.toStringAsFixed(0)},${t.y.toStringAsFixed(0)})');
      if (++n > 20) break;
    }
  }
  if (n == 0) print('no match for "$needle"');
}
