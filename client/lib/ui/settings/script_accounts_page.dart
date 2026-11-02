import 'package:flutter/material.dart';

import '../../core/scripts/registry.dart';
import '../../core/scripts/manifest.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import '../login/script_login_page.dart';
import '../login/webview_login_page.dart';

/// ADR-066: declarations identify each source; only its explicit status entry runs.
class ScriptAccountsPage extends StatefulWidget {
  const ScriptAccountsPage({super.key});

  @override
  State<ScriptAccountsPage> createState() => _ScriptAccountsPageState();
}

class _ScriptAccountsPageState extends State<ScriptAccountsPage> {
  SessionController? _session;
  Future<ScriptRegistry>? _registry;
  int _refresh = 0;

  Future<void> _login(
    ScriptInstallation installation,
    ScriptAccount account,
  ) async {
    final session = _session!;
    final school = session.selectedSchool;
    if (school == null) return;
    final result = await Navigator.of(context).push<WebViewLoginResult>(
      MaterialPageRoute(
        builder: (_) => ScriptLoginPage(
          session: session,
          school: school,
          package: installation.package,
          accountId: account.id,
        ),
      ),
    );
    if (!mounted ||
        !identical(session, _session) ||
        session.selectedSchool?.id != school.id) {
      return;
    }
    setState(() => _refresh++);
    final l10n = AppLocalizations.of(context);
    final message = switch (result?.status) {
      WebViewLoginStatus.success => l10n.scriptAccountsLoginSucceeded,
      WebViewLoginStatus.cancelled || null => l10n.scriptAccountsLoginCancelled,
      WebViewLoginStatus.error => result?.error ?? l10n.scriptsLoginFailed,
    };
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.of(context);
    if (!identical(session, _session)) {
      _session = session;
      _registry = session.scriptRegistry;
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final school = session.selectedSchool;
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.scriptAccountsTitle)),
      body: FutureBuilder<ScriptRegistry>(
        future: _registry,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text(l10n.scriptAccountsLoadFailed));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final installations = snapshot.data!.installations
              .where((i) => i.package.manifest.schoolId == school?.id)
              .toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(l10n.scriptAccountsDescription),
              const SizedBox(height: 16),
              if (installations.isEmpty) Text(l10n.scriptAccountsEmpty),
              for (final installation in installations) ...[
                Text(
                  installation.package.manifest.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  installation.package.manifest.id,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (!installation.enabled) Text(l10n.scriptAccountsDisabled),
                if (installation.package.requiresUpdate)
                  Text(l10n.scriptAccountsUpdateRequired),
                if (!installation.package.manifest.declaresAccounts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(l10n.scriptAccountsUndeclared),
                  )
                else if (installation.package.manifest.accounts.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(l10n.scriptAccountsNone),
                  ),
                for (final account in installation.package.manifest.accounts)
                  _AccountCard(
                    key: ValueKey(
                      '${school?.id}:${session.trustedScriptViewGeneration}:$_refresh:${installation.package.digest}:${account.id}',
                    ),
                    session: session,
                    installation: installation,
                    account: account,
                    onLogin: () => _login(installation, account),
                  ),
                const SizedBox(height: 24),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _AccountCard extends StatefulWidget {
  const _AccountCard({
    super.key,
    required this.session,
    required this.installation,
    required this.account,
    required this.onLogin,
  });
  final SessionController session;
  final ScriptInstallation installation;
  final ScriptAccount account;
  final Future<void> Function() onLogin;
  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  ScriptRunCancellation? _cancellation;
  Map<String, dynamic>? _state;
  bool _checking = false;
  bool _loggingIn = false;
  bool get _available =>
      widget.installation.enabled &&
      !widget.installation.package.requiresUpdate &&
      widget.session.selectedSchool?.id ==
          widget.installation.package.manifest.schoolId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    final account = widget.account;
    if (!mounted ||
        !_available ||
        account.statusCapability == null ||
        _checking) {
      return;
    }
    final cancellation = ScriptRunCancellation();
    _cancellation?.cancel();
    _cancellation = cancellation;
    setState(() => _checking = true);
    final result = await widget.session.runTrustedScript(
      widget.installation.package.manifest.id,
      account.statusCapability!,
      expectedDigest: widget.installation.package.digest,
      params: account.statusParams,
      cancellation: cancellation,
    );
    if (!mounted ||
        cancellation.isCancelled ||
        !identical(cancellation, _cancellation)) {
      return;
    }
    setState(() {
      _checking = false;
      _state = result.ok && result.data is Map
          ? Map<String, dynamic>.from(result.data as Map)
          : {'status': 'unknown'};
    });
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final account = widget.account;
    final status = _state?['status'];
    final signedIn = status == 'authenticated';
    final description = _checking
        ? l10n.scriptAccountChecking
        : switch (status) {
            'authenticated' => l10n.scriptAccountAuthenticated,
            'signedOut' => l10n.scriptAccountSignedOut,
            'expired' => l10n.scriptAccountExpired,
            _ => l10n.scriptAccountUnknown,
          };
    final label = _state?['accountLabel'];
    final id = _state?['accountId'];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(account.name, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(account.instructions),
            const SizedBox(height: 8),
            Text(
              l10n.scriptAccountsUsedBy(
                account.capabilities
                    .map((id) => _purpose(l10n, id))
                    .toSet()
                    .join(l10n.commonListSeparator),
              ),
            ),
            if (account.statusCapability != null) ...[
              const SizedBox(height: 8),
              Text(
                description,
                key: ValueKey('account-state:${account.id}'),
                style: status == 'expired'
                    ? TextStyle(color: Theme.of(context).colorScheme.error)
                    : null,
              ),
              if (signedIn && label is String && label.isNotEmpty) Text(label),
              if (signedIn && id is String && id.isNotEmpty && id != label)
                Text(id),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (account.loginCapability != null)
                  FilledButton.tonal(
                    key: ValueKey(
                      'account-login:${widget.installation.package.manifest.id}:${account.id}',
                    ),
                    onPressed: !_available || _checking || _loggingIn
                        ? null
                        : () async {
                            setState(() => _loggingIn = true);
                            try {
                              await widget.onLogin();
                            } finally {
                              if (mounted) setState(() => _loggingIn = false);
                            }
                          },
                    child: Text(
                      signedIn
                          ? l10n.scriptAccountRelogin
                          : l10n.settingsActionLogin,
                    ),
                  ),
                if (account.statusCapability != null)
                  TextButton(
                    onPressed: !_available || _checking || _loggingIn
                        ? null
                        : _check,
                    child: Text(l10n.scriptAccountCheck),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _purpose(AppLocalizations l10n, String id) => switch (id) {
  'schedule.week' ||
  'term.list' ||
  'calendar.academic' => l10n.homeScheduleTitle,
  'grades.list' => l10n.homeGradesTitle,
  'exam.list' => l10n.homeExamTitle,
  'classroom.buildings' || 'classroom.available' => l10n.homeClassroomTitle,
  'card.balance' || 'card.transactions' || 'card.qr' => l10n.homeCardTitle,
  'library.loans' => l10n.homeLibraryLoansTitle,
  'energy.meters' || 'energy.usage' => l10n.energyTitle,
  'climate.devices' ||
  'climate.status' ||
  'climate.command' => l10n.climateTitle,
  'notice.list' || 'notice.detail' => l10n.homeNoticeTitle,
  'faculty.search' => l10n.facultyTitle,
  'forum.session' => l10n.navForum,
  'messages.session' ||
  'messages.list' ||
  'messages.conversations' ||
  'messages.history' ||
  'messages.send' => l10n.navMessages,
  'attendance.checkin' => l10n.homeCheckinTitle,
  'generic.section' || 'account.session' => l10n.settingsActionLogin,
  _ => id,
};
