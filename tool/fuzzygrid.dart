import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  const minX=68000.0,maxX=68760.0,minY=2400.0,maxY=3060.0;
  const gx=8,gy=8;
  final cw=(maxX-minX)/gx, ch=(maxY-minY)/gy;
  // per-cell: collect tefrişler segments, compute connectivity
  final cells=List.generate(gx*gy,(_)=>[<double>[]][0]==null?<List<double>>[]:<List<double>>[]);
  final buckets=List.generate(gx*gy,(_)=><List<double>>[]);
  s.lineBatches.forEach((k,v){
    final lay=DwgScene.batchLayer(k);
    final n=lay<s.layers.length?s.layers[lay].name.toLowerCase():'';
    if(!n.contains('tefri')) return;
    for(var i=0;i+3<v.length;i+=4){
      final mx=(v[i]+v[i+2])/2,my=(v[i+1]+v[i+3])/2;
      if(mx<minX||mx>=maxX||my<minY||my>=maxY) continue;
      final cx=((mx-minX)/cw).floor().clamp(0,gx-1);
      final cy=((my-minY)/ch).floor().clamp(0,gy-1);
      buckets[cy*gx+cx].add([v[i],v[i+1],v[i+2],v[i+3]]);
    }
  });
  String q(double a)=>(a*4).round().toString();
  print('cell(col,row)  x,y            segs  conn%');
  for(var r=0;r<gy;r++){for(var c=0;c<gx;c++){
    final segs=buckets[r*gx+c]; if(segs.length<50) continue;
    final ends=<String,int>{};
    for(final g in segs){ ends['${q(g[0])},${q(g[1])}']=(ends['${q(g[0])},${q(g[1])}']??0)+1; ends['${q(g[2])},${q(g[3])}']=(ends['${q(g[2])},${q(g[3])}']??0)+1; }
    var conn=0; for(final g in segs){ if((ends['${q(g[0])},${q(g[1])}']??0)>1 && (ends['${q(g[2])},${q(g[3])}']??0)>1) conn++; }
    final ax=(minX+(c+0.5)*cw).toStringAsFixed(0), ay=(minY+(r+0.5)*ch).toStringAsFixed(0);
    print('($c,$r)  $ax,$ay   ${segs.length.toString().padLeft(5)}  ${(conn*100~/segs.length).toString().padLeft(3)}%');
  }}
}
