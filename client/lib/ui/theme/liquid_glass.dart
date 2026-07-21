/// 液态玻璃（liquid glass）开关与表面组件。
///
/// 主题 [LiquidGlassTokens.enabled] 为 true 时，[LiquidGlassSurface] 走
/// `liquid_glass_widgets` 的 [GlassContainer]；关闭时回落到 Material 超椭圆表面。
///
/// 着色策略：玻璃本身只带**很浅**的主题 seed/primary tint；主色贡献留给
/// scaffold 底面背景与底栏玻璃（见 [liquidGlassBarSettings] / [AppTheme]）。
library;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app_theme.dart';

/// 解析当前主题是否启用液态玻璃。
bool liquidGlassEnabled(BuildContext context) {
  return Theme.of(context).extension<LiquidGlassTokens>()?.enabled ?? false;
}

/// 将主题 seed/primary 混入玻璃 tint。
///
/// [primaryMix] 控制色相偏主题的程度（0–1）；[alpha] 为 shader 着色强度，
/// 卡片宜低、底栏/指示器可略高。
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

/// 卡片 / 分组面板：极浅主题 tint，不抢背景与底栏的色。
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

/// 底栏玻璃：略强主题 tint，作为主色贡献面之一。
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

/// 选中指示器胶囊：再略强一点 primary，与底栏分层。
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

/// 统一表面：开启液态玻璃时用 [GlassContainer]，否则用超椭圆 [Material]。
///
/// 用于卡片、分组面板等；勿把交互式 glass 控件再嵌进本表面（包约束）。
class LiquidGlassSurface extends StatelessWidget {
  const LiquidGlassSurface({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius = 16,
    this.color,
    this.clipBehavior = Clip.antiAlias,
    this.elevation = 0,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final Color? color;
  final Clip clipBehavior;
  final double elevation;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = padding == null
        ? child
        : Padding(padding: padding!, child: child);

    if (liquidGlassEnabled(context)) {
      return GlassContainer(
        useOwnLayer: true,
        quality: GlassQuality.standard,
        margin: margin,
        padding: padding,
        clipBehavior: clipBehavior,
        shape: LiquidRoundedSuperellipse(borderRadius: borderRadius),
        settings: liquidGlassSurfaceSettings(scheme),
        child: child,
      );
    }

    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(borderRadius),
    );
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: Material(
        color: color ?? scheme.surfaceContainerLow,
        elevation: elevation,
        shadowColor: scheme.shadow.withValues(alpha: 0.18),
        surfaceTintColor: Colors.transparent,
        shape: shape,
        clipBehavior: clipBehavior,
        child: content,
      ),
    );
  }
}
