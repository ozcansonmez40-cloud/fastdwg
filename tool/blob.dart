import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
String h(int c)=>'#${(c&0xFFFFFF).toRadixString(16).padLeft(6,"0")}';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  // salmon #bd7e7e fills: how many loops, bbox size — blob(1 big loop) vs band(2)
  var n=0,big=0;
  for(var fi=0;fi<s.fills.length;fi++){
    final f=s.fills[fi];
    if((f.color&0xFFFFFF)!=0xbd7e7e)continue;
    n++;
    double x0=1e30,y0=1e30,x1=-1e30,y1=-1e30;
    for(final lp in f.loops){for(var i=0;i+1<lp.length;i+=2){if(lp[i]<x0)x0=lp[i];if(lp[i]>x1)x1=lp[i];if(lp[i+1]<y0)y0=lp[i+1];if(lp[i+1]>y1)y1=lp[i+1];}}
    final w=x1-x0,hh=y1-y0;
    if(w>300||hh>300){big++; if(big<=12)print('fill#$fi loops=${f.loops.length} bbox=${w.toStringAsFixed(0)}x${hh.toStringAsFixed(0)} @(${((x0+x1)/2).toStringAsFixed(0)},${((y0+y1)/2).toStringAsFixed(0)}) layer=${f.layer<s.layers.length?s.layers[f.layer].name:"?"}');}
  }
  print('total #bd7e7e fills=$n  big(>300)=$big');
}
