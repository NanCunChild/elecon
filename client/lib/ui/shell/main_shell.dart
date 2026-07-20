/// 主壳：底栏四页（首页 / 课表 / 通知 / 设置）+ 滚动隐藏底栏。
/// 液态玻璃开启时用 [GlassScaffold] + [GlassTabBar.bottom]（package 真 shader）；
/// 关闭或高对比时走 Material 悬浮 [NavigationBar]。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../home/home_page.dart';
import '../settings/settings_page.dart';
import '../theme/theme_scope.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  var _index = 0;
  var _navVisible = true;

  static const _destinations = <_Dest>[
    _Dest(
      label: '首页',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
    ),
    _Dest(
      label: '课表',
      icon: Icons.calendar_today_outlined,
      selectedIcon: Icons.calendar_today,
    ),
    _Dest(
      label: '通知',
      icon: Icons.campaign_outlined,
      selectedIcon: Icons.campaign,
    ),
    _Dest(
      label: '设置',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
    ),
  ];

  bool _onScroll(UserScrollNotification n) {
    if (n.depth != 0) return false;
    switch (n.direction) {
      case ScrollDirection.forward:
        if (!_navVisible) setState(() => _navVisible = true);
      case ScrollDirection.reverse:
        if (_navVisible) setState(() => _navVisible = false);
      case ScrollDirection.idle:
        break;
    }
    return false;
  }

  void _select(int i) {
    if (i == _index) return;
    setState(() {
      _index = i;
      _navVisible = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final glass = ThemeScope.of(context).prefs.effectiveLiquidGlass;
    final pages = <Widget>[
      NotificationListener<UserScrollNotification>(
        onNotification: _onScroll,
        child: const EleconHomePage(),
      ),
      NotificationListener<UserScrollNotification>(
        onNotification: _onScroll,
        child: const _PlaceholderTab(
          icon: Icons.schedule,
          label: '课表',
        ),
      ),
      NotificationListener<UserScrollNotification>(
        onNotification: _onScroll,
        child: const _PlaceholderTab(
          icon: Icons.notifications_outlined,
          label: '通知',
        ),
      ),
      NotificationListener<UserScrollNotification>(
        onNotification: _onScroll,
        child: const SettingsPage(),
      ),
    ];

    final body = IndexedStack(index: _index, children: pages);

    if (glass) {
      return GlassScaffold(
        contentAwareBrightness: true,
        extendBody: true,
        body: body,
        bottomBar: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          child: _navVisible
              ? GlassTabBar.bottom(
                  selectedIndex: _index,
                  onTabSelected: _select,
                  adaptiveBrightness: true,
                  tabs: [
                    for (final d in _destinations)
                      GlassTab(
                        icon: Icon(d.icon),
                        activeIcon: Icon(d.selectedIcon),
                        label: d.label,
                      ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      );
    }

    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Scaffold(
      body: body,
      bottomNavigationBar: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: _navVisible
            ? Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 12 + bottomInset),
                child: Material(
                  elevation: 3,
                  shadowColor: Theme.of(context)
                      .colorScheme
                      .shadow
                      .withValues(alpha: 0.18),
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  shape: const StadiumBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: NavigationBar(
                    selectedIndex: _index,
                    onDestinationSelected: _select,
                    indicatorShape: const StadiumBorder(),
                    height: 72,
                    labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                    backgroundColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                    destinations: [
                      for (final d in _destinations)
                        NavigationDestination(
                          icon: Icon(d.icon),
                          selectedIcon: Icon(d.selectedIcon),
                          label: d.label,
                        ),
                    ],
                  ),
                ),
              )
            : const SizedBox(width: double.infinity),
      ),
    );
  }
}

class _Dest {
  const _Dest({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class _PlaceholderTab extends StatelessWidget {
  const _PlaceholderTab({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(label)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              '$label 页面开发中',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
