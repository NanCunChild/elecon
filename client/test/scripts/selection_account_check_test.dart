// Synthetic source-bound account checks through the production QuickJS bridge.
import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage selectionPackage({
  String id = 'synthetic.selection',
  String school = 'synthetic',
  String version = '1.0.0',
  int sdk = 14,
  List<String>? accounts = const ['school'],
  Set<String> withoutStatus = const {},
  String body = "return {status:'signedOut'};",
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'id': id,
      'schoolId': school,
      'name': 'Synthetic selection',
      'version': version,
      'sdkVersion': sdk,
      'browser': true,
      'network': {'origins': []},
      'capabilities': [
        {
          'id': 'account.session',
          'schema': 'elecon.account.session',
          'schemaVersion': '1.0',
        },
      ],
      if (accounts != null)
        'accounts': [
          for (final id in accounts)
            {
              'id': id,
              'name': 'Synthetic $id account',
              'instructions': 'Synthetic credentials only.',
              'capabilities': ['account.session'],
              'login': {
                'capability': 'account.session',
                'params': {'account': id, 'operation': 'login'},
              },
              if (!withoutStatus.contains(id))
                'status': {
                  'capability': 'account.session',
                  'params': {'account': id, 'operation': 'status'},
                },
            },
        ],
    },
    'source':
        "export const capabilities={'account.session':async(ctx,p)=>{$body}};",
  }),
);

Future<void> selectPackage(SessionController session, ScriptPackage p) async {
  await session.installTrustedScript(p, approvedDigest: p.digest);
  await session.selectTrustedScriptSchool(p.manifest.id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'all declared states survive; failure and absent status stay distinct',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      final p = selectionPackage(
        accounts: const [
          'authenticated',
          'signedout',
          'expired',
          'unknown',
          'failed',
          'missing',
        ],
        withoutStatus: const {'missing'},
        body: '''
        if(p.operation !== 'status' || p.account === 'missing') throw new Error('unexpected_invocation');
        if(p.account === 'failed') throw new Error('synthetic_failure');
        return {status:p.account === 'signedout' ? 'signedOut' : p.account};
      ''',
      );
      await selectPackage(session, p);
      expect(await session.checkTrustedScriptAccounts(p), {
        'authenticated': 'authenticated',
        'signedout': 'signedOut',
        'expired': 'expired',
        'unknown': 'unknown',
        'failed': 'unknown',
        'missing': null,
      });
    },
  );

  test(
    'legacy undeclared and explicitly empty accounts perform no invocation',
    () async {
      for (final legacy in [true, false]) {
        final session = SessionController();
        try {
          final p = selectionPackage(
            sdk: legacy ? 10 : 14,
            accounts: legacy ? null : const [],
            body:
                "await ctx.credentials.set('unexpected','SYNTHETIC'); return {status:'authenticated'};",
          );
          await selectPackage(session, p);
          expect(await session.checkTrustedScriptAccounts(p), isEmpty);
          expect(session.credentialCount, 0);
          expect(p.manifest.declaresAccounts, !legacy);
        } finally {
          session.dispose();
        }
      }
    },
  );

  test(
    'status checks never open browser, input, password or storage consent',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      var interactiveCalls = 0;
      session.scriptBrowserPresenter = (_, _) async {
        interactiveCalls++;
        return null;
      };
      session.scriptInputPresenter = (_, _) async {
        interactiveCalls++;
        return null;
      };
      session.scriptPasswordPresenter = (_, _, _) async {
        interactiveCalls++;
        return null;
      };
      session.scriptStorageConsent = () async {
        interactiveCalls++;
        return true;
      };
      final p = selectionPackage(
        accounts: const ['browser', 'input', 'password'],
        body: '''
        if(p.account === 'browser') await ctx.browser.open('https://synthetic.invalid');
        if(p.account === 'input') await ctx.ui.requestInput({title:'Synthetic',fields:[]});
        if(p.account === 'password') await ctx.accounts.password('password',{mode:'manual'});
        return {status:'authenticated'};
      ''',
      );
      await selectPackage(session, p);
      expect(await session.checkTrustedScriptAccounts(p), {
        'browser': 'unknown',
        'input': 'unknown',
        'password': 'unknown',
      });
      expect(interactiveCalls, 0);
    },
  );

  test(
    'raw input denial has a stable code and never opens a presenter',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      var calls = 0;
      session.scriptInputPresenter = (_, _) async {
        calls++;
        return null;
      };
      final p = selectionPackage(
        body: '''
      const result = JSON.parse(await globalThis.__script_input('{}'));
      return {status:'unknown',accountLabel:JSON.stringify(result)};
    ''',
      );
      await selectPackage(session, p);
      final result = await session.runTrustedScript(
        p.manifest.id,
        'account.session',
        expectedDigest: p.digest,
        params: {'account': 'school', 'operation': 'status'},
      );
      expect(result.reason, isNull);
      expect(jsonDecode((result.data as Map)['accountLabel'] as String), {
        'ok': false,
        'error': {'code': 'input_unavailable', 'category': 'internal'},
      });
      expect(calls, 0);
    },
  );

  for (final transition in ['school', 'revoke', 'replace', 'logout']) {
    test(
      'late $transition discards checks and does not invoke the next account',
      () async {
        final session = SessionController();
        addTearDown(session.dispose);
        final p = selectionPackage(
          accounts: const ['first', 'second'],
          body: '''
          await ctx.credentials.set(p.account,'SYNTHETIC');
          await new Promise(resolve => setTimeout(resolve,250));
          return {status:'authenticated'};
        ''',
        );
        final other = selectionPackage(id: 'other.selection', school: 'other');
        await session.installTrustedScript(other, approvedDigest: other.digest);
        await selectPackage(session, p);
        final pending = session.checkTrustedScriptAccounts(p);
        for (var i = 0; i < 100 && session.credentialCount == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(
          session.credentialCount,
          1,
          reason: 'first status must be executing before transition',
        );
        switch (transition) {
          case 'school':
            await session.selectTrustedScriptSchool(other.manifest.id);
          case 'revoke':
            await session.enableTrustedScript(p.manifest.id, false);
          case 'replace':
            final replacement = selectionPackage(
              version: '1.1.0',
              body: "return {status:'unknown'};",
            );
            await session.installTrustedScript(
              replacement,
              approvedDigest: replacement.digest,
            );
          case 'logout':
            session.logout();
        }
        expect(await pending, isNull);
        if (transition != 'school') {
          expect(session.credentialCount, transition == 'logout' ? 0 : 1);
        }
        if (transition != 'logout') {
          expect(await session.checkTrustedScriptAccounts(p), isNull);
        }
      },
    );
  }
}
