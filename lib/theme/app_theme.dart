import 'package:flutter/material.dart';

/// StrideMate palette, taken from the app icon.
class SmColors {
  static const navy = Color(0xFF0A1A3F);
  static const navyLight = Color(0xFF13285C);
  static const navyDeep = Color(0xFF060F27);
  static const mint = Color(0xFF6CF59A);
  static const mintDark = Color(0xFF1E8A4C); // mint with enough contrast on ivory
  static const ivory = Color(0xFFFBF6EE);
  static const amber = Color(0xFFFFB547);
  static const coral = Color(0xFFFF7A59);
}

class AppTheme {
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: SmColors.navy,
      brightness: Brightness.light,
      primary: SmColors.navy,
      onPrimary: SmColors.ivory,
      secondary: SmColors.mintDark,
      onSecondary: Colors.white,
      tertiary: SmColors.coral,
      surface: SmColors.ivory,
      onSurface: SmColors.navy,
    );
    return _base(scheme).copyWith(scaffoldBackgroundColor: SmColors.ivory);
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: SmColors.navy,
      brightness: Brightness.dark,
      primary: SmColors.mint,
      onPrimary: SmColors.navyDeep,
      secondary: SmColors.mint,
      onSecondary: SmColors.navyDeep,
      tertiary: SmColors.amber,
      surface: SmColors.navy,
      onSurface: SmColors.ivory,
      surfaceContainerHighest: SmColors.navyLight,
    );
    return _base(scheme).copyWith(scaffoldBackgroundColor: SmColors.navyDeep);
  }

  static ThemeData _base(ColorScheme scheme) => ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: scheme.onSurface,
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: scheme.brightness == Brightness.dark ? SmColors.navy : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
        navigationBarTheme: NavigationBarThemeData(
          indicatorColor: scheme.brightness == Brightness.dark ? SmColors.navyLight : SmColors.mint.withValues(alpha: 0.45),
        ),
        chipTheme: ChipThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      );
}
