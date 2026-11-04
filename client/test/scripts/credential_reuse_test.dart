import 'dart:async';
import 'dart:convert';
import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/account_auth.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:elecon/core/transport/hermes/hermes.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'account_password_test.dart' show passwordPackage;
import '../transport/hermes_configuration_test.dart' show syntheticSession;

Map<String, dynamic> reuseManifest() {
  final raw = jsonDecode(passwordPackage().encode()) as Map<String, dynamic>;
  final manifest = raw['manifest'] as Map<String, dynamic>;
  manifest['sdkVersion'] = 15;
  manifest['appTunnels'] = ['hermes-atrust'];
  manifest['network'] = {
    'origins': ['https://gateway.example.invalid'],
  };
  (manifest['accounts'] as List).add({
    'id': 'vpn',
    'name': 'Synthetic VPN',
    'instructions': 'Reuse synthetic school credentials',
    'capabilities': ['account.session'],
    'login': {
      'capability': 'account.session',
      'params': {'account': 'vpn', 'operation': 'login'},
    },
    'status': {
      'capability': 'account.session',
      'params': {'account': 'vpn', 'operation': 'status'},
    },
    'credentialReuse': {
      'sourceAccountId': 'school',
      'service': 'hermes-atrust',
      'gatewayUrl': 'https://gateway.example.invalid',
      'loginDomain': '',
    },
  });
  return manifest;
}

ScriptPackage reusePackage({String? source}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': reuseManifest(),
    'source':
        source ??
        '''export const capabilities={'account.session':async(ctx,p)=>{
    if(p.account==='school') {
      const v=await ctx.accounts.password('school',{mode:'manual'});
      await ctx.accounts.completePassword('school',{attemptId:v.attemptId,outcome:'authenticated'});
      return {status:'authenticated'};
    }
    return p.operation==='status' ? ctx.appTunnel.status('hermes-atrust') : ctx.appTunnel.login('hermes-atrust',{accountId:'vpn'});
  }};''',
  }),
);

class ReuseNative extends HermesNativeBinding {
  final calls = <Map<String, Object?>>[];
  Map<String, dynamic> state = {
    'status': 'authenticated',
    'accountLabel': 'SYNTHETIC_USER',
  };
  Completer<Map<String, dynamic>>? gate;
  Map<String, dynamic> session = syntheticSession();
  @override
  bool get isAvailable => true;
  @override
  HermesNativeRequest request(Map<String, Object?> input) {
    calls.add(Map.of(input));
    return HermesNativeRequest(
      gate?.future ??
          Future.value(
            input['op'] == 'authenticatePassword'
                ? {'session': session}
                : state,
          ),
      () async => {},
    );
  }
}

class ReuseBlobs extends InMemoryBlobStore {
  bool fail = false;
  @override
  Future<void> write(String name, List<int> bytes) async {
    if (fail && name == 'store.enc') {
      throw StateError('synthetic persistence failure');
    }
    await super.write(name, bytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'SDK15 rejects old versions, dangling/self sources and unapproved destinations',
    () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (m) => m['sdkVersion'] = 14,
        (m) =>
            (m['accounts'] as List).last['credentialReuse']['sourceAccountId'] =
                'missing',
        (m) =>
            (m['accounts'] as List).last['credentialReuse']['sourceAccountId'] =
                'vpn',
        (m) => (m['accounts'] as List).last['credentialReuse']['gatewayUrl'] =
            'https://other.example.invalid',
        (m) => (m['accounts'] as List).last['credentialReuse']['gatewayUrl'] =
            'https://gateway.example.invalid/path',
        (m) => (m['accounts'] as List).last.remove('status'),
        (m) => (m['network'] as Map)['ipAllow'] = <String>[],
      ]) {
        final m = reuseManifest();
        mutate(m);
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
      expect(reusePackage().manifest.sdkVersion, 15);
    },
  );
  test(
    'actual QuickJS reuse requires exact target login and allows one attempt',
    () async {
      var calls = 0;
      Future<Object?> run(ScriptPackage p, Map<String, dynamic> params) =>
          const TrustedScriptRuntime().run(
            package: p,
            capability: 'account.session',
            params: params,
            credentials: ScriptCredentials(
              store: CredentialStore(),
              schoolId: p.manifest.schoolId,
              scriptId: p.manifest.id,
              sdkVersion: 15,
              isActive: () => true,
            ),
            fetch: (_, _) async => throw StateError('no network'),
            appTunnelReuseCall: (_) async {
              calls++;
              return {'status': 'authenticated'};
            },
          );
      final p = reusePackage(
        source:
            "export const capabilities={'account.session':async c=>c.appTunnel.login('hermes-atrust',{accountId:'vpn'})};",
      );
      expect(await run(p, {'account': 'vpn', 'operation': 'login'}), {
        'status': 'authenticated',
      });
      expect(calls, 1);
      await expectLater(
        run(p, {'account': 'vpn', 'operation': 'status'}),
        throwsA(isA<ScriptRunException>()),
      );
      await expectLater(
        run(p, {'account': 'school', 'operation': 'login'}),
        throwsA(isA<ScriptRunException>()),
      );
      expect(calls, 1);
      final twice = reusePackage(
        source:
            "export const capabilities={'account.session':async c=>{await c.appTunnel.login('hermes-atrust',{accountId:'vpn'});return c.appTunnel.login('hermes-atrust',{accountId:'vpn'});}};",
      );
      await expectLater(
        run(twice, {'account': 'vpn', 'operation': 'login'}),
        throwsA(isA<ScriptRunException>()),
      );
      expect(calls, 2);
    },
  );
  Future<(SessionController, ScriptPackage, ReuseNative)> setup({
    InMemoryBlobStore? storage,
  }) async {
    final native = ReuseNative();
    final blobs = storage ?? InMemoryBlobStore();
    final s = SessionController(
      hermesBinding: native,
      blobStoreProvider: () async => blobs,
    );
    addTearDown(s.dispose);
    final p = reusePackage();
    await s.installTrustedScript(p, approvedDigest: p.digest);
    await s.selectTrustedScriptSchool(p.manifest.id);
    s.scriptStorageConsent = () async => true;
    final saved = await s.runTrustedScript(
      p.manifest.id,
      'account.session',
      expectedDigest: p.digest,
      params: {'account': 'school', 'operation': 'login'},
      passwordCall: (_) async => const ScriptPasswordInput(
        username: 'SYNTHETIC_USER',
        password: 'SYNTHETIC_PASSWORD',
        remember: true,
      ),
    );
    expect(saved.ok, true, reason: saved.reason);
    return (s, p, native);
  }

  Future<Map<String, Object?>> login(
    SessionController s,
    ScriptPackage p, {
    ScriptRunCancellation? cancellation,
  }) => s.loginHermesWithScriptAccount(
    package: p,
    accountId: 'vpn',
    capability: 'account.session',
    params: {'account': 'vpn', 'operation': 'login'},
    isActive: () => true,
    cancellation: cancellation,
  );
  test(
    'authenticate then check commits only target session, preserving source and password store',
    () async {
      final (s, p, native) = await setup();
      final before = s.savedScriptAccount(p, p.manifest.accounts.first.id);
      final run = await s.runTrustedScript(
        p.manifest.id,
        'account.session',
        expectedDigest: p.digest,
        params: {'account': 'vpn', 'operation': 'login'},
      );
      expect(run.ok, true, reason: run.reason);
      final result = run.data as Map;
      expect(result['status'], 'authenticated');
      expect(native.calls.map((c) => c['op']), [
        'authenticatePassword',
        'checkSession',
      ]);
      expect(native.calls.first['password'], 'SYNTHETIC_PASSWORD');
      expect(native.calls.last.containsKey('password'), false);
      expect(s.hermesConfigurationInfo(), isNotNull);
      expect(s.hermesAccountInfo(), isNull);
      final count = native.calls.length;
      expect(
        await s.checkHermesAccount(
          expectedGatewayUrl: 'https://other.example.invalid',
        ),
        {'status': 'signedOut'},
      );
      expect(
        await s.checkHermesAccount(
          expectedGatewayUrl: 'https://gateway.example.invalid',
          expectedLoginDomain: 'another-domain',
        ),
        {'status': 'signedOut'},
      );
      expect(native.calls.length, count);
      expect(
        s.savedScriptAccount(p, p.manifest.accounts.first.id)?.blocked,
        before?.blocked,
      );
      expect(jsonEncode(result), isNot(contains('PASSWORD')));
    },
  );
  test(
    'unknown check keeps previous target and cancellation cannot publish',
    () async {
      final (s, p, native) = await setup();
      expect((await login(s, p))['status'], 'authenticated');
      native.state = {'status': 'unknown'};
      native.session = {...syntheticSession(), 'sid': 'SYNTHETIC_NEW_SID'};
      expect((await login(s, p))['status'], 'unknown');
      expect(s.hermesConfigurationInfo(), isNotNull);
      await s.checkHermesAccount();
      expect(
        (native.calls.last['session'] as Map)['sid'],
        'SYNTHETIC_PRIVATE_SID',
      );
      await s.clearHermesConfiguration();
      native.gate = Completer<Map<String, dynamic>>();
      final cancellation = ScriptRunCancellation();
      final pending = login(s, p, cancellation: cancellation);
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel();
      native.gate!.complete({'session': syntheticSession()});
      await expectLater(pending, throwsA(isA<ScriptRunException>()));
      expect(s.hermesConfigurationInfo(), isNull);
      cancellation.dispose();
    },
  );
  test(
    'background, missing source and source deletion never submit or publish',
    () async {
      final (s, p, native) = await setup();
      s.scriptAppForeground = false;
      await expectLater(login(s, p), throwsA(isA<ScriptRunException>()));
      expect(native.calls, isEmpty);
      s.scriptAppForeground = true;
      native.gate = Completer<Map<String, dynamic>>();
      final pending = login(s, p);
      await Future<void>.delayed(Duration.zero);
      await s.deleteSavedScriptAccount(p, 'school');
      native.gate!.complete({'session': syntheticSession()});
      await expectLater(pending, throwsA(isA<ScriptRunException>()));
      expect(s.hermesConfigurationInfo(), isNull);
      await expectLater(
        login(s, p),
        throwsA(
          isA<ScriptRunException>().having(
            (e) => e.code,
            'code',
            'authentication_required',
          ),
        ),
      );
      expect(native.calls.length, 1);
    },
  );
  test(
    'failed durable target save reports unknown and retains source',
    () async {
      final blobs = ReuseBlobs();
      final (s, p, native) = await setup(storage: blobs);
      blobs.fail = true;
      expect((await login(s, p))['status'], 'unknown');
      expect(s.hermesConfigurationInfo(), isNull);
      expect(s.savedScriptAccount(p, 'school')?.username, 'SYNTHETIC_USER');
      expect(s.savedScriptAccount(p, 'school')?.blocked, false);
      expect(native.calls.length, 2);
      blobs.fail = false;
    },
  );
}
