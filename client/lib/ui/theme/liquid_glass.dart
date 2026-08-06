/// Platform-neutral liquid-glass facade.
///
/// The default application entry point never imports the Apple implementation.
/// `main_apple.dart` installs it for iOS and macOS builds only, leaving other
/// platforms with the Material fallback and no liquid-glass package in their
/// compile-time import graph.
library;

import 'package:flutter/material.dart';

typedef LiquidGlassSurfaceBuilder =
    Widget Function({
      required Widget child,
      required EdgeInsetsGeometry? padding,
      required EdgeInsetsGeometry? margin,
      required double borderRadius,
      required Color? color,
      required Clip clipBehavior,
      required double elevation,
    });

typedef LiquidGlassShellBarBuilder =
    Widget Function({
      required List<LiquidGlassTabSpec> tabs,
      required int selectedIndex,
      required ValueChanged<int> onSelected,
      required ColorScheme scheme,
    });

typedef LiquidGlassSettingsTileBuilder = Widget Function(BuildContext context);

LiquidGlassSurfaceBuilder? _surfaceBuilder;
LiquidGlassShellBarBuilder? _shellBarBuilder;
LiquidGlassSettingsTileBuilder? _settingsTileBuilder;

@immutable
class LiquidGlassTokens extends ThemeExtension<LiquidGlassTokens> {
  const LiquidGlassTokens({required this.enabled});

  final bool enabled;

  @override
  LiquidGlassTokens copyWith({bool? enabled}) =>
      LiquidGlassTokens(enabled: enabled ?? this.enabled);

  @override
  LiquidGlassTokens lerp(ThemeExtension<LiquidGlassTokens>? other, double t) {
    if (other is! LiquidGlassTokens) return this;
    return t < 0.5 ? this : other;
  }
}

/// Installs the implementation compiled from the Apple-only entry point.
void installLiquidGlassImplementation({
  required LiquidGlassSurfaceBuilder surfaceBuilder,
  required LiquidGlassShellBarBuilder shellBarBuilder,
  required LiquidGlassSettingsTileBuilder settingsTileBuilder,
}) {
  _surfaceBuilder = surfaceBuilder;
  _shellBarBuilder = shellBarBuilder;
  _settingsTileBuilder = settingsTileBuilder;
}

@visibleForTesting
void resetLiquidGlassImplementation() {
  _surfaceBuilder = null;
  _shellBarBuilder = null;
  _settingsTileBuilder = null;
}

/// Describes one shell tab without exposing the third-party glass package.
class LiquidGlassTabSpec {
  const LiquidGlassTabSpec({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Liquid glass is available only when the Apple entry point installed it.
bool get liquidGlassAvailable => _surfaceBuilder != null;

bool liquidGlassEnabled(BuildContext context) {
  return liquidGlassAvailable &&
      (Theme.of(context).extension<LiquidGlassTokens>()?.enabled ?? false);
}

Widget? buildLiquidGlassShellBar({
  required BuildContext context,
  required List<LiquidGlassTabSpec> tabs,
  required int selectedIndex,
  required ValueChanged<int> onSelected,
}) {
  if (!liquidGlassEnabled(context)) return null;
  return _shellBarBuilder?.call(
    tabs: tabs,
    selectedIndex: selectedIndex,
    onSelected: onSelected,
    scheme: Theme.of(context).colorScheme,
  );
}

Widget? buildLiquidGlassSettingsTile(BuildContext context) {
  return _settingsTileBuilder?.call(context);
}

/// Unified surface that delegates to glass only in an Apple build.
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
    if (liquidGlassEnabled(context)) {
      return _surfaceBuilder!(
        child: child,
        padding: padding,
        margin: margin,
        borderRadius: borderRadius,
        color: color,
        clipBehavior: clipBehavior,
        elevation: elevation,
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final content = padding == null
        ? child
        : Padding(padding: padding!, child: child);
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
