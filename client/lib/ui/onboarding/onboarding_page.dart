/// 开始面板：首次进入选择学校 → 发起登录收割 → 进入主界面。
///
/// 选校后调用 [runSchoolLogin]（核心托管 WebView 收割），无论登录成功 / 取消都
/// 完成选校进入主壳；未登录状态由设置页呈现并可再次登录。
library;

import 'package:flutter/material.dart';

import '../../catalog/schools.dart';
import '../../session/session_scope.dart';
import '../login/login_flow.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, this.loginRunner = runSchoolLogin});

  final SchoolLoginRunner loginRunner;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  SchoolDescriptor? _selected;
  bool _busy = false;

  Future<void> _continue() async {
    final session = SessionScope.of(context);
    final selected = _selected;
    if (selected == null) return;
    setState(() => _busy = true);
    final result = await widget.loginRunner(context, session, selected);
    if (!mounted) return;
    setState(() => _busy = false);

    // 无论成功/取消，都完成选校进入主壳（未登录态由设置页呈现）。
    session.selectSchool(selected);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(loginResultMessage(result, session))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final schools = SessionScope.of(context).availableSchools;
    _selected ??= schools.firstOrNull;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
              shrinkWrap: true,
              children: [
                Icon(
                  Icons.school_rounded,
                  size: 56,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 20),
                Text(
                  '欢迎使用 elecon',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  '校园信息聚合平台\n选择你的学校，登录后即可聚合成绩、课表、通知等信息',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  '选择学校',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                for (final school in schools)
                  _SchoolTile(
                    school: school,
                    selected: _selected?.id == school.id,
                    onTap: school.available && !_busy
                        ? () => setState(() => _selected = school)
                        : null,
                  ),
                const SizedBox(height: 8),
                _ComingSoonTile(),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: _busy || _selected == null ? null : _continue,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: Text(_busy ? '登录中…' : '登录并进入'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '凭证仅保存在本机可信核心，绝不上传（红线 #1）',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SchoolTile extends StatelessWidget {
  const _SchoolTile({
    required this.school,
    required this.selected,
    required this.onTap,
  });

  final SchoolDescriptor school;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: selected ? theme.colorScheme.primaryContainer : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.account_balance,
                  color: selected
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      school.displayName,
                      style: theme.textTheme.titleMedium,
                    ),
                    Text(
                      school.subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComingSoonTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Icon(Icons.more_horiz, size: 18, color: theme.colorScheme.outline),
          const SizedBox(width: 8),
          Text(
            '更多学校陆续接入中',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
