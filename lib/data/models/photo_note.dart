import 'dart:convert';

/// A photo pinned to a model-space location in a drawing (site photo, detail,
/// etc.). Coordinates are in DWG model units so the pin lands in the same spot
/// across sessions, regardless of pan/zoom.
class PhotoNote {
  const PhotoNote({
    required this.id,
    required this.x,
    required this.y,
    required this.path,
    required this.createdAt,
    this.caption = '',
  });

  final String id;
  final double x;
  final double y;
  final String path; // absolute path to the stored image file
  final DateTime createdAt;
  final String caption;

  PhotoNote copyWith({String? caption}) => PhotoNote(
        id: id,
        x: x,
        y: y,
        path: path,
        createdAt: createdAt,
        caption: caption ?? this.caption,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'x': x,
        'y': y,
        'path': path,
        'createdAt': createdAt.toIso8601String(),
        'caption': caption,
      };

  factory PhotoNote.fromMap(Map<String, dynamic> map) => PhotoNote(
        id: map['id'] as String,
        x: (map['x'] as num).toDouble(),
        y: (map['y'] as num).toDouble(),
        path: map['path'] as String,
        createdAt:
            DateTime.tryParse(map['createdAt'] as String? ?? '') ?? DateTime.now(),
        caption: map['caption'] as String? ?? '',
      );

  static String encodeList(List<PhotoNote> notes) =>
      jsonEncode([for (final n in notes) n.toMap()]);

  static List<PhotoNote> decodeList(String? json) {
    if (json == null || json.trim().isEmpty) return [];
    try {
      final list = jsonDecode(json) as List;
      return [
        for (final e in list) PhotoNote.fromMap(e as Map<String, dynamic>),
      ];
    } catch (_) {
      return [];
    }
  }
}
