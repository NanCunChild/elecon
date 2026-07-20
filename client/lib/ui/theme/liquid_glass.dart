/// 卡片等局部表面的玻璃封装。
/// 导航 chrome 由 [MainShell] 的 [GlassTabBar] 负责；此处仅用于内容区可选玻璃盘。
library;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app_theme.dart';

/// 启用液态玻璃时用 package [GlassContainer]；否则透传 [child]。
class LiquidGlassSurface extends StatelessWidget {
  const LiquidGlassSurface({
    super.key,
    required this.child,
    this.borderRadius,
    this.padding,
  });

  final Widget child;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<LiquidGlassTokens>();
    if (tokens == null || !tokens.enabled) {
      return padding == null ? child : Padding(padding: padding!, child: child);
    }

    final r = borderRadius?.topLeft.x ?? 28.0;
    return GlassContainer(
      shape: LiquidRoundedSuperellipse(borderRadius: r.clamp(8.0, 40.0)),
      quality: GlassQuality.standard,
      padding: padding,
      child: child,
    );
  }
}
