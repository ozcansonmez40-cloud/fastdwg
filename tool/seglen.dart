import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  const cx=67688.0,cy=2900.0;
  final buckets=<String,int>{'<1':0,'1-5':0,'5-20':0,'20-100':0,'>100':0};
  var minx=1e30,miny=1e30,maxx=-1e30,maxy=-1e30;
  s.lineBatches.forEach((k,v){
    if(DwgScene.batchColor(k)!=0xbd7e7e)return;
    for(var i=0;i+3<v.length;i+=4){
      final mx=(v[i]+v[i+2])/2,my=(v[i+1]+v[i+3])/2;
      if((mx-cx).abs()<700&&(my-cy).abs()<900){
        final dx=v[i+2]-v[i],dy=v[i+3]-v[i+1];
        final l=(dx*dx+dy*dy);
        if(l<1)buckets['<1']=buckets['<1']!+1;
        else if(l<25)buckets['1-5']=buckets['1-5']!+1;
        else if(l<400)buckets['5-20']=buckets['5-20']!+1;
        else if(l<10000)buckets['20-100']=buckets['20-100']!+1;
        else buckets['>100']=buckets['>100']!+1;
        for(final x in [v[i],v[i+2]]){if(x<minx)minx=x;if(x>maxx)maxx=x;}
        for(final y in [v[i+1],v[i+3]]){if(y<miny)miny=y;if(y>maxy)maxy=y;}
      }
    }
  });
  print('segment length buckets (salmon @table): $buckets');
  print('actual extent: ${(maxx-minx).toStringAsFixed(0)} x ${(maxy-miny).toStringAsFixed(0)} @ (${minx.toStringAsFixed(0)},${miny.toStringAsFixed(0)})');
}
