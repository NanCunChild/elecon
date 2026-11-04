/// ADR-076: source changes give immediate feedback and source-bound checks.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/scripts/manifest.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../settings/script_accounts_page.dart';

Future<void> selectScriptWithFeedback(
  BuildContext context,
  SessionController session,
  Future<ScriptPackage?> Function() select,
) async {
  // Onboarding can disappear as soon as selection is published.
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final l10n = AppLocalizations.of(context);
  final package = await select();
  if (package == null || !messenger.mounted) return;
  final selected = l10n.scriptsSelectionChanged(package.manifest.name);
  void show(String message, {bool accounts = false, bool completed = false}) {
    if (!messenger.mounted) return;
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        key: ValueKey(
          'script-selection-${package.digest}-${completed ? 'complete' : 'checking'}',
        ),
        content: Text(message),
        duration: const Duration(seconds: 12),
        action: accounts
            ? SnackBarAction(
                label: l10n.scriptAccountsTitle,
                onPressed: () {
                  if (navigator.mounted &&
                      session.selectedSchool?.id == package.manifest.schoolId) {
                    navigator.push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ScriptAccountsPage(),
                      ),
                    );
                  }
                },
              )
            : null,
      ),
    );
  }

  if (session.selectedSchool?.id != package.manifest.schoolId) {
    show('$selected\n${l10n.scriptsSchoolRequired}');
    return;
  }
  show('$selected\n${l10n.scriptAccountChecking}');
  Future<void> check() async {
    final results = await session.checkTrustedScriptAccounts(package);
    if (results == null) return;
    final detail = !package.manifest.declaresAccounts
        ? l10n.scriptAccountsUndeclared
        : results.isEmpty
        ? l10n.scriptAccountsNone
        : package.manifest.accounts
              .map((account) {
                final state = switch (results[account.id]) {
                  'authenticated' => l10n.scriptAccountAuthenticated,
                  'signedOut' => l10n.scriptAccountSignedOut,
                  'expired' => l10n.scriptAccountExpired,
                  'unknown' => l10n.scriptAccountUnknown,
                  _ => l10n.scriptsAccountCheckUnavailable,
                };
                return '${account.name}: $state';
              })
              .join('\n');
    show('$selected\n$detail', accounts: results.isNotEmpty, completed: true);
  }

  // A status request must not lock navigation while a school is unreachable.
  unawaited(check());
}
