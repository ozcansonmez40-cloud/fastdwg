import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  final needles=['TASARIM','FAK','BÖLÜM','BOLUM','MIMAR','MİMAR','ÜNİVERS','UNIVERS','YYÜ','YYU'];
  var found=0;
  for(final t in s.texts){
    final u=t.value.toUpperCase();
    for(final nd in needles){ if(u.contains(nd)){ print('MATCH[$nd] "${t.value}" @(${t.x.toStringAsFixed(0)},${t.y.toStringAsFixed(0)})'); found++; break; } }
  }
  print('bigtitle fragments found=$found');
  // Also: does any text contain lowercase dotted i vs check a known one
  for(final t in s.texts){ if(t.value.contains('KESİT')||t.value.contains('KESIT')){ print('sample: "${t.value}" bytes=${t.value.codeUnits}'); break; } }
}
