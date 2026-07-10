import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
String h(int c)=>'#${(c&0xFFFFFF).toRadixString(16).padLeft(6,"0")}';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  // A-A KESİTİ area near (-2977,-83022) and ÖLÇEK (-4015,-88544)
  for(final loc in [[-3500.0,-85500.0],[65500.0,-85500.0]]){
    final cx=loc[0],cy=loc[1];
    print('=== fills near title block ($cx,$cy) ===');
    var n=0;
    for(var fi=0;fi<s.fills.length;fi++){
      final f=s.fills[fi];
      double x0=1e30,y0=1e30,x1=-1e30,y1=-1e30;
      for(final lp in f.loops){for(var i=0;i+1<lp.length;i+=2){if(lp[i]<x0)x0=lp[i];if(lp[i]>x1)x1=lp[i];if(lp[i+1]<y0)y0=lp[i+1];if(lp[i+1]>y1)y1=lp[i+1];}}
      final mx=(x0+x1)/2,my=(y0+y1)/2;
      if((mx-cx).abs()<6000&&(my-cy).abs()<8000){
        n++;
        if(n<=20)print('  fill#$fi ${h(f.color)} loops=${f.loops.length} bbox=${(x1-x0).toStringAsFixed(0)}x${(y1-y0).toStringAsFixed(0)} @(${mx.toStringAsFixed(0)},${my.toStringAsFixed(0)}) layer=${f.layer<s.layers.length?s.layers[f.layer].name:"?"}');
      }
    }
    print('  totalFills=$n');
  }
}
