import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';
double area(List<double> l){var a=0.0;for(var i=0;i+3<l.length;i+=2){a+=l[i]*l[i+3]-l[i+2]*l[i+1];}return a.abs()/2;}
void main(){
  final s=DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
  for(final idx in [351,1008]){
    final f=s.fills[idx];var tot=0.0;final per=<String>[];
    for(final lp in f.loops){final a=area(lp);tot+=a;per.add(a.toStringAsFixed(0));}
    print('fill#$idx loops=${f.loops.length} sumArea=${tot.toStringAsFixed(0)} perLoop=${per.join(",")}');
  }
}
