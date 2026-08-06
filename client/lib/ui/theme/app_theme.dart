/// 应用主题：Material 3 + 可选高对比 + 液态玻璃标记。
///
/// 卡片 / 底栏等圆角统一用 [RoundedSuperellipseBorder]（连续曲率，接近
/// iOS continuous corner），避免普通 RRect 在拐角处的“硬圆”。
library;

import 'package:flutter/material.dart';

import 'liquid_glass.dart';
import 'theme_prefs.dart';

/// 应用主题工厂。
abstract final class AppTheme {
  static const _cardRadius = 16.0;
  static const _barRadius = 28.0;
  static const _buttonRadius = 12.0;

  static ShapeBorder get cardShape => const RoundedSuperellipseBorder(
    borderRadius: BorderRadius.all(Radius.circular(_cardRadius)),
  );

  static ShapeBorder get barShape => const RoundedSuperellipseBorder(
    borderRadius: BorderRadius.all(Radius.circular(_barRadius)),
  );

  static ThemeData light(ThemePrefs prefs) => _build(Brightness.light, prefs);

  static ThemeData dark(ThemePrefs prefs) => _build(Brightness.dark, prefs);

  static ThemeData _build(Brightness brightness, ThemePrefs prefs) {
    final seed = SeedPalette.byId(prefs.seedId).seed;
    var scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);

    if (prefs.highContrast) {
      scheme = _highContrast(scheme, brightness);
    }

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      visualDensity: VisualDensity.standard,
    );

    // 液态玻璃开启时：底面略带 seed/primary，作为主色贡献源；
    // 卡片玻璃只留极浅 tint（见 liquid_glass.dart）。
    final effectiveLiquidGlass =
        liquidGlassAvailable && prefs.effectiveLiquidGlass;
    final scaffoldBg = effectiveLiquidGlass
        ? Color.alphaBlend(
            seed.withValues(
              alpha: brightness == Brightness.light ? 0.06 : 0.10,
            ),
            scheme.surface,
          )
        : scheme.surface;

    return base.copyWith(
      extensions: <ThemeExtension<dynamic>>[
        LiquidGlassTokens(enabled: effectiveLiquidGlass),
      ],
      scaffoldBackgroundColor: scaffoldBg,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scaffoldBg,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: prefs.highContrast ? 0 : 1,
      ),
      cardTheme: CardThemeData(
        elevation: prefs.highContrast ? 0 : 0.5,
        shape: cardShape,
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
      ),
      dialogTheme: DialogThemeData(
        shape: const RoundedSuperellipseBorder(
          borderRadius: BorderRadius.all(Radius.circular(28)),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        shape: const RoundedSuperellipseBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const RoundedSuperellipseBorder(
            borderRadius: BorderRadius.all(Radius.circular(_buttonRadius)),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: const RoundedSuperellipseBorder(
            borderRadius: BorderRadius.all(Radius.circular(_buttonRadius)),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 64,
        elevation: 0,
        backgroundColor: Colors.transparent,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const RoundedSuperellipseBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 24,
            color: selected
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
          );
        }),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  static ColorScheme _highContrast(ColorScheme base, Brightness brightness) {
    if (brightness == Brightness.light) {
      return base.copyWith(
        surface: Colors.white,
        onSurface: Colors.black,
        surfaceContainerLowest: Colors.white,
        surfaceContainerLow: const Color(0xFFF2F2F2),
        surfaceContainer: const Color(0xFFE6E6E6),
        surfaceContainerHigh: const Color(0xFFD9D9D9),
        surfaceContainerHighest: const Color(0xFFCCCCCC),
        outline: Colors.black,
        outlineVariant: const Color(0xFF444444),
        shadow: Colors.black,
        scrim: Colors.black,
        surfaceTint: Colors.transparent,
      );
    }
    return base.copyWith(
      surface: Colors.black,
      onSurface: Colors.white,
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: const Color(0xFF121212),
      surfaceContainer: const Color(0xFF1A1A1A),
      surfaceContainerHigh: const Color(0xFF242424),
      surfaceContainerHighest: const Color(0xFF2E2E2E),
      outline: Colors.white,
      outlineVariant: const Color(0xFFBBBBBB),
      shadow: Colors.black,
      scrim: Colors.black,
      surfaceTint: Colors.transparent,
    );
  }
}
