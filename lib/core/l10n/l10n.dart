import 'dart:ui' as ui;

/// True when the device language is Turkish.
bool get isTurkish =>
    ui.PlatformDispatcher.instance.locale.languageCode.toLowerCase() == 'tr';

/// Tiny two-language helper: Turkish phones get [trText], everyone else [en].
/// The app has exactly two audiences today; a full ARB/intl pipeline can
/// replace this the day a third language is needed.
String tr(String en, String trText) => isTurkish ? trText : en;
