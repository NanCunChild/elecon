import 'package:elecon/core/scripts/account_auth.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/settings/script_accounts_page.dart';
import 'package:elecon/ui/login/script_login_page.dart';
import 'package:elecon/ui/scripts/script_password_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'account_password_test.dart' show passwordPackage;
import 'login_entry_test.dart' show until;

Widget localized(Widget child, [String language = 'en']) => MaterialApp(
  locale: Locale(language),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  setUpAll(() async {
    final p = passwordPackage(
      source:
          "export const capabilities={'account.session':async()=>({status:'signedOut'})};",
    );
    await const TrustedScriptRuntime().run(
      package: p,
      capability: 'account.session',
      credentials: ScriptCredentials(
        store: CredentialStore(),
        schoolId: 'synthetic',
        scriptId: p.manifest.id,
        sdkVersion: 14,
      ),
      fetch: (_, _) async => throw StateError('no traffic'),
    );
  });
  for (final language in ['zh', 'en', 'uz', 'ru', 'fa']) {
    testWidgets(
      'password form is localized, private and cancellable ($language)',
      (tester) async {
        ScriptPasswordInput? result;
        await tester.pumpWidget(
          localized(
            Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await presentScriptPassword(
                      context,
                      const ScriptPasswordPrompt(
                        accountName: 'Synthetic account',
                        username: 'EXAMPLE_USER',
                        hasSavedPassword: true,
                        blocked: true,
                        allowWeb: true,
                      ),
                      () => true,
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
            language,
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(ScriptPasswordDialog));
        final l10n = AppLocalizations.of(context);
        expect(find.text(l10n.accountPasswordTitle), findsOneWidget);
        final password = tester.widget<TextField>(
          find.byKey(const ValueKey('account-password-secret')),
        );
        expect(password.obscureText, isTrue);
        expect(password.controller!.text, isEmpty);
        expect(
          Directionality.of(context),
          language == 'fa' ? TextDirection.rtl : TextDirection.ltr,
        );
        await tester.tap(find.text(l10n.commonCancel));
        await tester.pumpAndSettle();
        expect(result, isNull);
        expect(find.byType(ScriptPasswordDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'school account native login saves only verified value and deletion preserves session',
    (tester) async {
      final p = passwordPackage(
        source: '''export const capabilities={'account.session':async(ctx,p)=>{
      if(p.operation==='status')return {status:await ctx.credentials.get('verified')?'authenticated':'signedOut'};
      const pair=await ctx.accounts.password('school',{mode:'manual'});
      if(!pair){const e=new Error('input_cancelled');e.code=e.message;throw e;}
      if(pair.username!=='EXAMPLE_USER'||pair.password!=='EXAMPLE_PASSWORD')throw new Error('synthetic verification failed');
      await ctx.accounts.completePassword('school',{attemptId:pair.attemptId,outcome:'authenticated'});
      await ctx.credentials.set('verified','EXAMPLE_SESSION');
      return {status:'authenticated'};
    }};''',
      );
      final session = SessionController();
      addTearDown(session.dispose);
      await session.installTrustedScript(p, approvedDigest: p.digest);
      await session.selectTrustedScriptSchool(p.manifest.id);
      await tester.pumpWidget(
        SessionScope(
          controller: session,
          child: localized(const ScriptAccountsPage()),
        ),
      );
      await until(tester, () => find.text('Signed out').evaluate().isNotEmpty);
      await tester.tap(
        find.byKey(const ValueKey('account-login:synthetic.password:school')),
      );
      await until(
        tester,
        () => find.byType(ScriptPasswordDialog).evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(session.savedScriptAccount(p, 'school'), isNull);
      await tester.enterText(
        find.byKey(const ValueKey('account-password-username')),
        'EXAMPLE_USER',
      );
      await tester.enterText(
        find.byKey(const ValueKey('account-password-secret')),
        'EXAMPLE_PASSWORD',
      );
      await tester.tap(find.byKey(const ValueKey('account-password-submit')));
      await until(
        tester,
        () =>
            session.savedScriptAccount(p, 'school') != null &&
            find.byType(ScriptLoginPage).evaluate().isEmpty,
      );
      await tester.pumpAndSettle();
      expect(session.savedScriptAccount(p, 'school')!.username, 'EXAMPLE_USER');
      expect(
        session.credentialCount,
        1,
        reason:
            'password archive does not imply an authenticated school cookie',
      );
      expect(find.text('Account and password saved'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('account-login:synthetic.password:school')),
      );
      await until(
        tester,
        () => find.byType(ScriptPasswordDialog).evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('account-password-secret')),
            )
            .controller!
            .text,
        isEmpty,
      );
      final saved = find.byKey(const ValueKey('account-password-use-saved'));
      await tester.ensureVisible(saved);
      await tester.tap(saved);
      await until(
        tester,
        () => find.byType(ScriptLoginPage).evaluate().isEmpty,
      );
      await tester.pumpAndSettle();
      final delete = find.byKey(
        const ValueKey('account-delete-password:school'),
      );
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(session.savedScriptAccount(p, 'school'), isNull);
      expect(session.credentialCount, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'revoking invocation dismisses native password input and drops late value',
    (tester) async {
      var active = true;
      Object? error;
      await tester.pumpWidget(
        localized(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  try {
                    await presentScriptPassword(
                      context,
                      const ScriptPasswordPrompt(
                        accountName: 'Synthetic',
                        username: '',
                        hasSavedPassword: false,
                        blocked: false,
                        allowWeb: true,
                      ),
                      () => active,
                    );
                  } catch (e) {
                    error = e;
                  }
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('account-password-secret')),
        'SYNTHETIC_PENDING',
      );
      active = false;
      await tester.pump(const Duration(milliseconds: 70));
      await tester.pumpAndSettle();
      expect(find.byType(ScriptPasswordDialog), findsNothing);
      expect(
        error,
        isA<ScriptAccountException>().having(
          (e) => e.code,
          'code',
          'invocation_cancelled',
        ),
      );
    },
  );
}
