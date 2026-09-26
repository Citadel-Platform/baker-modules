import 'package:flutter/material.dart';

import 'tokens.dart';

/// The application's theme for one brightness, derived from the tokens.
///
/// A colour written twice is a colour that will one day be two colours, so
/// every Material role is mapped from [AppColors] here and nowhere else.
ThemeData appTheme(Brightness brightness) {
  final AppColors c = brightness == Brightness.dark
      ? AppColors.dark
      : AppColors.light;
  final ColorScheme scheme =
      ColorScheme.fromSeed(
        seedColor: c.accent,
        brightness: brightness,
      ).copyWith(
        primary: c.accent,
        onPrimary: c.onAccent,
        surface: c.surface,
        surfaceContainerLow: c.background,
        surfaceContainerHigh: c.surfaceRaised,
        onSurface: c.textPrimary,
        onSurfaceVariant: c.textSecondary,
        outline: c.border,
        outlineVariant: c.border,
        error: c.danger,
      );

  final TextTheme text = _textTheme(c);
  final OutlineInputBorder inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppTokens.radiusMd),
    borderSide: BorderSide(color: c.border),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: AppTokens.fontFamily,
    textTheme: text,
    scaffoldBackgroundColor: c.background,
    dividerColor: c.border,
    dividerTheme: DividerThemeData(color: c.border, space: 1, thickness: 1),
    extensions: <ThemeExtension<dynamic>>[c],
    visualDensity: VisualDensity.standard,
    cardTheme: CardThemeData(
      color: c.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        side: BorderSide(color: c.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: c.surface,
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: c.accent, width: 2),
      ),
      errorBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: c.danger),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space3,
        vertical: AppTokens.space2,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, AppTokens.controlHeight),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, AppTokens.controlHeight),
        side: BorderSide(color: c.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: c.surface,
      indicatorColor: c.accentSoft,
      selectedIconTheme: IconThemeData(color: c.accentText),
      selectedLabelTextStyle: text.labelLarge?.copyWith(color: c.accentText),
      unselectedLabelTextStyle: text.labelLarge?.copyWith(color: c.textMuted),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.surface,
      indicatorColor: c.accentSoft,
    ),
  );
}

TextTheme _textTheme(AppColors c) => TextTheme(
  headlineSmall: TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    color: c.textPrimary,
  ),
  titleLarge: TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: c.textPrimary,
  ),
  titleMedium: TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: c.textPrimary,
  ),
  bodyLarge: TextStyle(fontSize: 15, color: c.textPrimary),
  bodyMedium: TextStyle(fontSize: 14, color: c.textSecondary),
  bodySmall: TextStyle(fontSize: 12, color: c.textMuted),
  labelLarge: TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: c.textPrimary,
  ),
  labelMedium: TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: c.textSecondary,
  ),
  labelSmall: TextStyle(fontSize: 11, letterSpacing: 0.4, color: c.textMuted),
);

/// Monospace text for identifiers, amounts in tables and payloads.
TextStyle monoStyle(BuildContext context, {double fontSize = 13}) => TextStyle(
  fontFamily: AppTokens.monoFontFamily,
  fontSize: fontSize,
  color: AppColors.of(context).textPrimary,
  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
);
