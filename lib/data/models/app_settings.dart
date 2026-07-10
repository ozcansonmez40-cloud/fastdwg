import 'dart:convert';

import 'package:flutter/material.dart';

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.hasPremium = false,
    this.adsEnabled = false,
    this.cacheLimitMb = 256,
  });

  final ThemeMode themeMode;
  final bool hasPremium;
  final bool adsEnabled;
  final int cacheLimitMb;

  AppSettings copyWith({
    ThemeMode? themeMode,
    bool? hasPremium,
    bool? adsEnabled,
    int? cacheLimitMb,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      hasPremium: hasPremium ?? this.hasPremium,
      adsEnabled: adsEnabled ?? this.adsEnabled,
      cacheLimitMb: cacheLimitMb ?? this.cacheLimitMb,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'themeMode': themeMode.name,
      'hasPremium': hasPremium,
      'adsEnabled': adsEnabled,
      'cacheLimitMb': cacheLimitMb,
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
    );
  }

  String toJson() => jsonEncode(toMap());

  factory AppSettings.fromJson(String source) {
    return AppSettings.fromMap(jsonDecode(source) as Map<String, dynamic>);
  }
}
