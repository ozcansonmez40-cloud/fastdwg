import 'dart:ui' as ui;

/// Manual override from Settings: 'system' (default), 'tr' or 'en'.
/// Set by AppController when settings load/change.
String appLanguage = 'system';

/// True when the UI should be Turkish: manual choice first, else the
/// device language.
bool get isTurkish {
  if (appLanguage == 'tr') return true;
  if (appLanguage == 'en') return false;
  return ui.PlatformDispatcher.instance.locale.languageCode.toLowerCase() ==
      'tr';
}

/// Tiny two-language helper: Turkish UI gets [trText], everyone else [en].
/// The app has exactly two audiences today; a full ARB/intl pipeline can
/// replace this the day a third language is needed.
String tr(String en, String trText) => isTurkish ? trText : en;
