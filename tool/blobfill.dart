import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
String h(int c)=>'#${(c&0xFFFFFF).toRadixString(16).padLeft(6,"0")}';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  // blob center ~ (67688, 2900). Find fills whose bbox overlaps that room.
  const rMinX=67300.0,rMaxX=68100.0,rMinY=2400.0,rMaxY=3400.0;
  print('layers:');
  for(var i=0;i<s.layers.length;i++){ final l=s.layers[i]; if(l.name.toLowerCase().contains('tefri')||l.name.toLowerCase().contains('mob')) print('  [$i] ${l.name} ${h(l.color)}'); }
  print('total fills=${s.fills.length}');
  var n=0;
  for(final f in s.fills){
    if(f.maxX<rMinX||f.minX>rMaxX||f.maxY<rMinY||f.minY>rMaxY) continue;
    final w=f.maxX-f.minX, ht=f.maxY-f.minY;
    var pts=0; for(final lp in f.loops) pts+=lp.length~/2;
    final lname=f.layer<s.layers.length?s.layers[f.layer].name:'?';
    print('fill#$n col=${h(f.color)} layer=$lname[${f.layer}] loops=${f.loops.length} pts=$pts bbox=${w.toStringAsFixed(0)}x${ht.toStringAsFixed(0)} at(${f.minX.toStringAsFixed(0)},${f.minY.toStringAsFixed(0)})');
    n++;
    if(n>40) {print('...more'); break;}
  }
}
