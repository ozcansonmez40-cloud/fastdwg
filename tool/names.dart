import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  // Names list (Dr. / Arş. Gör.) - should be left-aligned column
  final rows=<List<dynamic>>[];
  for(final t in s.texts){
    final u=t.value.toUpperCase();
    if(u.contains('DR.')||u.contains('ÖĞR')||u.contains('ARŞ')||u.contains('GÖR')||u.contains('ÖZTÜRK')||u.contains('KANAN')||u.contains('BÜK')){
      rows.add([t.x,t.y,t.height,t.anchor,t.value]);
    }
  }
  rows.sort((a,b)=>(b[1]as double).compareTo(a[1]as double));
  for(final r in rows.take(14)){print('x=${(r[0]as double).toStringAsFixed(1)} y=${(r[1]as double).toStringAsFixed(1)} h=${(r[2]as double).toStringAsFixed(0)} anc=${r[3]} "${r[4]}"');}
}
