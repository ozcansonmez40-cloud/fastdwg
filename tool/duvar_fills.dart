import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  var duvar=-1;
  for(var i=0;i<s.layers.length;i++){if(s.layers[i].name.toUpperCase()=='DUVAR')duvar=i;}
  // For each DUVAR fill: bbox, and the MIN loop thickness (min bbox side of any loop)
  var wide=0;
  for(var fi=0;fi<s.fills.length;fi++){
    final f=s.fills[fi];
    if(f.layer!=duvar)continue;
    double X0=1e30,Y0=1e30,X1=-1e30,Y1=-1e30;
    double minThick=1e30;
    for(final lp in f.loops){
      double x0=1e30,y0=1e30,x1=-1e30,y1=-1e30;
      for(var i=0;i+1<lp.length;i+=2){if(lp[i]<x0)x0=lp[i];if(lp[i]>x1)x1=lp[i];if(lp[i+1]<y0)y0=lp[i+1];if(lp[i+1]>y1)y1=lp[i+1];}
      X0=x0<X0?x0:X0;Y0=y0<Y0?y0:Y0;X1=x1>X1?x1:X1;Y1=y1>Y1?y1:Y1;
      final t=(x1-x0)<(y1-y0)?(x1-x0):(y1-y0);
      if(t<minThick)minThick=t;
    }
    final w=X1-X0,h=Y1-Y0;
    if(w>800||h>800){ // wall-band sized hatches
      wide++;
      if(wide<=25)print('fill#$fi loops=${f.loops.length} bbox=${w.toStringAsFixed(0)}x${h.toStringAsFixed(0)} @(${((X0+X1)/2).toStringAsFixed(0)},${((Y0+Y1)/2).toStringAsFixed(0)}) minLoopThick=${minThick.toStringAsFixed(1)}');
    }
  }
  print('total wide DUVAR fills=$wide');
}
