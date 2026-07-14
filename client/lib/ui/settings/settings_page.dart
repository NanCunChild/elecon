/// 设置页——随会话状态更新：当前学校、登录状态、凭证、调试选项。
library;

import 'package:flutter/material.dart';

import '../../session/session_scope.dart';
import '../login/login_flow.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Future<void> _login(BuildContext context) async {
    final session = SessionScope.of(context);
    final school = session.selectedSchool;
    if (school == null) return;
    final result = await runSchoolLogin(context, session, school);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(loginResultMessage(result, session))));
  }

  Future<void> _logout(BuildContext context) async {
    final session = SessionScope.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('将立即抹除本机保存的全部凭证，需要重新登录。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('退出')),
        ],
      ),
    );
    if (confirmed != true) return;
    session.logout();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已退出登录，凭证已抹除')));
  }

  Future<void> _switchSchool(BuildContext context) async {
    final session = SessionScope.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切换学校'),
        content: const Text('将抹除当前凭证并返回学校选择面板。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('切换')),
        ],
      ),
    );
    if (confirmed != true) return;
    session.reset();
  }

  @override
  Widget build(BuildContext context) {
    // 监听会话变化，状态更新时本页重建。
    final session = SessionScope.of(context);
    final school = session.selectedSchool;
    final loggedIn = session.isLoggedIn;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _SectionTitle(title: '账户'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.school),
                  title: Text(school?.displayName ?? '未选择学校'),
                  subtitle: Text(school?.subtitle ?? '返回开始面板选择学校'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    loggedIn ? Icons.verified_user : Icons.lock_outline,
                    color: loggedIn
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outline,
                  ),
                  title: Text(loggedIn ? '已登录' : '未登录'),
                  subtitle: Text(loggedIn
                      ? '已收割 ${session.credentialCount} 条凭证：${session.credentialRefs.join("、")}'
                      : '登录后聚合校园信息'),
                  trailing: loggedIn
                      ? TextButton(
                          onPressed: () => _logout(context),
                          child: const Text('退出'),
                        )
                      : FilledButton.tonal(
                          onPressed: () => _login(context),
                          child: const Text('登录'),
                        ),
                ),
                if (loggedIn) ...[
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text('重新登录'),
                    subtitle: const Text('会话过期时刷新凭证'),
                    onTap: () => _login(context),
                  ),
                ],
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.swap_horiz),
                  title: const Text('切换学校'),
                  onTap: () => _switchSchool(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle(title: '调试'),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.bug_report_outlined),
              title: const Text('WebView 日志面板'),
              subtitle: const Text('登录时显示带时间戳的收割日志（cookie 已打码）'),
              value: session.debugLog,
              onChanged: session.setDebugLog,
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle(title: '关于'),
          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('elecon'),
                  subtitle: Text('校园信息聚合平台'),
                ),
                const Divider(height: 1),
                const ListTile(
                  leading: Icon(Icons.code),
                  title: Text('版本'),
                  subtitle: Text('0.1.0-dev'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
