/// 主壳：底部导航在「首页 / 设置」间切换。
///
/// 开启液态玻璃时底栏为 [GlassTabBar]；关闭时为自绘满高 tab 指示器底栏
///（指示器高度撑满每个 tab，形状为超椭圆）。
library;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../home/home_page.dart';
import '../settings/settings_page.dart';
import '../theme/app_theme.dart';
import '../theme/liquid_glass.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  static const _tabs = <_ShellTab>[
    _ShellTab(
      label: '首页',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
    ),
    _ShellTab(
      label: '设置',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final glass = liquidGlassEnabled(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      // 内容延伸到底栏后，玻璃折射才有内容可采样。
      extendBody: glass,
      body: IndexedStack(
        index: _index,
        children: const [
          EleconHomePage(),
          SettingsPage(),
        ],
      ),
      bottomNavigationBar: glass
          ? _GlassShellBar(
              tabs: _tabs,
              selectedIndex: _index,
              onSelected: (i) => setState(() => _index = i),
              scheme: scheme,
            )
          : _MaterialShellBar(
              tabs: _tabs,
              selectedIndex: _index,
              onSelected: (i) => setState(() => _index = i),
            ),
    );
  }
}

class _ShellTab {
  const _ShellTab({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// 液态玻璃底栏：指示器为每个 tab 的满高玻璃胶囊。
class _GlassShellBar extends StatelessWidget {
  const _GlassShellBar({
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    required this.scheme,
  });

  final List<_ShellTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return GlassTabBar.bottom(
      tabs: [
        for (final t in tabs)
          GlassTab(
            label: t.label,
            icon: Icon(t.icon),
            activeIcon: Icon(t.selectedIcon),
          ),
      ],
      selectedIndex: selectedIndex,
      onTabSelected: onSelected,
      barHeight: 68,
      horizontalPadding: 16,
      verticalPadding: 10,
      // 指示器相对 tab 槽外扩，竖直撑满 bar 成胶囊（包默认 vertical: 8）。
      indicatorExpansion:
          const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      indicatorBorderRadius: 28,
      selectedIconColor: scheme.primary,
      selectedLabelColor: scheme.primary,
      unselectedIconColor: scheme.onSurfaceVariant,
      unselectedLabelColor: scheme.onSurfaceVariant,
      quality: GlassQuality.standard,
      magnification: 1.08,
      // 底栏 / 指示器承担主色；卡片表面仅极浅 tint。
      settings: liquidGlassBarSettings(scheme),
      indicatorSettings: liquidGlassIndicatorSettings(scheme),
    );
  }
}

/// Material 底栏：Stack + 满高超椭圆指示器（非仅图标后 32px 小条）。
class _MaterialShellBar extends StatelessWidget {
  const _MaterialShellBar({
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<_ShellTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const _height = 64.0;
  static const _padH = 12.0;
  static const _padV = 8.0;
  static const _inset = 4.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: EdgeInsets.fromLTRB(_padH, 0, _padH, _padV + bottomInset),
        child: Material(
          elevation: 3,
          shadowColor: scheme.shadow.withValues(alpha: 0.2),
          surfaceTintColor: Colors.transparent,
          color: scheme.surfaceContainer,
          shape: AppTheme.barShape,
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: _height,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final n = tabs.length;
                final tabW = constraints.maxWidth / n;
                return Stack(
                  children: [
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      left: selectedIndex * tabW + _inset,
                      top: _inset,
                      bottom: _inset,
                      width: tabW - _inset * 2,
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: scheme.secondaryContainer,
                          shape: const RoundedSuperellipseBorder(
                            borderRadius: BorderRadius.all(Radius.circular(20)),
                          ),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        for (var i = 0; i < n; i++)
                          Expanded(
                            child: _MaterialTab(
                              tab: tabs[i],
                              selected: i == selectedIndex,
                              onTap: () => onSelected(i),
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _MaterialTab extends StatelessWidget {
  const _MaterialTab({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final _ShellTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    final labelStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
          color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          fontSize: 12,
        );

    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      child: InkWell(
        onTap: onTap,
        customBorder: const RoundedSuperellipseBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(selected ? tab.selectedIcon : tab.icon, size: 24, color: color),
            const SizedBox(height: 2),
            Text(tab.label, style: labelStyle, maxLines: 1),
          ],
        ),
      ),
    );
  }
}
