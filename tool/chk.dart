import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  print('lines=${s.lineSegmentCount} fills=${s.fills.length} texts=${s.texts.length}');
  // find TOPLANTI text
  for(final t in s.texts){ if(t.value.toUpperCase().contains('TOPLANT')){ print('TOPLANTI @(${t.x.toStringAsFixed(0)},${t.y.toStringAsFixed(0)})'); } }
}
