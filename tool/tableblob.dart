import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
String h(int c)=>'#${(c&0xFFFFFF).toRadixString(16).padLeft(6,"0")}';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  for(final loc in [[-378.0,2602.0],[67688.0,2602.0]]){
    final cx=loc[0],cy=loc[1];
    print('=== fills near TABLE ($cx,$cy) sorted by size ===');
    final rows=<List<dynamic>>[];
    for(var fi=0;fi<s.fills.length;fi++){
      final f=s.fills[fi];
      double x0=1e30,y0=1e30,x1=-1e30,y1=-1e30;
      for(final lp in f.loops){for(var i=0;i+1<lp.length;i+=2){if(lp[i]<x0)x0=lp[i];if(lp[i]>x1)x1=lp[i];if(lp[i+1]<y0)y0=lp[i+1];if(lp[i+1]>y1)y1=lp[i+1];}}
      final mx=(x0+x1)/2,my=(y0+y1)/2;
      if((mx-cx).abs()<2000&&(my-cy).abs()<2500){
        rows.add([fi,f.color,f.loops.length,x1-x0,y1-y0,f.layer<s.layers.length?s.layers[f.layer].name:"?"]);
      }
    }
    rows.sort((a,b)=>((b[3]as double)*(b[4]as double)).compareTo((a[3]as double)*(a[4]as double)));
    for(final r in rows.take(10)){print('  fill#${r[0]} ${h(r[1]as int)} loops=${r[2]} bbox=${(r[3]as double).toStringAsFixed(0)}x${(r[4]as double).toStringAsFixed(0)} layer=${r[5]}');}
    print('  total=${rows.length}');
  }
}
