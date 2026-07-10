import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
double area(List<double> l){var a=0.0;for(var i=0;i+3<l.length;i+=2){a+=l[i]*l[i+3]-l[i+2]*l[i+1];}return a.abs()/2;}
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  // even-odd net area ~ we approximate by summing signed loop areas
  for(var fi=0;fi<s.fills.length;fi++){
    final f=s.fills[fi];
    var sum=0.0;
    for(final lp in f.loops){var a=0.0;for(var i=0;i+3<lp.length;i+=2){a+=lp[i]*lp[i+3]-lp[i+2]*lp[i+1];}sum+=a;}
    final net=sum.abs()/2;
    if(net>650000 && net<750000){
      double x0=1e30,y0=1e30,x1=-1e30,y1=-1e30;
      for(final lp in f.loops){for(var i=0;i+1<lp.length;i+=2){if(lp[i]<x0)x0=lp[i];if(lp[i]>x1)x1=lp[i];if(lp[i+1]<y0)y0=lp[i+1];if(lp[i+1]>y1)y1=lp[i+1];}}
      print('fill#$fi netArea=${net.toStringAsFixed(0)} loops=${f.loops.length} layer=${f.layer<s.layers.length?s.layers[f.layer].name:"?"} bbox=(${x0.toStringAsFixed(0)},${y0.toStringAsFixed(0)})-(${x1.toStringAsFixed(0)},${y1.toStringAsFixed(0)})');
    }
  }
}
