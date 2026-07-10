import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
String h(int c)=>'#${(c&0xFFFFFF).toRadixString(16).padLeft(6,"0")}';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  // Group solid fills by layer name; report count + median bbox diag + color.
  final byLayer=<String,List<double>>{}; // diag list
  final colOf=<String,int>{}; final cntOf=<String,int>{};
  for(final f in s.fills){
    final lname=f.layer<s.layers.length?s.layers[f.layer].name:'?';
    final w=f.maxX-f.minX, ht=f.maxY-f.minY;
    if(!w.isFinite||!ht.isFinite) continue;
    final diag=(w*w+ht*ht);
    (byLayer[lname]??=[]).add(diag);
    colOf[lname]=f.color; cntOf[lname]=(cntOf[lname]??0)+1;
  }
  final ent=byLayer.entries.toList()..sort((a,b)=>b.value.length.compareTo(a.value.length));
  print('layer                         count  medDiag  color');
  for(final e in ent){
    final v=e.value..sort();
    final med=v[v.length~/2];
    print('${e.key.padRight(28)} ${e.value.length.toString().padLeft(6)}  ${(med>0?med:0).toStringAsFixed(0).padLeft(7)}  ${h(colOf[e.key]!)}');
  }
}
