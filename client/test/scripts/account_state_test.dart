import 'dart:convert';
import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/input.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage fixture(
  String body, {
  bool tunnel = true,
  int sdk = 12,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'id': 'synthetic.accounts',
      'schoolId': 'synthetic',
      'name': 'Synthetic',
      'version': '1.0.0',
      'sdkVersion': sdk,
      'network': {'origins': []},
      'browser': true,
      'accounts': [],
      if (tunnel) 'appTunnels': ['hermes-atrust'],
      'capabilities': [
        {
          'id': 'account.session',
          'schema': 'elecon.account.session',
          'schemaVersion': '1.0',
        },
      ],
    },
    'source':
        "export const capabilities={'account.session':async(ctx,p)=>{$body}};",
  }),
);
Future<Object?> run(
  ScriptPackage package, {
  String operation = 'status',
  Future<Object?> Function(String, String)? tunnel,
  Future<Object?> Function(String, Map<String, Object?>)? browser,
  ScriptInputCall? input,
}) => const TrustedScriptRuntime().run(
  package: package,
  capability: 'account.session',
  params: {'account': 'synthetic', 'operation': operation},
  credentials: ScriptCredentials(
    store: CredentialStore(store: InMemorySecureStore(releaseMode: false)),
    schoolId: 'synthetic',
    scriptId: package.manifest.id,
    sdkVersion: package.manifest.sdkVersion,
  ),
  fetch: (_, _) async => throw StateError('no HTTP in fixture'),
  appTunnelCall: tunnel,
  browserCall: browser,
  inputCall: input,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'SDK 12 tunnel declaration is explicit and earlier SDKs reject it',
    () async {
      final hidden = fixture(
        "return {status:typeof ctx.appTunnel==='undefined'?'signedOut':'unknown'}",
        tunnel: false,
      );
      expect(await run(hidden), {'status': 'signedOut'});
      expect(
        () => fixture("return {status:'unknown'}", sdk: 11),
        throwsFormatException,
      );
      var calls = 0;
      final data = await run(
        fixture("return ctx.appTunnel.status('hermes-atrust');"),
        tunnel: (m, p) async {
          expect(m, 'status');
          expect(p, 'hermes-atrust');
          calls++;
          return {'status': 'authenticated', 'accountLabel': 'Synthetic'};
        },
      );
      expect((data as Map)['status'], 'authenticated');
      expect(calls, 1);
    },
  );
  test(
    'account status cannot invoke UI or tunnel login even via raw host calls',
    () async {
      var calls = 0;
      for (final body in [
        "await ctx.appTunnel.login('hermes-atrust');",
        "await ctx.browser.open('https://synthetic.invalid');",
        "await ctx.ui.requestInput({title:'Synthetic',fields:[]});",
      ]) {
        await expectLater(
          run(
            fixture("$body return {status:'authenticated'}"),
            tunnel: (_, _) async {
              calls++;
              return {'status': 'authenticated'};
            },
            input: (_) async {
              calls++;
              return null;
            },
            browser: (_, _) async {
              calls++;
              return null;
            },
          ),
          throwsA(
            isA<ScriptRunException>().having(
              (e) => e.code,
              'code',
              'input_unavailable',
            ),
          ),
        );
      }
      for (final expression in [
        "globalThis.__script_app_tunnel('login','hermes-atrust','{}')",
        "globalThis.__script_input('{}')",
      ]) {
        final result = await run(
          fixture(
            "const result=JSON.parse(await $expression); return {status:'unknown',accountLabel:JSON.stringify(result)};",
          ),
          tunnel: (_, _) async {
            calls++;
            return {'status': 'authenticated'};
          },
          input: (_) async {
            calls++;
            return null;
          },
        );
        expect(jsonDecode((result as Map)['accountLabel'] as String), {
          'ok': false,
          'error': {'code': 'input_unavailable', 'category': 'internal'},
        });
      }
      expect(calls, 0);
    },
  );
  test('declared login may invoke only its fixed provider', () async {
    var calls = 0;
    final data = await run(
      fixture("return ctx.appTunnel.login('hermes-atrust');"),
      operation: 'login',
      tunnel: (_, _) async {
        calls++;
        return {'status': 'authenticated'};
      },
    );
    expect((data as Map)['status'], 'authenticated');
    expect(calls, 1);
    await expectLater(
      run(
        fixture("return ctx.appTunnel.status('unreviewed');"),
        tunnel: (_, _) async {
          fail('undeclared provider reached host');
        },
      ),
      throwsA(isA<ScriptRunException>()),
    );
  });
  test(
    'background account status is rejected before host service access',
    () async {
      final package = fixture("return ctx.appTunnel.status('hermes-atrust');");
      final session = SessionController();
      addTearDown(session.dispose);
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
      await session.selectTrustedScriptSchool(package.manifest.id);
      final result = await session.runTrustedScript(
        package.manifest.id,
        'account.session',
        params: {'account': 'synthetic', 'operation': 'status'},
        interactive: false,
      );
      expect(result.reason, 'foreground_required');
    },
  );
}
