import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  var n=0;
  for(final t in s.texts){
    final u=t.value.toUpperCase();
    if(u.contains('PLANT')||u.contains('PLANTI')||u.contains('TOPLAN')){
      print('"${t.value}" @(${t.x.toStringAsFixed(0)},${t.y.toStringAsFixed(0)})');
      if(++n>10)break;
    }
  }
  print('matches=$n totalTexts=${s.texts.length}');
}
