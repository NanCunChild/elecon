/// iOS/macOS liquid-glass implementation.
///
/// This library is reachable only from `main_apple.dart`; non-Apple release
/// entry points therefore do not compile these widgets or their package import.
library;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../l10n/gen/app_localizations.dart';
import 'liquid_glass.dart';
import 'theme_scope.dart';

void configureAppleLiquidGlass() {
  installLiquidGlassImplementation(
    surfaceBuilder: _buildSurface,
    shellBarBuilder: _buildShellBar,
    settingsTileBuilder: _buildSettingsTile,
  );
}

Future<void> initializeAppleLiquidGlass() async {
  configureAppleLiquidGlass();
  await LiquidGlassWidgets.initialize();
}

Widget wrapAppleLiquidGlass(Widget child) {
  return LiquidGlassWidgets.wrap(child: child, adaptiveQuality: true);
}

Color themedGlassColor(
  ColorScheme scheme, {
  required double primaryMix,
  required double alpha,
}) {
  final isLight = scheme.brightness == Brightness.light;
  final base = isLight ? Colors.white : const Color(0xFFECECEC);
  final tinted = Color.lerp(base, scheme.primary, primaryMix)!;
  return tinted.withValues(alpha: alpha);
}

LiquidGlassSettings liquidGlassSurfaceSettings(ColorScheme scheme) {
  final isLight = scheme.brightness == Brightness.light;
  return LiquidGlassSettings(
    thickness: 28,
    blur: 10,
    glassColor: themedGlassColor(
      scheme,
      primaryMix: isLight ? 0.28 : 0.36,
      alpha: isLight ? 0.08 : 0.10,
    ),
    lightIntensity: isLight ? 0.68 : 0.55,
    ambientStrength: isLight ? 0.32 : 0.22,
    saturation: 1.04,
    chromaticAberration: 0.01,
  );
}

LiquidGlassSettings liquidGlassBarSettings(ColorScheme scheme) {
  final isLight = scheme.brightness == Brightness.light;
  return LiquidGlassSettings(
    thickness: 32,
    blur: 6,
    glassColor: themedGlassColor(
      scheme,
      primaryMix: isLight ? 0.40 : 0.48,
      alpha: isLight ? 0.16 : 0.18,
    ),
    lightIntensity: isLight ? 0.72 : 0.58,
    ambientStrength: isLight ? 0.55 : 0.4,
    refractiveIndex: 1.5,
    saturation: 1.06,
    chromaticAberration: 0.02,
  );
}

LiquidGlassSettings liquidGlassIndicatorSettings(ColorScheme scheme) {
  final isLight = scheme.brightness == Brightness.light;
  return LiquidGlassSettings(
    thickness: 28,
    blur: 5,
    glassColor: themedGlassColor(
      scheme,
      primaryMix: isLight ? 0.55 : 0.62,
      alpha: isLight ? 0.22 : 0.24,
    ),
    lightIntensity: isLight ? 0.78 : 0.62,
    ambientStrength: isLight ? 0.45 : 0.35,
    saturation: 1.08,
    chromaticAberration: 0.015,
  );
}

Widget _buildSurface({
  required Widget child,
  required EdgeInsetsGeometry? padding,
  required EdgeInsetsGeometry? margin,
  required double borderRadius,
  required Color? color,
  required Clip clipBehavior,
  required double elevation,
}) {
  return Builder(
    builder: (context) => GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      margin: margin,
      padding: padding,
      clipBehavior: clipBehavior,
      shape: LiquidRoundedSuperellipse(borderRadius: borderRadius),
      settings: liquidGlassSurfaceSettings(Theme.of(context).colorScheme),
      child: child,
    ),
  );
}

Widget _buildShellBar({
  required List<LiquidGlassTabSpec> tabs,
  required int selectedIndex,
  required ValueChanged<int> onSelected,
  required ColorScheme scheme,
}) {
  return GlassTabBar.bottom(
    tabs: [
      for (final tab in tabs)
        GlassTab(
          label: tab.label,
          icon: Icon(tab.icon),
          activeIcon: Icon(tab.selectedIcon),
        ),
    ],
    selectedIndex: selectedIndex,
    onTabSelected: onSelected,
    barHeight: 68,
    horizontalPadding: 16,
    verticalPadding: 10,
    indicatorExpansion: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
    indicatorBorderRadius: 28,
    selectedIconColor: scheme.primary,
    selectedLabelColor: scheme.primary,
    unselectedIconColor: scheme.onSurfaceVariant,
    unselectedLabelColor: scheme.onSurfaceVariant,
    quality: GlassQuality.standard,
    magnification: 1.08,
    settings: liquidGlassBarSettings(scheme),
    indicatorSettings: liquidGlassIndicatorSettings(scheme),
  );
}

Widget _buildSettingsTile(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  final themeCtrl = ThemeScope.of(context);
  final prefs = themeCtrl.prefs;
  final scheme = Theme.of(context).colorScheme;
  return SwitchListTile(
    secondary: Icon(
      Icons.water_drop_outlined,
      color: prefs.effectiveLiquidGlass ? scheme.primary : null,
    ),
    title: Text(l10n.experimentalLiquidGlassTitle),
    subtitle: Text(
      prefs.highContrast
          ? l10n.experimentalLiquidGlassDisabledByContrast
          : l10n.experimentalLiquidGlassSubtitle,
    ),
    value: prefs.liquidGlass,
    onChanged: prefs.highContrast ? null : themeCtrl.setLiquidGlass,
  );
}
