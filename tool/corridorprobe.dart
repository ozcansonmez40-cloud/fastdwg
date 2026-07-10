import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
String h(int c)=>'#${(c&0xFFFFFF).toRadixString(16).padLeft(6,"0")}';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  // corridor phantom clusters at y~2300-2400, across building width
  const y0=2280.0,y1=2430.0,x0=66400.0,x1=68400.0;
  final byLayer=<int,int>{}; final xs=<double>[];
  s.lineBatches.forEach((k,v){
    final lay=DwgScene.batchLayer(k);
    for(var i=0;i+3<v.length;i+=4){
      final mx=(v[i]+v[i+2])/2,my=(v[i+1]+v[i+3])/2;
      if(mx>x0&&mx<x1&&my>y0&&my<y1){ byLayer[lay]=(byLayer[lay]??0)+1; xs.add(mx); }
    }
  });
  print('corridor segs by layer:');
  final e=byLayer.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));
  for(final x in e){final n=x.key<s.layers.length?s.layers[x.key].name:'?'; print('  $n[${x.key}] ${h(s.layers[x.key].color)} vis=${s.layers[x.key].visible}: ${x.value}');}
  // cluster x centers
  xs.sort();
  if(xs.isNotEmpty){
    final clusters=<double>[]; double cur=xs.first; var cnt=0; double sum=0;
    for(final x in xs){ if(x-cur>80){ clusters.add(sum/cnt); cur=x; sum=0; cnt=0;} sum+=x; cnt++; cur=x; }
    if(cnt>0)clusters.add(sum/cnt);
    print('cluster x-centers(approx): ${clusters.map((c)=>c.toStringAsFixed(0)).toList()}');
  }
  // Also list ALL layer names + visibility to spot a furniture/detail layer AutoCAD freezes
  print('--- all layers vis=false ---');
  for(var i=0;i<s.layers.length;i++){ if(!s.layers[i].visible) print('  HIDDEN ${s.layers[i].name}[$i]'); }
}
