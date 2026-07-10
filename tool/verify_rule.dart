import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  for(final fi in [685,686,351,1013,6,344]){
    final f=s.fills[fi];
    int small=0;
    for(final lp in f.loops){
      double x0=1e30,y0=1e30,x1=-1e30,y1=-1e30;
      for(var i=0;i+1<lp.length;i+=2){if(lp[i]<x0)x0=lp[i];if(lp[i]>x1)x1=lp[i];if(lp[i+1]<y0)y0=lp[i+1];if(lp[i+1]>y1)y1=lp[i+1];}
      final d=(( x1-x0)*(x1-x0)+(y1-y0)*(y1-y0));
      if(d<300*300)small++;
    }
    final frac=small/f.loops.length;
    print('fill#$fi loops=${f.loops.length} small=$small frac=${frac.toStringAsFixed(2)} -> ${frac>=0.6?"SKIP(text)":"FILL(wall)"}');
  }
}
