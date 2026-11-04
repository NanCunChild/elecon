import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/adapter_service.dart';
import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/software_secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/account_auth.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/data_cache.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_password_test.dart' show passwordPackage;

const _loginParams = {'account': 'school', 'operation': 'login'};
const _source = '''export const capabilities={
  'account.session':async(ctx,params)=>{
    if(params.operation==='status')return {status:'authenticated'};
    ctx.log('info','synthetic_login_started');
    const pair=await ctx.accounts.password('school',{mode:'manual'});
    if(pair===null)throw new Error('synthetic_cancelled');
    if(pair.username==='SYNTHETIC_REJECTED'){
      await ctx.accounts.completePassword('school',{attemptId:pair.attemptId,outcome:'credentialsRejected'});
      throw new Error('synthetic_rejected');
    }
    await ctx.credentials.set('principal',pair.username,{namespace:'synthetic.identity'});
    await ctx.accounts.completePassword('school',{attemptId:pair.attemptId,outcome:'authenticated'});
    return {status:'authenticated'};
  },
  'notice.list':async(ctx,params)=>{
    ctx.log('info','synthetic_query_started');
    if(params.seedCredential)await ctx.credentials.set('service-token','SYNTHETIC_PRESERVED_TOKEN',{namespace:'synthetic.service'});
    const principal=await ctx.credentials.get('principal',{namespace:'synthetic.identity'});
    return {items:[],principal:principal?.value??'SYNTHETIC_OTHER_SCHOOL'};
  }
};''';

ScriptPackage _package({
  String id = 'synthetic.password',
  String school = 'synthetic',
}) {
  final raw =
      jsonDecode(passwordPackage(source: _source).encode())
          as Map<String, dynamic>;
  final manifest = raw['manifest'] as Map<String, dynamic>;
  manifest['id'] = id;
  manifest['schoolId'] = school;
  manifest['home'] = [
    {'capability': 'notice.list', 'ttlSeconds': 300, 'preload': false},
  ];
  return ScriptPackage.parse(jsonEncode(raw));
}

class _ControlledBlobs extends InMemoryBlobStore {
  Completer<void>? entered;
  Completer<void>? writeGate;
  bool failWrites = false;

  @override
  Future<void> write(String name, List<int> bytes) async {
    if (name == 'store.enc') {
      final gate = writeGate;
      if (gate != null) {
        writeGate = null;
        entered?.complete();
        await gate.future;
      }
      if (failWrites) throw StateError('synthetic persistence failure');
    }
    await super.write(name, bytes);
  }
}

Future<SessionController> _session(
  InMemoryBlobStore blobs,
  ScriptPackage package,
) async {
  final session = SessionController(blobStoreProvider: () async => blobs);
  addTearDown(session.dispose);
  await session.bootstrap();
  await session.installTrustedScript(package, approvedDigest: package.digest);
  await session.selectTrustedScriptSchool(package.manifest.id);
  session.scriptStorageConsent = () async => true;
  return session;
}

Future<CapabilityRun> _login(
  SessionController session,
  ScriptPackage package,
  String user,
) => session.runTrustedScript(
  package.manifest.id,
  'account.session',
  expectedDigest: package.digest,
  params: _loginParams,
  passwordCall: (_) async => ScriptPasswordInput(
    username: user,
    password: 'SYNTHETIC_PASSWORD',
    remember: true,
  ),
);

Future<void> _query(
  SessionController session,
  ScriptPackage package, {
  Map<String, dynamic> params = const {},
}) async {
  final result = await session.runTrustedScript(
    package.manifest.id,
    'notice.list',
    expectedDigest: package.digest,
    params: params,
  );
  expect(result.ok, isTrue, reason: result.reason);
}

Future<ScriptCachedData?> _cached(
  SessionController session,
  ScriptPackage package, {
  Map<String, dynamic> params = const {},
}) => session.cachedCapability(
  'notice.list',
  packageId: package.manifest.id,
  expectedDigest: package.digest,
  params: params,
);

Future<void> _seedA(SessionController session, ScriptPackage package) async {
  final result = await _login(session, package, 'SYNTHETIC_A');
  expect(result.ok, isTrue, reason: result.reason);
  await _query(session, package);
  expect(
    ((await _cached(session, package))!.data as Map)['principal'],
    'SYNTHETIC_A',
  );
  await session.flush();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'same-school login clears every package, locale and parameter cache durably while preserving other schools and credentials',
    () async {
      final blobs = InMemoryBlobStore();
      final package = _package();
      final sibling = _package(id: 'synthetic.sibling');
      final other = _package(id: 'other.password', school: 'other');
      final session = await _session(blobs, package);
      for (final p in [sibling, other]) {
        await session.installTrustedScript(p, approvedDigest: p.digest);
      }
      await session.selectTrustedScriptSchool(other.manifest.id);
      await _query(session, other);
      await session.selectTrustedScriptSchool(package.manifest.id);
      await _seedA(session, package);
      await _query(session, package, params: {'seedCredential': true});
      for (final locale in ['zh', 'en']) {
        session.scriptLocale = locale;
        for (final p in [package, sibling]) {
          for (final page in [1, 2]) {
            await _query(session, p, params: {'page': page});
            expect(
              ((await _cached(session, p, params: {'page': page}))!.data
                  as Map)['principal'],
              'SYNTHETIC_A',
            );
          }
        }
      }
      final viewGeneration = session.trustedScriptViewGeneration;
      final dataGeneration = session.trustedScriptDataGeneration;
      final result = await _login(session, package, 'SYNTHETIC_B');
      expect(result.ok, isTrue, reason: result.reason);
      expect(session.trustedScriptViewGeneration, viewGeneration);
      expect(session.trustedScriptDataGeneration, greaterThan(dataGeneration));
      for (final locale in ['zh', 'en']) {
        session.scriptLocale = locale;
        for (final p in [package, sibling]) {
          for (final page in [1, 2]) {
            expect(await _cached(session, p, params: {'page': page}), isNull);
          }
        }
      }
      await session.flush();
      final persisted = await SoftwareSecureStore.open(blobs);
      expect(
        persisted.list().where(
          (e) => e.schoolId == 'synthetic' && e.type == ScriptDataCache.type,
        ),
        isEmpty,
      );
      expect(
        persisted.list().where(
          (e) => e.schoolId == 'other' && e.type == ScriptDataCache.type,
        ),
        hasLength(1),
      );
      final credentials = ScriptCredentials(
        store: CredentialStore(store: persisted),
        schoolId: 'synthetic',
        scriptId: package.manifest.id,
        sdkVersion: 14,
      );
      expect(
        credentials.get(
          'service-token',
          namespace: 'synthetic.service',
        )?['value'],
        'SYNTHETIC_PRESERVED_TOKEN',
      );
      expect(
        credentials.get('principal', namespace: 'synthetic.identity')?['value'],
        'SYNTHETIC_B',
      );
      final restored = SessionController(blobStoreProvider: () async => blobs);
      addTearDown(restored.dispose);
      await restored.bootstrap();
      expect(await _cached(restored, package), isNull);
      expect(await _cached(restored, sibling, params: {'page': 1}), isNull);
      await restored.selectTrustedScriptSchool(other.manifest.id);
      restored.scriptLocale = 'zh';
      expect(await _cached(restored, other), isNotNull);
    },
  );

  test(
    'cache deletion is flushed before login executes and a query queued before the login boundary cannot execute afterward',
    () async {
      final blobs = _ControlledBlobs();
      final package = _package();
      final session = await _session(blobs, package);
      await _seedA(session, package);
      final gate = Completer<void>();
      blobs.writeGate = gate;
      blobs.entered = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      var prompts = 0;
      final logs = <String>[];
      final login = session.runTrustedScript(
        package.manifest.id,
        'account.session',
        expectedDigest: package.digest,
        params: _loginParams,
        passwordCall: (_) async {
          prompts++;
          return const ScriptPasswordInput(
            username: 'SYNTHETIC_B',
            password: 'SYNTHETIC_PASSWORD',
            remember: true,
          );
        },
        onLog: (_, message) => logs.add(message),
      );
      final queued = session.runTrustedScript(
        package.manifest.id,
        'notice.list',
        expectedDigest: package.digest,
        onLog: (_, message) => logs.add(message),
      );
      await blobs.entered!.future;
      expect(prompts, 0);
      expect(logs, isEmpty);
      expect(await _cached(session, package), isNull);
      gate.complete();
      final result = await login;
      expect(result.ok, isTrue, reason: result.reason);
      expect(prompts, 1);
      expect((await queued).ok, isFalse);
      expect(logs, ['synthetic_login_started']);
      expect(await _cached(session, package), isNull);
    },
  );

  test(
    'failed cache flush blocks login and preserves cache invalidation until a durable retry succeeds',
    () async {
      final blobs = _ControlledBlobs();
      final package = _package();
      final session = await _session(blobs, package);
      await _seedA(session, package);
      blobs.failWrites = true;
      var prompts = 0;
      final logs = <String>[];
      final result = await session.runTrustedScript(
        package.manifest.id,
        'account.session',
        expectedDigest: package.digest,
        params: _loginParams,
        passwordCall: (_) async {
          prompts++;
          return null;
        },
        onLog: (_, message) => logs.add(message),
      );
      expect(result.ok, isFalse);
      expect(prompts, 0);
      expect(logs, isEmpty);
      expect(await _cached(session, package), isNull);
      final persisted = await SoftwareSecureStore.open(blobs);
      final account = ScriptAccountStore(CredentialStore(store: persisted));
      expect(
        account.read('synthetic', 'synthetic.auth')?['username'],
        'SYNTHETIC_A',
      );
      blobs.failWrites = false;
      final retry = await _login(session, package, 'SYNTHETIC_B');
      expect(retry.ok, isTrue, reason: retry.reason);
      expect(await _cached(session, package), isNull);
      final recovered = await SoftwareSecureStore.open(blobs);
      expect(
        recovered.list().where((entry) => entry.type == ScriptDataCache.type),
        isEmpty,
      );
    },
  );

  for (final outcome in ['cancelled', 'rejected']) {
    test(
      '$outcome replacement login leaves caches erased and keeps verified credentials',
      () async {
        final blobs = InMemoryBlobStore();
        final package = _package();
        final session = await _session(blobs, package);
        await _seedA(session, package);
        final result = await session.runTrustedScript(
          package.manifest.id,
          'account.session',
          expectedDigest: package.digest,
          params: _loginParams,
          passwordCall: (_) async => outcome == 'cancelled'
              ? null
              : const ScriptPasswordInput(
                  username: 'SYNTHETIC_REJECTED',
                  password: 'SYNTHETIC_PASSWORD',
                  remember: true,
                ),
        );
        expect(result.ok, isFalse);
        expect(await _cached(session, package), isNull);
        await session.flush();
        final persisted = await SoftwareSecureStore.open(blobs);
        expect(
          persisted.list().where((e) => e.type == ScriptDataCache.type),
          isEmpty,
        );
        final account = ScriptAccountStore(CredentialStore(store: persisted));
        expect(
          account.read('synthetic', 'synthetic.auth')?['username'],
          'SYNTHETIC_A',
        );
      },
    );
  }
}
