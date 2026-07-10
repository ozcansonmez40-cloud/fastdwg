import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
String h(int c)=>'#${(c&0xFFFFFF).toRadixString(16).padLeft(6,"0")}';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  const x0=61000.0,y0=-90000.0,x1=70000.0,y1=-82000.0;
  final byLayer=<int,int>{};
  s.lineBatches.forEach((k,v){
    final ly=DwgScene.batchLayer(k);
    for(var i=0;i+3<v.length;i+=4){
      final cx=(v[i]+v[i+2])/2,cy=(v[i+1]+v[i+3])/2;
      if(cx>=x0&&cx<=x1&&cy>=y0&&cy<=y1){byLayer[ly]=(byLayer[ly]??0)+1;}
    }
  });
  final e=byLayer.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));
  print('=== line segments in stairwell region by layer ===');
  for(final x in e.take(20)){
    final nm=x.key<s.layers.length?s.layers[x.key].name:'?';
    print('$nm (${h(x.key<s.layers.length?s.layers[x.key].color:0)}): ${x.value}');
  }
}
