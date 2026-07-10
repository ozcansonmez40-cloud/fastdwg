import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
String h(int c)=>'#${(c&0xFFFFFF).toRadixString(16).padLeft(6,"0")}';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  for(var i=0;i<s.layers.length;i++){
    final n=s.layers[i].name.toUpperCase();
    if(n.contains('DUVAR')||n.contains('TARAMA')||n.contains('DOSEME')||n=='0'){
      print('layer[$i] "${s.layers[i].name}" color=${h(s.layers[i].color)}');
    }
  }
  final f=s.fills[351];
  print('fill#351 color=${h(f.color)} layer=${f.layer}(${f.layer<s.layers.length?s.layers[f.layer].name:"?"})');
  // total fills by color across whole scene
  final byc=<int,int>{};
  for(final x in s.fills){byc[x.color]=(byc[x.color]??0)+1;}
  final e=byc.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));
  print('--- all fills by color ---');
  for(final x in e.take(8)){print('${h(x.key)}: ${x.value}');}
}
