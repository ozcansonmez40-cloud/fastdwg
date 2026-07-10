import 'dart:io';
import 'dart:typed_data';
String h(int c)=>'#${(c&0xFFFFFF).toRadixString(16).padLeft(6,"0")}';
// Read RAW fills (before the furniture-drop) straight from the FDW5 buffer.
void main(){
  final bytes=File('tool/last_scene.bin').readAsBytesSync();
  final bd=ByteData.sublistView(bytes);
  int o=0; o+=4; // magic
  o+=4; // err
  o+=16; // bounds
  final vlen=bd.getUint16(o,Endian.little); o+=2+vlen;
  o+=2; // insunits
  o+=4; // entitycount
  final lc2=bd.getUint16(o,Endian.little); o+=2;
  final names=<String>[];
  for(var i=0;i<lc2;i++){ final nl=bd.getUint16(o,Endian.little); o+=2; names.add(utf8dec(bytes,o,nl)); o+=nl; o+=7; }
  // lines
  final lineCount=bd.getUint32(o,Endian.little); o+=4;
  const stride=22;
  // desk keyboard region (above trapezoid): x[68050,68200] y[2975,3060]
  const x0=68050.0,x1=68200.0,y0=2975.0,y1=3060.0;
  var lseg=0; final llay=<int,int>{};
  for(var i=0;i<lineCount;i++){
    final ax=bd.getFloat32(o,Endian.little), ay=bd.getFloat32(o+4,Endian.little);
    final bx=bd.getFloat32(o+8,Endian.little), by=bd.getFloat32(o+12,Endian.little);
    final l=bd.getUint16(o+20,Endian.little); o+=stride;
    final mx=(ax+bx)/2,my=(ay+by)/2;
    if(mx>x0&&mx<x1&&my>y0&&my<y1){lseg++; llay[l]=(llay[l]??0)+1;}
  }
  print('LINES in keyboard box=$lseg');
  llay.forEach((k,v){final n=k<names.length?names[k]:'?'; print('  line layer $n[$k]: $v');});
  // circles
  final cc=bd.getUint32(o,Endian.little); o+=4; o+=cc*18;
  // texts
  final tc=bd.getUint32(o,Endian.little); o+=4;
  for(var i=0;i<tc;i++){ o+=25-2; final len=bd.getUint16(o,Endian.little); o+=2; o+=len; }
  // fills
  final fc=bd.getUint32(o,Endian.little); o+=4;
  var fraw=0; final flay=<int,int>{};
  for(var i=0;i<fc;i++){
    final col=bd.getUint32(o,Endian.little); final lay=bd.getUint16(o+4,Endian.little);
    final nl=bd.getUint16(o+6,Endian.little); o+=8;
    var fx0=1e30,fy0=1e30,fx1=-1e30,fy1=-1e30;
    for(var j=0;j<nl;j++){ final np=bd.getUint32(o,Endian.little); o+=4;
      for(var k=0;k<np;k++){ final px=bd.getFloat32(o,Endian.little),py=bd.getFloat32(o+4,Endian.little); o+=8;
        if(px<fx0)fx0=px; if(py<fy0)fy0=py; if(px>fx1)fx1=px; if(py>fy1)fy1=py; } }
    final cx=(fx0+fx1)/2, cy=(fy0+fy1)/2;
    if(cx>x0&&cx<x1&&cy>y0&&cy<y1){fraw++; flay[lay]=(flay[lay]??0)+1;
      if(fraw<=8) print('  RAWFILL col=${h(col)} layer=${lay<names.length?names[lay]:"?"}[$lay] bbox=${(fx1-fx0).toStringAsFixed(0)}x${(fy1-fy0).toStringAsFixed(0)} at(${fx0.toStringAsFixed(0)},${fy0.toStringAsFixed(0)})');
    }
  }
  print('RAW FILLS in keyboard box=$fraw');
  flay.forEach((k,v){final n=k<names.length?names[k]:'?'; print('  fill layer $n[$k]: $v');});
}
String utf8dec(Uint8List b,int o,int n){ return String.fromCharCodes(b.sublist(o,o+n)); }
