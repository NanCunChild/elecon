import 'dart:convert';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/settings/script_accounts_page.dart';
import 'package:elecon/ui/login/script_login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'login_entry_test.dart' show until;
import 'account_state_test.dart' as runtime;
import '../transport/hermes_account_test.dart' show FakeHermes, save;
import 'package:elecon/ui/settings/app_tunnel_page.dart';

ScriptPackage fixture(String status) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'id': 'synthetic',
      'schoolId': 'synthetic',
      'name': 'Synthetic',
      'version': '1.0.0',
      'sdkVersion': 12,
      'browser': false,
      'network': {'origins': []},
      'capabilities': [
        {
          'id': 'account.session',
          'schema': 'elecon.account.session',
          'schemaVersion': '1.0',
        },
      ],
      'accounts': [
        {
          'id': 'account',
          'name': 'Synthetic account',
          'instructions': 'Use synthetic credentials only.',
          'capabilities': ['account.session'],
          'status': {
            'capability': 'account.session',
            'params': {'account': 'account', 'operation': 'status'},
          },
          'login': {
            'capability': 'account.session',
            'params': {'account': 'account', 'operation': 'login'},
          },
        },
      ],
    },
    'source':
        """export const capabilities={'account.session':async(ctx,p)=>{
    if(p.operation==='login') await ctx.credentials.set('identity','replacement');
    const value=await ctx.credentials.get('identity');
    if(value) return {status:'authenticated',accountId:'replacement-id',accountLabel:'Replacement'};
    return {status:'$status',...( '$status'==='authenticated' ? {accountLabel:'Original',accountId:'original-id'} : {})};
  }};""",
  }),
);
void main() {
  setUpAll(() async {
    await runtime.run(fixture('signedOut'));
  });
  testWidgets(
    'declared tunnel login stays open through credential rotation and rechecks on return',
    (tester) async {
      final native = FakeHermes()
        ..checkResult = {
          'status': 'authenticated',
          'accountLabel': 'Verified tunnel',
        };
      final session = SessionController(hermesBinding: native);
      addTearDown(session.dispose);
      final value =
          jsonDecode(fixture('signedOut').encode()) as Map<String, dynamic>;
      (value['manifest'] as Map)['appTunnels'] = ['hermes-atrust'];
      value['source'] =
          "export const capabilities={'account.session':async(ctx,p)=>ctx.appTunnel[p.operation]('hermes-atrust')};";
      final package = ScriptPackage.parse(jsonEncode(value));
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
      await session.selectTrustedScriptSchool(package.manifest.id);
      await save(session);
      await tester.pumpWidget(
        SessionScope(
          controller: session,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const ScriptAccountsPage(),
          ),
        ),
      );
      await until(tester, () => find.text('Signed out').evaluate().isNotEmpty);
      await tester.tap(
        find.byKey(const ValueKey('account-login:synthetic:account')),
      );
      await until(
        tester,
        () => find.byType(AppTunnelPage).evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(AppTunnelPage)),
      );
      final login = find.widgetWithText(
        FilledButton,
        l10n.appTunnelAccountLogin,
      );
      await tester.scrollUntilVisible(
        login,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(login);
      await until(tester, () => session.hermesConfigurationInfo() != null);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(AppTunnelPage), findsOneWidget);
      expect(await session.appTunnelChoice(), isNull);
      await tester.pageBack();
      await until(
        tester,
        () =>
            find.text('Verified tunnel').evaluate().isNotEmpty &&
            find.byType(ScriptLoginPage).evaluate().isEmpty,
      );
      expect(find.text('Sign in again'), findsOneWidget);
      // Leaving the host page without a new authentication is cancellation,
      // even though the previous remote session is still authenticated.
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('account-login:synthetic:account')),
      );
      await until(
        tester,
        () => find.byType(AppTunnelPage).evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      await tester.pageBack();
      await until(
        tester,
        () =>
            find.text(l10n.scriptAccountsLoginCancelled).evaluate().isNotEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final status in ['authenticated', 'signedOut', 'expired', 'unknown']) {
    testWidgets('account page renders $status and rechecks explicit login', (
      tester,
    ) async {
      final package = fixture(status);
      final session = SessionController();
      addTearDown(session.dispose);
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
      await session.selectTrustedScriptSchool(package.manifest.id);
      await tester.pumpWidget(
        SessionScope(
          controller: session,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const ScriptAccountsPage(),
          ),
        ),
      );
      final expected = switch (status) {
        'authenticated' => 'Signed in',
        'signedOut' => 'Signed out',
        'expired' => 'Your session has expired. Please sign in again.',
        _ => 'Sign-in status is unknown. Check again or sign in.',
      };
      await until(tester, () => find.text(expected).evaluate().isNotEmpty);
      expect(session.credentialCount, 0);
      expect(
        find.text(status == 'authenticated' ? 'Sign in again' : 'Sign in'),
        findsOneWidget,
      );
      if (status == 'authenticated') {
        expect(find.text('Original'), findsOneWidget);
        expect(find.text('original-id'), findsOneWidget);
      }
      await tester.tap(
        find.byKey(const ValueKey('account-login:synthetic:account')),
      );
      await until(
        tester,
        () =>
            find.text('Replacement').evaluate().isNotEmpty &&
            find.byType(ScriptLoginPage).evaluate().isEmpty,
      );
      expect(find.text('replacement-id'), findsOneWidget);
      expect(find.text('Sign in again'), findsOneWidget);
      expect(find.text('Original'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
