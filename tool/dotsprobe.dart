import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
String h(int c)=>'#${(c&0xFFFFFF).toRadixString(16).padLeft(6,"0")}';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  // sofa cluster with scattered dots ~ (68213, 2738)
  const cx=68300.0,cy=2760.0,r=420.0;
  // 1) DOT/DASHDOT marks
  var dots=0; final dcol=<int,int>{}; final dlay=<int,int>{};
  for(var i=0;i<s.dotCount;i++){
    final x=s.dotCoords[i*2],y=s.dotCoords[i*2+1];
    if((x-cx).abs()<r&&(y-cy).abs()<r){dots++; dcol[s.dotColors[i]]=(dcol[s.dotColors[i]]??0)+1; dlay[s.dotLayers[i]]=(dlay[s.dotLayers[i]]??0)+1;}
  }
  print('DOT marks in region=$dots');
  dcol.forEach((k,v)=>print('  dotcol ${h(k)}: $v'));
  dlay.forEach((k,v){final n=k<s.layers.length?s.layers[k].name:'?'; print('  dotlayer $n[$k]: $v');});
  // 2) tiny circles
  var tinyC=0,bigC=0; final clay=<int,int>{};
  for(var i=0;i<s.circleCount;i++){
    final x=s.circleCoords[i*3],y=s.circleCoords[i*3+1],rad=s.circleCoords[i*3+2];
    if((x-cx).abs()<r&&(y-cy).abs()<r){ if(rad<3){tinyC++; final l=s.circleLayers[i]; clay[l]=(clay[l]??0)+1;} else bigC++; }
  }
  print('circles in region: tiny(r<3)=$tinyC big=$bigC');
  clay.forEach((k,v){final n=k<s.layers.length?s.layers[k].name:'?'; print('  tinyCircLayer $n[$k]: $v');});
  // 3) tiny segments
  var tinyS=0,total=0; final slay=<int,int>{};
  s.lineBatches.forEach((k,v){
    final lay=DwgScene.batchLayer(k);
    for(var i=0;i+3<v.length;i+=4){
      final mx=(v[i]+v[i+2])/2,my=(v[i+1]+v[i+3])/2;
      if((mx-cx).abs()<r&&(my-cy).abs()<r){ total++;
        final len=((v[i]-v[i+2]).abs()+(v[i+1]-v[i+3]).abs());
        if(len<3){tinyS++; slay[lay]=(slay[lay]??0)+1;}
      }
    }
  });
  print('segments in region total=$total tiny(<3)=$tinyS');
  final se=slay.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));
  for(final e in se.take(6)){final n=e.key<s.layers.length?s.layers[e.key].name:'?'; print('  tinySegLayer $n[${e.key}]: ${e.value}');}
}
