import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  for(final t in s.texts){
    final u=t.value.toUpperCase();
    if(u.contains('TATIL')||u.contains('TATİL')||u.contains('PROJE')||u.contains('MIMAR')||u.contains('MİMAR')||u.contains('FAK')||u.contains('YY')){
      print('"${t.value}" @(${t.x.toStringAsFixed(0)},${t.y.toStringAsFixed(0)}) h=${t.height.toStringAsFixed(0)}');
    }
  }
}
