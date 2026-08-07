/// 主壳：底部导航在「首页 / 设置」间切换。
///
/// Apple 构建开启液态玻璃时使用玻璃底栏；其余情况为 Material 底栏。
library;

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../home/home_page.dart';
import '../settings/settings_page.dart';
import '../theme/app_theme.dart';
import '../theme/liquid_glass.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key, this.loadHomeSnapshot});

  final CampusSnapshotLoader? loadHomeSnapshot;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  /// 标签文案随语言变，故在 build 里按当前 l10n 组装（图标是常量）。
  static List<LiquidGlassTabSpec> _tabsOf(AppLocalizations l10n) =>
      <LiquidGlassTabSpec>[
        LiquidGlassTabSpec(
          label: l10n.navHome,
          icon: Icons.home_outlined,
          selectedIcon: Icons.home,
        ),
        LiquidGlassTabSpec(
          label: l10n.navSettings,
          icon: Icons.settings_outlined,
          selectedIcon: Icons.settings,
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final tabs = _tabsOf(AppLocalizations.of(context));
    final glassBar = buildLiquidGlassShellBar(
      context: context,
      tabs: tabs,
      selectedIndex: _index,
      onSelected: (i) => setState(() => _index = i),
    );

    return Scaffold(
      // 内容延伸到底栏后，玻璃折射才有内容可采样。
      extendBody: glassBar != null,
      body: IndexedStack(
        index: _index,
        children: [
          EleconHomePage(loadSnapshot: widget.loadHomeSnapshot),
          const SettingsPage(),
        ],
      ),
      bottomNavigationBar:
          glassBar ??
          _MaterialShellBar(
            tabs: tabs,
            selectedIndex: _index,
            onSelected: (i) => setState(() => _index = i),
          ),
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

  final List<LiquidGlassTabSpec> tabs;
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

  final LiquidGlassTabSpec tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
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
            Icon(
              selected ? tab.selectedIcon : tab.icon,
              size: 24,
              color: color,
            ),
            const SizedBox(height: 2),
            Text(tab.label, style: labelStyle, maxLines: 1),
          ],
        ),
      ),
    );
  }
}
