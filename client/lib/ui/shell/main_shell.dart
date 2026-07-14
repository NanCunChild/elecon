/// 主界面壳——悬浮底部导航岛 + 四页切换。
///
/// 导航栏采用浮动胶囊样式，不贴边（horizontal padding + 圆角），
/// 向下滚动时折叠收起、向上滚动时重新浮现。
///
/// 走形修复要点：
/// - 用 [Material] `clipBehavior` 裁剪，避免选中指示器 / 水波纹溢出圆角。
/// - 隐藏用 [AnimatedSize] 折叠槽位（而非 AnimatedSlide 平移），收起时不留白带。
/// - 采用 M3 `surfaceContainer` 层 + 柔化阴影，高度留足以免标签拥挤。
library;

import 'package:flutter/material.dart';

import '../home/home_page.dart';
import '../settings/settings_page.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  bool _navVisible = true;

  static const _scrollThreshold = 10.0;

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification) return false;
    final delta = notification.scrollDelta ?? 0;
    if (delta > _scrollThreshold && _navVisible) {
      setState(() => _navVisible = false);
    } else if (delta < -_scrollThreshold && !_navVisible) {
      setState(() => _navVisible = true);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: IndexedStack(
          index: _currentIndex,
          children: const [
            EleconHomePage(),
            _PlaceholderTab(icon: Icons.schedule, label: '课表'),
            _PlaceholderTab(icon: Icons.notifications_outlined, label: '通知'),
            SettingsPage(),
          ],
        ),
      ),
      // AnimatedSize 折叠：隐藏时槽位高度归零，底部不留空白带。
      bottomNavigationBar: AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        alignment: Alignment.topCenter,
        child: _navVisible
            ? _FloatingNavIsland(
                currentIndex: _currentIndex,
                onSelected: (i) => setState(() => _currentIndex = i),
              )
            : const SizedBox(width: double.infinity),
      ),
    );
  }
}

class _FloatingNavIsland extends StatelessWidget {
  const _FloatingNavIsland({
    required this.currentIndex,
    required this.onSelected,
  });

  final int currentIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 手势导航条留白计入内边距，避免悬浮岛贴住系统条。
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 12 + bottomInset),
      child: Material(
        color: theme.colorScheme.surfaceContainer,
        surfaceTintColor: theme.colorScheme.surfaceTint,
        shadowColor: Colors.black.withValues(alpha: 0.2),
        elevation: 3,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias, // 裁剪指示器 / 水波纹，修圆角破形
        child: NavigationBar(
          selectedIndex: currentIndex,
          onDestinationSelected: onSelected,
          indicatorShape: const StadiumBorder(),
          height: 72,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: '首页',
            ),
            NavigationDestination(
              icon: Icon(Icons.calendar_today_outlined),
              selectedIcon: Icon(Icons.calendar_today),
              label: '课表',
            ),
            NavigationDestination(
              icon: Icon(Icons.campaign_outlined),
              selectedIcon: Icon(Icons.campaign),
              label: '通知',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '设置',
            ),
          ],
        ),
      ),
    );
  }
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
            Text('$label 页面开发中',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.outline)),
          ],
        ),
      ),
    );
  }
}
