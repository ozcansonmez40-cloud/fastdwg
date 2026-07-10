import 'dart:convert';

class RecentFile {
  const RecentFile({
    required this.id,
    required this.name,
    required this.uri,
    required this.fileExtension,
    required this.lastOpenedAt,
    this.thumbnailPath,
    this.fileSizeBytes,
    this.isPinned = false,
  });

  final String id;
  final String name;
  final String uri;
  final String fileExtension;
  final DateTime lastOpenedAt;
  final String? thumbnailPath;
  final int? fileSizeBytes;
  final bool isPinned;

  RecentFile copyWith({
    DateTime? lastOpenedAt,
    String? thumbnailPath,
    int? fileSizeBytes,
    bool? isPinned,
  }) {
    return RecentFile(
      id: id,
      name: name,
      uri: uri,
      fileExtension: fileExtension,
      lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      isPinned: isPinned ?? this.isPinned,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'uri': uri,
      'fileExtension': fileExtension,
      'lastOpenedAt': lastOpenedAt.toIso8601String(),
      'thumbnailPath': thumbnailPath,
      'fileSizeBytes': fileSizeBytes,
      'isPinned': isPinned,
    };
  }

  factory RecentFile.fromMap(Map<String, dynamic> map) {
    return RecentFile(
      id: map['id'] as String,
      name: map['name'] as String,
      uri: map['uri'] as String,
      fileExtension: map['fileExtension'] as String,
      lastOpenedAt: DateTime.parse(map['lastOpenedAt'] as String),
      thumbnailPath: map['thumbnailPath'] as String?,
      fileSizeBytes: map['fileSizeBytes'] as int?,
      isPinned: map['isPinned'] as bool? ?? false,
    );
  }

  String toJson() => jsonEncode(toMap());

  factory RecentFile.fromJson(String source) {
    return RecentFile.fromMap(jsonDecode(source) as Map<String, dynamic>);
  }
}
