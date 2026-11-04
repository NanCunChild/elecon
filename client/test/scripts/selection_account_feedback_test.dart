// Selection notifications survive onboarding removal and reject late checks.
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/scripts/script_selection_feedback.dart';
import 'package:elecon/ui/settings/script_accounts_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'selection_account_check_test.dart' show selectionPackage;

Future<void> until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 150; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Synthetic selection feedback did not settle');
}

Future<SessionController> install(WidgetTester tester, ScriptPackage p) async =>
    (await tester.runAsync(() async {
      final session = SessionController();
      await session.installTrustedScript(p, approvedDigest: p.digest);
      return session;
    }))!;

Widget app(
  SessionController session,
  ScriptPackage p, {
  ValueNotifier<bool>? onboarding,
}) => SessionScope(
  controller: session,
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) {
        Widget page(bool selecting) => Scaffold(
          body: selecting
              ? FilledButton(
                  onPressed: () =>
                      selectScriptWithFeedback(context, session, () async {
                        await session.selectTrustedScriptSchool(p.manifest.id);
                        onboarding?.value = false;
                        return p;
                      }),
                  child: const Text('Select synthetic script'),
                )
              : const Text('Synthetic home'),
        );
        return onboarding == null
            ? page(true)
            : ValueListenableBuilder<bool>(
                valueListenable: onboarding,
                builder: (_, selecting, _) => page(selecting),
              );
      },
    ),
  ),
);

void main() {
  for (final state in ['authenticated', 'signedOut', 'expired', 'unknown']) {
    testWidgets(
      'selection explicitly reports $state and offers account management',
      (tester) async {
        final p = selectionPackage(body: "return {status:'$state'};");
        final session = await install(tester, p);
        addTearDown(session.dispose);
        await tester.pumpWidget(app(session, p));
        final l10n = AppLocalizations.of(
          tester.element(find.byType(FilledButton)),
        );
        await tester.tap(find.text('Select synthetic script'));
        final expected = switch (state) {
          'authenticated' => l10n.scriptAccountAuthenticated,
          'signedOut' => l10n.scriptAccountSignedOut,
          'expired' => l10n.scriptAccountExpired,
          _ => l10n.scriptAccountUnknown,
        };
        await until(
          tester,
          () => find
              .textContaining('Synthetic school account: $expected')
              .evaluate()
              .isNotEmpty,
        );
        expect(
          find.textContaining(l10n.scriptsSelectionChanged(p.manifest.name)),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(SnackBarAction, l10n.scriptAccountsTitle),
          findsOneWidget,
        );
        if (state == 'signedOut') {
          await tester.pumpAndSettle();
          await tester.tap(
            find.widgetWithText(SnackBarAction, l10n.scriptAccountsTitle),
          );
          await until(
            tester,
            () => find.byType(ScriptAccountsPage).evaluate().isNotEmpty,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'no-account declaration differs from missing legacy declaration',
    (tester) async {
      for (final legacy in [true, false]) {
        final p = selectionPackage(
          sdk: legacy ? 10 : 14,
          accounts: legacy ? null : const [],
        );
        final session = await install(tester, p);
        try {
          await tester.pumpWidget(app(session, p));
          final l10n = AppLocalizations.of(
            tester.element(find.byType(FilledButton)),
          );
          await tester.tap(find.text('Select synthetic script'));
          final expected = legacy
              ? l10n.scriptAccountsUndeclared
              : l10n.scriptAccountsNone;
          await until(
            tester,
            () => find.textContaining(expected).evaluate().isNotEmpty,
          );
          expect(find.byType(SnackBarAction), findsNothing);
          expect(session.credentialCount, 0);
          await tester.pumpWidget(const SizedBox.shrink());
        } finally {
          session.dispose();
        }
      }
    },
  );

  testWidgets(
    'selection feedback survives the onboarding page being replaced',
    (tester) async {
      final p = selectionPackage();
      final session = await install(tester, p);
      final onboarding = ValueNotifier(true);
      addTearDown(session.dispose);
      addTearDown(onboarding.dispose);
      await tester.pumpWidget(app(session, p, onboarding: onboarding));
      final l10n = AppLocalizations.of(
        tester.element(find.byType(FilledButton)),
      );
      await tester.tap(find.text('Select synthetic script'));
      await until(
        tester,
        () => find
            .textContaining(l10n.scriptAccountSignedOut)
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text('Synthetic home'), findsOneWidget);
      expect(find.text('Select synthetic script'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('revoked source cannot replace feedback with a late success', (
    tester,
  ) async {
    final p = selectionPackage(
      body: '''
      await ctx.credentials.set('started','SYNTHETIC');
      await new Promise(resolve=>setTimeout(resolve,250));
      return {status:'authenticated'};
    ''',
    );
    final session = await install(tester, p);
    addTearDown(session.dispose);
    await tester.pumpWidget(app(session, p));
    final l10n = AppLocalizations.of(tester.element(find.byType(FilledButton)));
    await tester.tap(find.text('Select synthetic script'));
    await until(tester, () => session.credentialCount == 1);
    expect(find.textContaining(l10n.scriptAccountChecking), findsOneWidget);
    await tester.runAsync(
      () => session.enableTrustedScript(p.manifest.id, false),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 350)),
    );
    // The background check owns its QuickJS close timeout. Drain its queue
    // after advancing that bounded cleanup deadline before disposing the UI.
    var drained = false;
    final barrier = session
        .runTrustedScript(
          p.manifest.id,
          'account.session',
          params: const {'account': 'school', 'operation': 'status'},
        )
        .then((_) => drained = true);
    await tester.pump(const Duration(seconds: 7));
    await until(tester, () => drained);
    await barrier;
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'Synthetic school account: ${l10n.scriptAccountAuthenticated}',
      ),
      findsNothing,
    );
    expect(find.byType(SnackBarAction), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
