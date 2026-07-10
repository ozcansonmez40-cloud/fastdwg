import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  const cx=67688.0,cy=2900.0;
  final seen=<String>{}; var total=0,dup=0;
  s.lineBatches.forEach((k,v){
    if(DwgScene.batchColor(k)!=0xbd7e7e)return;
    for(var i=0;i+3<v.length;i+=4){
      final mx=(v[i]+v[i+2])/2,my=(v[i+1]+v[i+3])/2;
      if((mx-cx).abs()<700&&(my-cy).abs()<900){
        total++;
        final key='${v[i].toStringAsFixed(1)},${v[i+1].toStringAsFixed(1)},${v[i+2].toStringAsFixed(1)},${v[i+3].toStringAsFixed(1)}';
        if(!seen.add(key))dup++;
      }
    }
  });
  print('total=$total unique=${seen.length} duplicates=$dup');
}
