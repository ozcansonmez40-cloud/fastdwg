import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  // fuzzy chair ~ (68087, 2832); clean chair ~ (68106, 2688)
  void probe(String tag, double cx, double cy){
    final segs=<List<double>>[];
    s.lineBatches.forEach((k,v){
      final lay=DwgScene.batchLayer(k);
      final n=lay<s.layers.length?s.layers[lay].name.toLowerCase():'';
      if(!n.contains('tefri')) return;
      for(var i=0;i+3<v.length;i+=4){
        final mx=(v[i]+v[i+2])/2,my=(v[i+1]+v[i+3])/2;
        if((mx-cx).abs()<40&&(my-cy).abs()<40){
          segs.add([v[i],v[i+1],v[i+2],v[i+3]]);
        }
      }
    });
    // stats: count, length histogram, and endpoint-connectivity (how many segs
    // share an endpoint with another — a smooth outline has ~2 neighbours each)
    var conn=0; final ends=<String,int>{};
    String q(double a)=>(a*4).round().toString();
    for(final g in segs){ ends['${q(g[0])},${q(g[1])}']=(ends['${q(g[0])},${q(g[1])}']??0)+1; ends['${q(g[2])},${q(g[3])}']=(ends['${q(g[2])},${q(g[3])}']??0)+1; }
    for(final g in segs){ if((ends['${q(g[0])},${q(g[1])}']??0)>1 && (ends['${q(g[2])},${q(g[3])}']??0)>1) conn++; }
    var tiny=0; double maxL=0; for(final g in segs){ final l=(g[0]-g[2]).abs()+(g[1]-g[3]).abs(); if(l<2)tiny++; if(l>maxL)maxL=l; }
    // ignore: avoid_print
    print('$tag: segs=${segs.length} tiny(<2)=$tiny maxLen=${maxL.toStringAsFixed(1)} connected(both ends shared)=$conn (${segs.isEmpty?0:(conn*100~/segs.length)}%)');
  }
  probe('FUZZY', 68087, 2832);
  probe('CLEAN', 68106, 2688);
}
