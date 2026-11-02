import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/settings/script_accounts_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'login_entry_test.dart' show until;

ScriptPackage accountPackage(
  String id, {
  String school = 'synthetic',
  bool legacy = false,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': legacy ? 3 : 11,
      'id': id,
      'schoolId': school,
      'version': '1.0.0',
      'name': 'Script $id',
      'browser': false,
      'network': {'origins': []},
      'capabilities': [
        {
          'id': 'generic.section',
          'schema': 'elecon.generic.section',
          'schemaVersion': '1.0',
        },
      ],
      if (!legacy)
        'accounts': [
          {
            'id': 'account',
            'name': 'Account $id',
            'instructions': 'Official sign-in instructions for $id.',
            'capabilities': ['generic.section'],
            'login': {'capability': 'generic.section'},
          },
        ],
    },
    'source':
        '''export const capabilities={'generic.section':async(ctx)=>{
      await ctx.credentials.set('session','SYNTHETIC_$id');
      return {sectionId:'login',title:'Signed in'};
    }};''',
  }),
);

void main() {
  setUpAll(() async {
    final package = accountPackage('warmup');
    await const TrustedScriptRuntime().run(
      package: package,
      capability: 'generic.section',
      credentials: ScriptCredentials(
        store: CredentialStore(store: InMemorySecureStore(releaseMode: false)),
        schoolId: package.manifest.schoolId,
        scriptId: package.manifest.id,
        sdkVersion: package.manifest.sdkVersion,
      ),
      fetch: (_, _) async => throw StateError('no network in fixture'),
    );
  });
  for (final locale in ['zh', 'en']) {
    testWidgets(
      'accounts are discovered without execution and login stays with its script ($locale)',
      (tester) async {
        final session = SessionController();
        addTearDown(session.dispose);
        final first = accountPackage('first');
        final second = accountPackage('second');
        final other = accountPackage('other', school: 'other-school');
        for (final package in [first, second, other]) {
          await session.installTrustedScript(
            package,
            approvedDigest: package.digest,
          );
        }
        await session.selectTrustedScriptSchool('first');
        await tester.pumpWidget(
          SessionScope(
            controller: session,
            child: MaterialApp(
              locale: Locale(locale),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const ScriptAccountsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l10n = AppLocalizations.of(
          tester.element(find.byType(ScriptAccountsPage)),
        );
        expect(find.text('Account first'), findsOneWidget);
        expect(find.text('Account second'), findsOneWidget);
        expect(find.text('Account other'), findsNothing);
        expect(
          find.text('Official sign-in instructions for second.'),
          findsOneWidget,
        );
        expect(session.credentialCount, 0);
        final secondButton = find.byKey(
          const ValueKey('account-login:second:account'),
        );
        await tester.scrollUntilVisible(
          secondButton,
          160,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(secondButton);
        await until(
          tester,
          () =>
              session.credentialCount == 1 &&
              find.byType(ScriptAccountsPage).evaluate().isNotEmpty &&
              find
                  .text(l10n.scriptAccountsSigningIn('Account second'))
                  .evaluate()
                  .isEmpty,
        );
        await tester.pumpAndSettle();
        expect(session.credentialRefs.single, contains(':second:'));
        expect(session.credentialRefs.single, isNot(contains(':first:')));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'legacy requirements stay unspecified and disabled scripts cannot log in',
    (tester) async {
      final session = SessionController();
      addTearDown(session.dispose);
      final legacy = accountPackage('legacy', legacy: true);
      final disabled = accountPackage('inactive');
      for (final p in [legacy, disabled]) {
        await session.installTrustedScript(p, approvedDigest: p.digest);
      }
      await session.selectTrustedScriptSchool('legacy');
      await session.enableTrustedScript('inactive', false);
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
      await tester.pumpAndSettle();
      expect(
        find.textContaining('has not declared account requirements'),
        findsOneWidget,
      );
      expect(find.text('Script disabled'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Sign in'))
            .onPressed,
        isNull,
      );
      expect(session.credentialCount, 0);
    },
  );
}
