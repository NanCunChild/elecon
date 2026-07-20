/// 实验性液态玻璃表面包装：半透明 + 可选 blur。
///
/// 高对比模式下 [LiquidGlassTokens.enabled] 为 false，本组件退化为普通 [Material]。
library;

import 'dart:ui';

import 'package:flutter/material.dart';

import 'app_theme.dart';

class LiquidGlassSurface extends StatelessWidget {
  const LiquidGlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(28)),
    this.elevation = 3,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double elevation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final glass = theme.extension<LiquidGlassTokens>() ??
        LiquidGlassTokens.disabled;

    if (!glass.enabled) {
      return Material(
        color: scheme.surfaceContainer,
        surfaceTintColor: scheme.surfaceTint,
        shadowColor: Colors.black.withValues(alpha: 0.2),
        elevation: elevation,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: child,
      );
    }

    return Material(
      color: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: glass.blurSigma,
            sigmaY: glass.blurSigma,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest
                  .withValues(alpha: glass.fillOpacity),
              borderRadius: borderRadius,
              border: Border.all(
                color: scheme.outlineVariant
                    .withValues(alpha: glass.borderOpacity),
              ),
              boxShadow: [
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: 0.12),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
