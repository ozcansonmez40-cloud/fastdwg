import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
String h(int c)=>'#${(c&0xFFFFFF).toRadixString(16).padLeft(6,"0")}';
void dumpFills(DwgScene s,double cx,double cy,double r,String tag){
  print('=== fills near $tag ($cx,$cy) r=$r ===');
  var n=0;
  for(var fi=0;fi<s.fills.length;fi++){
    final f=s.fills[fi];
    double x0=1e30,y0=1e30,x1=-1e30,y1=-1e30;
    for(final lp in f.loops){for(var i=0;i+1<lp.length;i+=2){if(lp[i]<x0)x0=lp[i];if(lp[i]>x1)x1=lp[i];if(lp[i+1]<y0)y0=lp[i+1];if(lp[i+1]>y1)y1=lp[i+1];}}
    final mx=(x0+x1)/2,my=(y0+y1)/2;
    if((mx-cx).abs()<r&&(my-cy).abs()<r){
      n++;
      if(n<=15)print('  fill#$fi ${h(f.color)} loops=${f.loops.length} bbox=${(x1-x0).toStringAsFixed(0)}x${(y1-y0).toStringAsFixed(0)} layer=${f.layer<s.layers.length?s.layers[f.layer].name:"?"}');
    }
  }
  print('  totalFills=$n');
}
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  dumpFills(s,-378,2602,1500,'TABLE');
  // find title texts
  for(final t in s.texts){
    final u=t.value.toUpperCase();
    if(u.contains('KES')||u.contains('GÖRÜN')||u.contains('GORUN')||u.contains('ÖLÇEK')||u.contains('OLCEK')){
      print('TITLE "${t.value}" @(${t.x.toStringAsFixed(0)},${t.y.toStringAsFixed(0)})');
    }
  }
}
