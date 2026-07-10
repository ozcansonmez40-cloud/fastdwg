import 'dart:convert';

import 'package:flutter/material.dart';

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.hasPremium = false,
    this.adsEnabled = false,
    this.cacheLimitMb = 256,
    this.viewerBgWhite = false,
    this.viewerMonochrome = false,
    this.viewerLineWeights = true,
    this.language = 'system',
  });

  final ThemeMode themeMode;
  final bool hasPremium;
  final bool adsEnabled;
  final int cacheLimitMb;

  // Viewer defaults — remembered across drawings so a preference set once in
  // the viewer's settings sheet (white paper, B/W, lineweights) applies to
  // every next file instead of resetting each open.
  final bool viewerBgWhite;
  final bool viewerMonochrome;
  final bool viewerLineWeights;

  /// UI language: 'system' (follow device), 'tr' or 'en'.
  final String language;

  AppSettings copyWith({
    ThemeMode? themeMode,
    bool? hasPremium,
    bool? adsEnabled,
    int? cacheLimitMb,
    bool? viewerBgWhite,
    bool? viewerMonochrome,
    bool? viewerLineWeights,
    String? language,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      hasPremium: hasPremium ?? this.hasPremium,
      adsEnabled: adsEnabled ?? this.adsEnabled,
      cacheLimitMb: cacheLimitMb ?? this.cacheLimitMb,
      viewerBgWhite: viewerBgWhite ?? this.viewerBgWhite,
      viewerMonochrome: viewerMonochrome ?? this.viewerMonochrome,
      viewerLineWeights: viewerLineWeights ?? this.viewerLineWeights,
      language: language ?? this.language,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'themeMode': themeMode.name,
      'hasPremium': hasPremium,
      'adsEnabled': adsEnabled,
      'cacheLimitMb': cacheLimitMb,
      'viewerBgWhite': viewerBgWhite,
      'viewerMonochrome': viewerMonochrome,
      'viewerLineWeights': viewerLineWeights,
      'language': language,
    };
  }

  factory AppSettings.fromMap(Map<String, dynamic> map) {
    return AppSettings(
      themeMode: ThemeMode.values.firstWhere(
        (mode) => mode.name == map['themeMode'],
        orElse: () => ThemeMode.dark,
      ),
      hasPremium: map['hasPremium'] as bool? ?? false,
      adsEnabled: map['adsEnabled'] as bool? ?? false,
      cacheLimitMb: map['cacheLimitMb'] as int? ?? 256,
      viewerBgWhite: map['viewerBgWhite'] as bool? ?? false,
      viewerMonochrome: map['viewerMonochrome'] as bool? ?? false,
      viewerLineWeights: map['viewerLineWeights'] as bool? ?? true,
      language: map['language'] as String? ?? 'system',
    );
  }

  String toJson() => jsonEncode(toMap());

  factory AppSettings.fromJson(String source) {
    return AppSettings.fromMap(jsonDecode(source) as Map<String, dynamic>);
  }
}
