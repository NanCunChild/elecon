/// 设置页——随会话状态更新：当前学校、登录状态、凭证、调试选项。
///
/// 显示文案一律取 [AppLocalizations]（`lib/l10n/*.arb`），不在此写字面量。
library;

import 'package:flutter/material.dart';

import 'package:flutter/foundation.dart';

import '../../app_info.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart' show SessionCredentialProtection;
import '../../session/session_scope.dart';
import '../login/login_flow.dart';
import '../debug/helloworld_test_page.dart';
import '../theme/liquid_glass.dart';
import 'about_page.dart';
import 'appearance_section.dart';
import 'dev_log_page.dart';
import 'privacy_policy_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Future<void> _login(BuildContext context) async {
    final session = SessionScope.of(context);
    final school = session.selectedSchool;
    if (school == null) return;
    final result = await runSchoolLogin(context, session, school);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(loginResultMessage(result, session))),
    );
  }

  Future<void> _logout(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final session = SessionScope.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.settingsLogoutDialogTitle),
        content: Text(l10n.settingsLogoutDialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.settingsActionLogout),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    session.logout();
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.settingsLogoutDone)));
  }

  Future<void> _switchSchool(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final session = SessionScope.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.settingsSwitchSchoolDialogTitle),
        content: Text(l10n.settingsSwitchSchoolDialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.settingsSwitchSchoolConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    session.reset();
  }

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    // 监听会话变化，状态更新时本页重建。
    final l10n = AppLocalizations.of(context);
    final session = SessionScope.of(context);
    final school = session.selectedSchool;
    final loggedIn = session.isLoggedIn;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          liquidGlassEnabled(context) ? 100 : 24,
        ),
        children: [
          _SectionTitle(title: l10n.settingsSectionAccount),
          LiquidGlassSurface(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.school),
                  title: Text(school?.displayName ?? l10n.settingsNoSchool),
                  subtitle: Text(
                    school?.subtitle ?? l10n.settingsNoSchoolSubtitle,
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    loggedIn ? Icons.verified_user : Icons.lock_outline,
                    color: loggedIn
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outline,
                  ),
                  title: Text(
                    loggedIn ? l10n.settingsLoggedIn : l10n.settingsLoggedOut,
                  ),
                  subtitle: Text(
                    loggedIn
                        ? l10n.settingsCredentialSummary(
                            session.credentialCount,
                            session.credentialRefs.join(
                              l10n.commonListSeparator,
                            ),
                          )
                        : l10n.settingsLoginPrompt,
                  ),
                  trailing: loggedIn
                      ? TextButton(
                          onPressed: () => _logout(context),
                          child: Text(l10n.settingsActionLogout),
                        )
                      : FilledButton.tonal(
                          onPressed: () => _login(context),
                          child: Text(l10n.settingsActionLogin),
                        ),
                ),
                if (loggedIn) ...[
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.security_outlined),
                    title: Text(l10n.settingsProtectionTitle),
                    subtitle: Text(switch (session.credentialProtection) {
                      SessionCredentialProtection.hardware =>
                        l10n.settingsProtectionHardware,
                      SessionCredentialProtection.software =>
                        l10n.settingsProtectionSoftware,
                      SessionCredentialProtection.memory =>
                        l10n.settingsProtectionMemory,
                      SessionCredentialProtection.mixed =>
                        l10n.settingsProtectionMixed,
                      null => l10n.settingsProtectionMemory,
                    }),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: Text(l10n.settingsRelogin),
                    subtitle: Text(l10n.settingsReloginSubtitle),
                    onTap: () => _login(context),
                  ),
                ],
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.swap_horiz),
                  title: Text(l10n.settingsSwitchSchool),
                  onTap: () => _switchSchool(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const AppearanceSection(),
          const SizedBox(height: 16),
          _SectionTitle(title: l10n.settingsSectionDebug),
          LiquidGlassSurface(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: Text(l10n.settingsDevLogTitle),
                  subtitle: Text(
                    kDebugMode
                        ? l10n.settingsDevLogSubtitleDebug
                        : l10n.settingsDevLogSubtitleRelease,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(context, const DevLogPage()),
                ),
                if (kDebugMode) ...[
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.route_outlined),
                    title: Text(l10n.settingsHelloWorldTitle),
                    subtitle: Text(l10n.settingsHelloWorldSubtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(context, const HelloWorldTestPage()),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(Icons.bug_report_outlined),
                    title: Text(l10n.settingsWebViewLogTitle),
                    subtitle: Text(l10n.settingsWebViewLogSubtitle),
                    value: session.debugLog,
                    onChanged: session.setDebugLog,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle(title: l10n.settingsSectionAbout),
          LiquidGlassSurface(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text(l10n.settingsAboutTile),
                  subtitle: Text(l10n.aboutVersion(kAppVersion)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(context, const AboutPage()),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: Text(l10n.settingsPrivacyTile),
                  subtitle: Text(l10n.settingsPrivacySubtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(context, const PrivacyPolicyPage()),
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
