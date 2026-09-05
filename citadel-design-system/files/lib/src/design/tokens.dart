import 'package:flutter/material.dart';

/// The values everything else is built from.
///
/// One place, so a spacing change is a spacing change rather than a hunt. The
/// same shape as the Citadel console's own tokens, so a client application and
/// the console it is administered from age together instead of drifting into
/// two half-similar looks.
abstract final class AppTokens {
  static const Color surface = Color(0xFF0E1621);
  static const Color surfaceRaised = Color(0xFF16202D);
  static const Color border = Color(0xFF25313F);
  static const Color textPrimary = Color(0xFFE6EDF3);
  static const Color textMuted = Color(0xFF8A9AAB);
  static const Color accent = Color(0xFF5EAFA8);
  static const Color danger = Color(0xFFDC8585);

  static const double space1 = 4;
  static const double space2 = 8;
  static const double space3 = 16;
  static const double space4 = 24;
  static const double space5 = 32;

  static const double radius = 8;
}

/// The application's theme, derived from the tokens rather than repeating
/// them. A colour written twice is a colour that will one day be two colours.
ThemeData appTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: AppTokens.accent,
    brightness: Brightness.dark,
  ).copyWith(surface: AppTokens.surface);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppTokens.surface,
    dividerColor: AppTokens.border,
    textTheme: const TextTheme(
      titleLarge: TextStyle(
        color: AppTokens.textPrimary,
        fontSize: 22,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: TextStyle(
        color: AppTokens.textPrimary,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: TextStyle(color: AppTokens.textMuted, fontSize: 14),
      labelSmall: TextStyle(
        color: AppTokens.textMuted,
        fontSize: 11,
        letterSpacing: 0.6,
      ),
    ),
  );
}
