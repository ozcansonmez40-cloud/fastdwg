import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
String h(int c)=>'#${(c&0xFFFFFF).toRadixString(16).padLeft(6,"0")}';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  // 1) any green (debug) left?
  var green=0;
  s.lineBatches.forEach((k,v){ if(DwgScene.batchColor(k)==0x00FF00) green+=v.length~/4; });
  print('GREEN debug segments left (must be 0)=$green');
  // 2) table region: dup check on ALL segments + by color
  const cx=67688.0,cy=2900.0;
  final seen=<String>{}; var total=0,dup=0; final byColor=<int,int>{};
  s.lineBatches.forEach((k,v){
    final col=DwgScene.batchColor(k);
    for(var i=0;i+3<v.length;i+=4){
      final mx=(v[i]+v[i+2])/2,my=(v[i+1]+v[i+3])/2;
      if((mx-cx).abs()<700&&(my-cy).abs()<900){
        total++; byColor[col]=(byColor[col]??0)+1;
        final key='${v[i].toStringAsFixed(1)},${v[i+1].toStringAsFixed(1)},${v[i+2].toStringAsFixed(1)},${v[i+3].toStringAsFixed(1)}';
        if(!seen.add(key))dup++;
      }
    }
  });
  print('table total=$total unique=${seen.length} dup=$dup');
  final e=byColor.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));
  for(final x in e.take(5)){print('  ${h(x.key)}: ${x.value}');}
}
