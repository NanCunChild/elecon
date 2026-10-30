/// 开始面板：首次进入选择学校 → 发起登录收割 → 进入主界面。
///
/// 选校后调用 [runSchoolLogin]（核心托管 WebView 收割），无论登录成功 / 取消都
/// 完成选校进入主壳；未登录状态由设置页呈现并可再次登录。
library;

import 'package:flutter/material.dart';

import '../../catalog/schools.dart';
import '../../session/session_scope.dart';
import '../../l10n/gen/app_localizations.dart';
import '../scripts/script_workbench_page.dart';
import '../scripts/bundled_scripts.dart';
import '../login/login_flow.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, this.loginRunner = runSchoolLogin});

  final SchoolLoginRunner loginRunner;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  SchoolDescriptor? _selected;
  BundledScriptSchool? _bundled = bundledScriptSchools.first;
  bool _busy = false;

  Future<void> _continue() async {
    final session = SessionScope.of(context);
    final bundled = _bundled;
    if (bundled != null) {
      setState(() => _busy = true);
      try {
        await installBundledSchool(context, session, bundled);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(context).scriptsFailed(
                  error is StateError
                      ? error.message.toString()
                      : 'bundled_script_unavailable',
                ),
              ),
            ),
          );
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    final selected = _selected;
    if (selected == null) return;
    setState(() => _busy = true);
    if (selected.adapterId.startsWith('script:')) {
      session.selectSchool(selected);
      if (mounted) setState(() => _busy = false);
      return;
    }
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
    final l10n = AppLocalizations.of(context);

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
                for (final school in bundledScriptSchools)
                  Card(
                    child: ListTile(
                      title: Text(school.label(l10n)),
                      subtitle: Text(l10n.scriptsBundled),
                      trailing: Icon(
                        _bundled == school
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      onTap: _busy
                          ? null
                          : () => setState(() {
                              _bundled = school;
                              _selected = null;
                            }),
                    ),
                  ),
                for (final school in schools.where(
                  (s) =>
                      !bundledLegacySchoolIds.contains(s.id) &&
                      !bundledScriptSchools.any((b) => b.id == s.id),
                ))
                  _SchoolTile(
                    school: school,
                    selected: _selected?.id == school.id,
                    onTap: school.available && !_busy
                        ? () => setState(() {
                            _selected = school;
                            _bundled = null;
                          })
                        : null,
                  ),
                const SizedBox(height: 8),
                _ComingSoonTile(),
                TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const ScriptWorkbenchPage(),
                          ),
                        ),
                  icon: const Icon(Icons.code),
                  label: Text(AppLocalizations.of(context).scriptsTitle),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: _busy || (_selected == null && _bundled == null)
                      ? null
                      : _continue,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: Text(
                    _busy
                        ? l10n.scriptsRunning
                        : _bundled != null ||
                              (_selected?.adapterId.startsWith('script:') ??
                                  false)
                        ? l10n.scriptsSelectAndEnter
                        : '登录并进入',
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  AppLocalizations.of(context).scriptsCredentialsLocal,
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
