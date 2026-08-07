import 'package:flutter/material.dart';

/// BroadcastNG's design system: a dark, hardware-console aesthetic with the
/// classic broadcast "ON AIR" red as the primary accent. Distinct from
/// generic Material dark theme — surfaces use layered depth (bevels,
/// subtle gradients) to evoke a physical mixing console rather than flat
/// cards, and numeric readouts (levels, timer) use tabular figures for
/// that instrument-panel look.
class BroadcastNGTheme {
  BroadcastNGTheme._();

  // ---- Core palette ----
  static const Color onAirRed = Color(0xFFE0263A);
  static const Color onAirRedDim = Color(0xFF7A1420);
  static const Color consoleBlack = Color(0xFF0B0B0D);
  static const Color panelDark = Color(0xFF17181C);
  static const Color panelMid = Color(0xFF212227);
  static const Color panelLight = Color(0xFF2C2D33);
  static const Color metalHighlight = Color(0xFF3A3B42);
  static const Color textPrimary = Color(0xFFF2F2F0);
  static const Color textSecondary = Color(0xFFA0A0A8);
  static const Color meterGreen = Color(0xFF4CD164);
  static const Color meterAmber = Color(0xFFE0A62B);

  static ThemeData get theme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: consoleBlack,
      colorScheme: const ColorScheme.dark(
        primary: onAirRed,
        onPrimary: Colors.white,
        secondary: meterAmber,
        surface: panelDark,
        onSurface: textPrimary,
        surfaceContainerHighest: panelMid,
        error: onAirRed,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: panelDark,
        foregroundColor: textPrimary,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 20,
          letterSpacing: 0.5,
          color: textPrimary,
        ),
      ),
      textTheme: const TextTheme(
        headlineSmall: TextStyle(
          fontFeatures: [FontFeature.tabularFigures()],
          fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        titleMedium: TextStyle(color: textPrimary, fontWeight: FontWeight.w600),
        titleSmall: TextStyle(color: textPrimary, fontWeight: FontWeight.w600),
        bodyMedium: TextStyle(color: textSecondary),
        bodySmall: TextStyle(color: textSecondary),
        labelSmall: TextStyle(
          color: textSecondary,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
        labelLarge: TextStyle(color: onAirRed, fontWeight: FontWeight.w700),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? onAirRed : panelLight),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? onAirRedDim : panelMid),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: onAirRed,
        inactiveTrackColor: panelMid,
        thumbColor: onAirRed,
        overlayColor: Color(0x33E0263A),
      ),
      iconTheme: const IconThemeData(color: textPrimary),
      dividerColor: panelLight,
      cardTheme: CardThemeData(
        color: panelDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: panelLight, width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panelMid,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: panelLight),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: panelLight),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: onAirRed, width: 2),
        ),
      ),
    );
  }

  /// Bevelled, hardware-like panel decoration — a subtle top-to-bottom
  /// gradient plus a faint highlight border gives controls a sense of
  /// physical depth rather than the flat look of a default Material card.
  static BoxDecoration consolePanel({
    Color base = panelDark,
    double radius = 14,
    bool raised = true,
  }) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: raised
            ? [
                Color.lerp(base, metalHighlight, 0.18)!,
                base,
                Color.lerp(base, Colors.black, 0.25)!,
              ]
            : [Color.lerp(base, Colors.black, 0.2)!, base],
      ),
      border: Border.all(color: metalHighlight.withValues(alpha: 0.4), width: 1),
      boxShadow: raised
          ? [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ]
          : null,
    );
  }

  /// The signature "ON AIR" light — a glowing red badge used for the live
  /// indicator, matching the physical studio light this app is modeled on.
  static BoxDecoration onAirGlow({required bool active}) {
    return BoxDecoration(
      shape: BoxShape.circle,
      color: active ? onAirRed : panelMid,
      boxShadow: active
          ? [
              BoxShadow(
                color: onAirRed.withValues(alpha: 0.7),
                blurRadius: 16,
                spreadRadius: 2,
              ),
            ]
          : null,
    );
  }
}
