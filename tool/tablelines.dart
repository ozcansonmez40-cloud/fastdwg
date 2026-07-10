import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
String h(int c)=>'#${(c&0xFFFFFF).toRadixString(16).padLeft(6,"0")}';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  const cx=67688.0,cy=2900.0;
  final byLayer=<int,int>{}; final byColor=<int,int>{};
  var maxlen=0.0; String longest='';
  s.lineBatches.forEach((k,v){
    final ly=DwgScene.batchLayer(k); final col=DwgScene.batchColor(k);
    for(var i=0;i+3<v.length;i+=4){
      final mx=(v[i]+v[i+2])/2,my=(v[i+1]+v[i+3])/2;
      if((mx-cx).abs()<700&&(my-cy).abs()<900){
        byLayer[ly]=(byLayer[ly]??0)+1;
        byColor[col]=(byColor[col]??0)+1;
      }
    }
  });
  print('=== line segs near TABLE by layer ===');
  final e=byLayer.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));
  for(final x in e.take(8)){print('${x.key<s.layers.length?s.layers[x.key].name:"?"}: ${x.value}');}
  print('=== by color ===');
  final e2=byColor.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));
  for(final x in e2.take(6)){print('${h(x.key)}: ${x.value}');}
}
