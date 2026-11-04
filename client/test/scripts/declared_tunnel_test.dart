import 'dart:convert';
import 'dart:io';
import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/scripts/account_auth.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/transport/app_tunnel.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/scripts/script_password_dialog.dart';
import 'package:elecon/ui/login/script_login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'credential_reuse_test.dart' show reuseManifest, ReuseNative;
import 'account_password_test.dart' show passwordPackage;
import 'login_entry_test.dart' show until;

Map<String, dynamic> declaredManifest({String? origin, bool web = false}) {
  final m = reuseManifest();
  m['sdkVersion'] = 16;
  final accounts = m['accounts'] as List;
  accounts.last.remove('credentialReuse');
  accounts.last['appTunnel'] = <String, dynamic>{
    'service': 'hermes-atrust',
    'gatewayUrl': 'https://gateway.example.invalid',
    'loginDomain': '',
    'loginMode': web ? 'web' : 'password',
    'nodeCertificateSha256': 'ab' * 32,
  };
  accounts.first['appTunnelAccountId'] = 'vpn';
  (m['network']['origins'] as List).add(
    origin ?? 'https://service.example.invalid',
  );
  (m['capabilities'] as List).firstWhere(
    (c) => c['id'] == 'notice.list',
  )['appTunnelAccountId'] = 'vpn';
  (m['capabilities'] as List).add({
    'id': 'generic.section',
    'schema': 'elecon.generic.section',
    'schemaVersion': '1.0',
  });
  return m;
}

ScriptPackage declaredPackage({
  String? origin,
  bool web = false,
  String? source,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': declaredManifest(origin: origin, web: web),
    'source':
        source ??
        '''export const capabilities={
  'account.session':async(c,p)=>p.operation==='status'?c.appTunnel.status('hermes-atrust'):c.appTunnel.login('hermes-atrust',{accountId:p.account}),
  'notice.list':async c=>{await c.fetch('${origin ?? 'https://service.example.invalid'}');return {items:[]};},
  'generic.section':async c=>{await c.fetch('${origin ?? 'https://service.example.invalid'}');return {sectionId:'test',title:'Synthetic',fields:[]};}
  };''',
  }),
);

class RefusingTunnel implements AppTunnelProvider {
  int opens = 0;
  @override
  String get id => 'hermes-atrust';
  @override
  String get name => 'Synthetic';
  @override
  bool get isAvailable => true;
  @override
  Future<AppTunnelConnection> open({required String schoolId}) async {
    opens++;
    throw const AppTunnelException('synthetic_no_connection');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
    'SDK16 declarations reject incompatible old versions, bad dependencies, realms and pins',
    () {
      for (final change in <void Function(Map<String, dynamic>)>[
        (m) => m['sdkVersion'] = 15,
        (m) =>
            (m['accounts'] as List).last['appTunnel']['nodeCertificateSha256'] =
                'invalid',
        (m) =>
            (m['accounts'] as List).last['appTunnel']['nodeCertificateSha256'] =
                null,
        (m) =>
            (m['accounts'] as List).last['appTunnel']['loginMode'] = 'unknown',
        (m) {
          final a = (m['accounts'] as List).last['appTunnel'];
          a['loginMode'] = 'web';
          a['loginDomain'] = 'unverified-cas';
        },
        (m) => (m['accounts'] as List).first['appTunnelAccountId'] = 'missing',
        (m) => (m['capabilities'] as List).first['appTunnelAccountId'] = 'vpn',
      ]) {
        final m = declaredManifest();
        change(m);
        expect(
          () => ScriptPackage.parse(
            jsonEncode({
              'format': 'elecon-script/1',
              'manifest': m,
              'source': 'export const capabilities={};',
            }),
          ),
          throwsFormatException,
        );
      }
      expect(
        declaredPackage().manifest.accounts.last.appTunnel?.loginMode,
        'password',
      );
    },
  );
  Future<(SessionController, ScriptPackage, ReuseNative)> setup({
    String? origin,
    bool web = false,
    AppTunnelProvider? provider,
    String? source,
  }) async {
    final native = ReuseNative();
    final blobs = InMemoryBlobStore();
    final s = SessionController(
      hermesBinding: native,
      blobStoreProvider: () async => blobs,
      appTunnelProviders: provider == null ? null : [provider],
    );
    addTearDown(s.dispose);
    final p = declaredPackage(origin: origin, web: web, source: source);
    await s.installTrustedScript(p, approvedDigest: p.digest);
    await s.selectTrustedScriptSchool(p.manifest.id);
    s.scriptStorageConsent = () async => true;
    return (s, p, native);
  }

  test(
    'declared password form authenticates once, verifies, then stores account and pinned session',
    () async {
      final (s, p, native) = await setup();
      var prompts = 0;
      final result = await s.runTrustedScript(
        p.manifest.id,
        'account.session',
        params: {'account': 'vpn', 'operation': 'login'},
        passwordCall: (prompt) async {
          prompts++;
          expect(prompt.tunnel?.gatewayUrl, 'https://gateway.example.invalid');
          expect(prompt.hasSavedPassword, false);
          return const ScriptPasswordInput(
            username: 'SYNTHETIC',
            password: 'EXAMPLE_PASSWORD',
            remember: true,
          );
        },
      );
      expect(result.ok, true, reason: result.reason);
      expect(prompts, 1);
      expect(native.calls.map((v) => v['op']), [
        'authenticatePassword',
        'checkSession',
      ]);
      expect(s.hermesAccountInfo()?.username, 'SYNTHETIC');
      expect(
        s.hasDeclaredTunnelConfiguration(p.manifest.accounts.last.appTunnel!),
        true,
      );
      expect(
        s.hasDeclaredTunnelConfiguration(
          const ScriptAppTunnel(
            service: 'hermes-atrust',
            gatewayUrl: 'https://gateway.example.invalid',
            loginDomain: '',
          ),
        ),
        false,
      );
    },
  );
  test(
    'SDK16 cannot escape through legacy optionless login or unscoped status',
    () async {
      for (final expression in [
        "c.appTunnel.login('hermes-atrust')",
        "c.appTunnel.status('hermes-atrust')",
      ]) {
        final (s, p, native) = await setup(
          source:
              "export const capabilities={'generic.section':async c=>$expression,'account.session':async c=>$expression};",
        );
        var opened = 0;
        final result = await s.runTrustedScript(
          p.manifest.id,
          expression.contains('login') ? 'account.session' : 'generic.section',
          params: expression.contains('login')
              ? {'account': 'vpn', 'operation': 'login'}
              : null,
          appTunnelLogin: () async {
            opened++;
          },
        );
        expect(result.ok, false);
        expect(result.reason, 'input_unavailable');
        expect(opened, 0);
        expect(native.calls, isEmpty);
      }
    },
  );
  test(
    'web mode never prompts or submits password, and does not claim callback completion is authenticated',
    () async {
      final (s, p, native) = await setup(web: true);
      var opened = 0;
      final result = await s.runTrustedScript(
        p.manifest.id,
        'account.session',
        params: {'account': 'vpn', 'operation': 'login'},
        passwordCall: (_) async => throw StateError('must not prompt'),
        appTunnelLogin: () async {
          opened++;
        },
      );
      expect(result.ok, true);
      expect((result.data as Map)['status'], 'unknown');
      expect(opened, 1);
      expect(native.calls, isEmpty);
      expect(s.hermesConfigurationInfo(), isNull);
    },
  );
  test(
    'required capability and account never connect directly, unrelated SDK16 capability ignores legacy global tunnel',
    () async {
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        requests++;
        request.response.write('{}');
        request.response.close();
      });
      final origin = 'http://127.0.0.1:${server.port}';
      final provider = RefusingTunnel();
      final (s, p, _) = await setup(origin: origin, provider: provider);
      final missing = await s.runTrustedScript(p.manifest.id, 'notice.list');
      expect(missing.reason, 'app_tunnel_required');
      final account = await s.runTrustedScript(
        p.manifest.id,
        'account.session',
        params: {'account': 'school', 'operation': 'status'},
      );
      expect(account.reason, 'app_tunnel_required');
      expect(requests, 0);
      expect(provider.opens, 0);
      await s.runTrustedScript(
        p.manifest.id,
        'account.session',
        params: {'account': 'vpn', 'operation': 'login'},
        passwordCall: (_) async => const ScriptPasswordInput(
          username: 'SYNTHETIC',
          password: 'EXAMPLE_PASSWORD',
          remember: false,
        ),
      );
      final blocked = await s.runTrustedScript(p.manifest.id, 'notice.list');
      expect(blocked.ok, false);
      expect(provider.opens, 1);
      expect(requests, 0);
      await s.selectAppTunnel('hermes-atrust');
      final direct = await s.runTrustedScript(p.manifest.id, 'generic.section');
      expect(direct.ok, true, reason: direct.reason);
      expect(requests, 1);
      expect(provider.opens, 1);
    },
  );
  testWidgets(
    'same password dialog shows script-owned connection as read-only details',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ScriptPasswordDialog(
              request: ScriptPasswordPrompt(
                accountName: 'Synthetic VPN',
                username: '',
                hasSavedPassword: false,
                blocked: false,
                allowWeb: false,
                instructions: 'Synthetic instructions',
                tunnel: declaredPackage().manifest.accounts.last.appTunnel,
              ),
            ),
          ),
        ),
      );
      expect(find.text('https://gateway.example.invalid'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('Synthetic instructions'), findsOneWidget);
    },
  );
  testWidgets(
    'SDK16 default school login selects declared password entry without explicit account id',
    (tester) async {
      final raw =
          jsonDecode(
                passwordPackage(
                  source:
                      "export const capabilities={'account.session':async c=>{await c.accounts.password('school',{mode:'manual'});return {status:'signedOut'};}};",
                ).encode(),
              )
              as Map<String, dynamic>;
      raw['manifest']['sdkVersion'] = 16;
      final p = ScriptPackage.parse(jsonEncode(raw));
      final session = SessionController();
      addTearDown(session.dispose);
      await session.installTrustedScript(p, approvedDigest: p.digest);
      await session.selectTrustedScriptSchool(p.manifest.id);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ScriptLoginPage(
                      session: session,
                      school: session.selectedSchool!,
                    ),
                  ),
                ),
                child: const Text('Open school'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open school'));
      await until(
        tester,
        () => find.byType(ScriptPasswordDialog).evaluate().isNotEmpty,
      );
      expect(find.text('Synthetic account'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(ScriptPasswordDialog),
          matching: find.text('Cancel'),
        ),
      );
      await until(
        tester,
        () =>
            find.byType(ScriptPasswordDialog).evaluate().isEmpty &&
            find.byType(ScriptLoginPage).evaluate().isEmpty,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
