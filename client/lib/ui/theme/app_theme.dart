/// 由 [ThemePrefs] 构建 M3 [ThemeData]；高对比覆盖全部色面策略。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme_prefs.dart';

/// 实验性液态玻璃：通过 [ThemeExtension] 下发，组件按需读取。
@immutable
class LiquidGlassTokens extends ThemeExtension<LiquidGlassTokens> {
  const LiquidGlassTokens({
    required this.enabled,
    required this.blurSigma,
    required this.fillOpacity,
    required this.borderOpacity,
  });

  final bool enabled;
  final double blurSigma;
  final double fillOpacity;
  final double borderOpacity;

  static const disabled = LiquidGlassTokens(
    enabled: false,
    blurSigma: 0,
    fillOpacity: 1,
    borderOpacity: 0,
  );

  static const experimental = LiquidGlassTokens(
    enabled: true,
    blurSigma: 24,
    fillOpacity: 0.55,
    borderOpacity: 0.28,
  );

  @override
  LiquidGlassTokens copyWith({
    bool? enabled,
    double? blurSigma,
    double? fillOpacity,
    double? borderOpacity,
  }) {
    return LiquidGlassTokens(
      enabled: enabled ?? this.enabled,
      blurSigma: blurSigma ?? this.blurSigma,
      fillOpacity: fillOpacity ?? this.fillOpacity,
      borderOpacity: borderOpacity ?? this.borderOpacity,
    );
  }

  @override
  LiquidGlassTokens lerp(ThemeExtension<LiquidGlassTokens>? other, double t) {
    if (other is! LiquidGlassTokens) return this;
    double mix(double a, double b) => a + (b - a) * t;
    return LiquidGlassTokens(
      enabled: t < 0.5 ? enabled : other.enabled,
      blurSigma: mix(blurSigma, other.blurSigma),
      fillOpacity: mix(fillOpacity, other.fillOpacity),
      borderOpacity: mix(borderOpacity, other.borderOpacity),
    );
  }
}

class AppTheme {
  AppTheme._();

  static ThemeData light(ThemePrefs prefs) => _build(prefs, Brightness.light);

  static ThemeData dark(ThemePrefs prefs) => _build(prefs, Brightness.dark);

  static ThemeData _build(ThemePrefs prefs, Brightness brightness) {
    final seed = prefs.seedColor;
    var scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );

    if (prefs.highContrast) {
      scheme = _highContrastScheme(scheme, brightness, seed);
    }

    final glass = prefs.effectiveLiquidGlass
        ? LiquidGlassTokens.experimental
        : LiquidGlassTokens.disabled;

    final cardColor = glass.enabled
        ? scheme.surfaceContainerHighest.withValues(alpha: glass.fillOpacity)
        : null;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      visualDensity: prefs.highContrast
          ? VisualDensity.comfortable
          : VisualDensity.standard,
      applyElevationOverlayColor: !prefs.highContrast,
      cardTheme: CardThemeData(
        color: cardColor,
        elevation: glass.enabled ? 0 : (prefs.highContrast ? 0 : null),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(glass.enabled ? 20 : 12),
          side: glass.enabled
              ? BorderSide(
                  color: scheme.outlineVariant
                      .withValues(alpha: glass.borderOpacity),
                )
              : (prefs.highContrast
                  ? BorderSide(color: scheme.outline, width: 1.5)
                  : BorderSide.none),
        ),
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        scrolledUnderElevation: prefs.highContrast ? 0 : 1,
        backgroundColor: prefs.highContrast
            ? scheme.surface
            : (glass.enabled
                ? scheme.surface.withValues(alpha: glass.fillOpacity)
                : null),
        foregroundColor: scheme.onSurface,
      ),
      navigationBarTheme: NavigationBarThemeData(
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected || prefs.highContrast
                ? FontWeight.w700
                : FontWeight.w500,
          );
        }),
      ),
      dividerTheme: prefs.highContrast
          ? DividerThemeData(color: scheme.outline, thickness: 1.2)
          : null,
      extensions: [glass],
    );
  }

  /// 高对比色面：固定黑/白表面，强化 on* 与 outline，保留 seed 作 primary 倾向。
  static ColorScheme _highContrastScheme(
    ColorScheme base,
    Brightness brightness,
    Color seed,
  ) {
    final isDark = brightness == Brightness.dark;
    final surface = isDark ? Colors.black : Colors.white;
    final onSurface = isDark ? Colors.white : Colors.black;
    final primary = _ensureContrast(seed, surface, minRatio: 4.5);
    final onPrimary = _onFor(primary);
    final secondary =
        isDark ? const Color(0xff80deea) : const Color(0xff006064);
    final error = isDark ? const Color(0xffff8a80) : const Color(0xffb71c1c);

    return base.copyWith(
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: primary,
      onPrimaryContainer: onPrimary,
      secondary: secondary,
      onSecondary: _onFor(secondary),
      secondaryContainer: secondary,
      onSecondaryContainer: _onFor(secondary),
      error: error,
      onError: _onFor(error),
      errorContainer: error,
      onErrorContainer: _onFor(error),
      surface: surface,
      onSurface: onSurface,
      onSurfaceVariant: onSurface,
      surfaceContainerLowest: surface,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: surface,
      surfaceContainerHighest: surface,
      surfaceTint: Colors.transparent,
      outline: onSurface,
      outlineVariant: onSurface.withValues(alpha: 0.7),
      inverseSurface: onSurface,
      onInverseSurface: surface,
      inversePrimary: primary,
      scrim: Colors.black,
      shadow: Colors.black,
    );
  }

  static Color _onFor(Color bg) {
    return ThemeData.estimateBrightnessForColor(bg) == Brightness.dark
        ? Colors.white
        : Colors.black;
  }

  static Color _ensureContrast(
    Color fg,
    Color bg, {
    required double minRatio,
  }) {
    if (_contrastRatio(fg, bg) >= minRatio) return fg;
    final target = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark
        ? Colors.white
        : Colors.black;
    var best = fg;
    for (var i = 0; i <= 20; i++) {
      final c = Color.lerp(fg, target, i / 20)!;
      best = c;
      if (_contrastRatio(c, bg) >= minRatio) return c;
    }
    return best;
  }

  static double _contrastRatio(Color a, Color b) {
    final l1 = _relLuminance(a);
    final l2 = _relLuminance(b);
    final lighter = math.max(l1, l2);
    final darker = math.min(l1, l2);
    return (lighter + 0.05) / (darker + 0.05);
  }

  static double _relLuminance(Color c) {
    double lin(double channel) {
      return channel <= 0.04045
          ? channel / 12.92
          : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
  }
}
