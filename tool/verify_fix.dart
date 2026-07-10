import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
String h(int c)=>'#${(c&0xFFFFFF).toRadixString(16).padLeft(6,"0")}';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  print('total fills=${s.fills.length}');
  // 1) title box: any big gray #505050 fill near (-2338,-87468)?
  var titleBox=0, wallFills=0;
  for(final f in s.fills){
    double x0=1e30,y0=1e30,x1=-1e30,y1=-1e30;
    for(final lp in f.loops){for(var i=0;i+1<lp.length;i+=2){if(lp[i]<x0)x0=lp[i];if(lp[i]>x1)x1=lp[i];if(lp[i+1]<y0)y0=lp[i+1];if(lp[i+1]>y1)y1=lp[i+1];}}
    final w=x1-x0,hh=y1-y0;
    // big gray box (title mask)
    if((f.color&0xFFFFFF)==0x505050 && w>5000 && hh>5000) titleBox++;
    // wall poché (DUVAR red, wide)
    if((f.color&0xFFFFFF)==0xff0000 && (w>800||hh>800)) wallFills++;
  }
  print('BIG GRAY title-mask fills remaining (should be 0)=$titleBox');
  print('DUVAR wall fills (should be >0, ~23)=$wallFills');
}
