import 'package:flutter/material.dart';

/// CitadelDS v1: the values everything else is built from.
///
/// One place, so a spacing change is a spacing change rather than a hunt, and
/// the same hues as the Citadel Console so a client application and the
/// console it is administered from do not drift into two half-similar looks.
///
/// Colours come in a light and a dark set. Widgets never read these directly:
/// they read [AppColors] from the theme, so a screen is correct in both modes
/// without knowing there are two.
abstract final class AppTokens {
  static const String fontFamily = 'Cairo';
  static const String monoFontFamily = 'JetBrainsMono';

  /// Four-point spacing scale. Every gap comes from here.
  static const double space1 = 4;
  static const double space2 = 8;
  static const double space3 = 12;
  static const double space4 = 16;
  static const double space5 = 20;
  static const double space6 = 24;
  static const double space8 = 32;

  static const double radiusSm = 6;
  static const double radiusMd = 8;
  static const double radiusLg = 12;

  /// Every control in a toolbar is this tall, so a row of them lines up.
  static const double controlHeight = 36;

  /// Table rows are a fixed height: it is what lets a long table build only
  /// the rows on screen.
  static const double rowHeight = 44;

  /// Content stops widening here; wider screens get margins, not longer lines.
  static const double contentMaxWidth = 1440;

  static const Duration motionFast = Duration(milliseconds: 120);
  static const Duration motionMedium = Duration(milliseconds: 220);
}

/// The colour roles a screen may use, for one brightness.
///
/// Semantic, not literal: `danger` rather than `red`, so a status reads the
/// same in both modes and a rebrand is one edit.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.accentText,
    required this.accentSoft,
    required this.success,
    required this.warning,
    required this.danger,
  });

  final Color background;
  final Color surface;
  final Color surfaceRaised;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  /// For fills, focus rings and borders.
  final Color accent;

  /// For accent-coloured text and icons, lifted until it is legible (at least
  /// 4.5:1) on every surface. [accent] as 12px type is not.
  final Color accentText;
  final Color accentSoft;
  final Color success;
  final Color warning;
  final Color danger;

  static const AppColors dark = AppColors(
    background: Color(0xFF0B121C),
    surface: Color(0xFF152334),
    surfaceRaised: Color(0xFF1C2C3E),
    border: Color(0xFF2B4054),
    textPrimary: Color(0xFFE9EFF6),
    textSecondary: Color(0xFFC0CAD4),
    textMuted: Color(0xFF97A1AC),
    accent: Color(0xFF4A8B8F),
    accentText: Color(0xFF74C9CE),
    accentSoft: Color(0xFF1B3336),
    success: Color(0xFF5FA87A),
    warning: Color(0xFFD39C4C),
    danger: Color(0xFFDC8585),
  );

  static const AppColors light = AppColors(
    background: Color(0xFFF5F7FA),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFF0F3F7),
    border: Color(0xFFD5DDE5),
    textPrimary: Color(0xFF14202C),
    textSecondary: Color(0xFF3A4957),
    textMuted: Color(0xFF5B6875),
    accent: Color(0xFF3B7B7F),
    accentText: Color(0xFF2B6468),
    accentSoft: Color(0xFFE1F0F0),
    success: Color(0xFF2F7A4B),
    warning: Color(0xFF8A5A12),
    danger: Color(0xFFB03A3A),
  );

  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>() ?? dark;

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      background: mix(background, other.background),
      surface: mix(surface, other.surface),
      surfaceRaised: mix(surfaceRaised, other.surfaceRaised),
      border: mix(border, other.border),
      textPrimary: mix(textPrimary, other.textPrimary),
      textSecondary: mix(textSecondary, other.textSecondary),
      textMuted: mix(textMuted, other.textMuted),
      accent: mix(accent, other.accent),
      accentText: mix(accentText, other.accentText),
      accentSoft: mix(accentSoft, other.accentSoft),
      success: mix(success, other.success),
      warning: mix(warning, other.warning),
      danger: mix(danger, other.danger),
    );
  }
}
