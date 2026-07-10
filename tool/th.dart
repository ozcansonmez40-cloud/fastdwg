import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  for(final t in s.texts){
    final u=t.value.toUpperCase();
    if(u.contains('MARLIK')||u.contains('ASARIM')||u.contains('AKÜLT')||u.contains('BÖLÜM')||(u.contains('YY')&&u.contains('PROJE'))){
      print('h=${t.height.toStringAsFixed(1)} "${t.value}" @(${t.x.toStringAsFixed(0)},${t.y.toStringAsFixed(0)})');
    }
  }
}
