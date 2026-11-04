import 'dart:async';
import 'dart:convert';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/credential/types.dart';
import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/software_secure_store.dart';
import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/scripts/account_auth.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage passwordPackage({String? source}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 14,
      'id': 'synthetic.password',
      'schoolId': 'synthetic',
      'version': '1.0.0',
      'name': 'Synthetic',
      'browser': true,
      'network': {
        'origins': ['https://school.example'],
      },
      'capabilities': [
        {
          'id': 'account.session',
          'schema': 'elecon.account.session',
          'schemaVersion': '1.0',
        },
        {
          'id': 'notice.list',
          'schema': 'elecon.notice.list',
          'schemaVersion': '1.1',
        },
      ],
      'accounts': [
        {
          'id': 'school',
          'name': 'Synthetic account',
          'instructions': 'Synthetic test',
          'capabilities': ['account.session', 'notice.list'],
          'login': {
            'capability': 'account.session',
            'params': {'account': 'school', 'operation': 'login'},
          },
          'status': {
            'capability': 'account.session',
            'params': {'account': 'school', 'operation': 'status'},
          },
          'authentication': {
            'namespace': 'synthetic.auth',
            'savedPassword': true,
            'interactiveWeb': true,
            'silentWeb': false,
          },
        },
      ],
    },
    'source': source ?? 'export const capabilities={};',
  }),
);
const loginParams = {'account': 'school', 'operation': 'login'};
Matcher errorCode(String code) =>
    throwsA(isA<ScriptAccountException>().having((e) => e.code, 'code', code));
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ScriptAccountStore store;
  late List<ScriptAccountEvent> events;
  late int writes;
  late bool active;
  setUp(() {
    store = ScriptAccountStore(CredentialStore());
    events = [];
    writes = 0;
    active = true;
  });
  ScriptAccountBridge bridge({
    ScriptPasswordInput? input = const ScriptPasswordInput(
      username: 'EXAMPLE_USER',
      password: 'EXAMPLE_PASSWORD',
      remember: true,
    ),
    Future<ScriptPasswordInput?> Function(ScriptPasswordPrompt)? prompt,
    Future<void> Function()? persist,
    bool interactive = true,
    String capability = 'account.session',
    Map<String, dynamic> params = loginParams,
  }) => ScriptAccountBridge(
    package: passwordPackage(),
    capability: capability,
    params: params,
    store: store,
    persist:
        persist ??
        () async {
          writes++;
        },
    isActive: () => active,
    interactive: interactive,
    passwordCall: prompt ?? (_) async => input,
    onEvent: events.add,
  );
  Future<Map<String, dynamic>> request(ScriptAccountBridge b) async =>
      Map<String, dynamic>.from(
        await b.call('password', 'school', {'mode': 'manual'}) as Map,
      );
  Future<void> complete(
    ScriptAccountBridge b,
    Map attempt,
    String outcome,
  ) async => b.call('completePassword', 'school', {
    'attemptId': attempt['attemptId'],
    'outcome': outcome,
  });
  Future<void> seed() async {
    final b = bridge();
    await complete(b, await request(b), 'authenticated');
  }

  test(
    'new credentials are staged; only verified completion persists and emits',
    () async {
      final b = bridge();
      final value = await request(b);
      expect(value['username'], 'EXAMPLE_USER');
      expect(store.metadata('synthetic', 'synthetic.auth'), isNull);
      expect(writes, 0);
      expect(events, isEmpty);
      await complete(b, value, 'authenticated');
      expect(
        store.read('synthetic', 'synthetic.auth')?['password'],
        'EXAMPLE_PASSWORD',
      );
      expect(writes, 1);
      expect(events.single.status, 'authenticated');
      expect(events.single.digest, passwordPackage().digest);
      await expectLater(
        complete(b, value, 'authenticated'),
        errorCode('account_attempt_invalid'),
      );
    },
  );
  test(
    'rejected replacement preserves verified password and fixed event',
    () async {
      await seed();
      final before = store.entry('synthetic', 'synthetic.auth');
      final b = bridge(
        input: const ScriptPasswordInput(
          username: 'NEW_EXAMPLE',
          password: 'REJECTED_EXAMPLE',
          remember: true,
        ),
      );
      await complete(b, await request(b), 'credentialsRejected');
      expect(store.entry('synthetic', 'synthetic.auth'), same(before));
      expect(events.last.reason, 'credentialsRejected');
      expect(events.last.actions, contains('updateCredentials'));
    },
  );
  test('temporary credential does not overwrite saved password', () async {
    await seed();
    final old = store.entry('synthetic', 'synthetic.auth');
    final b = bridge(
      input: const ScriptPasswordInput(
        username: 'TEMP_EXAMPLE',
        password: 'TEMP_PASSWORD',
        remember: false,
      ),
    );
    await complete(b, await request(b), 'authenticated');
    expect(store.entry('synthetic', 'synthetic.auth'), same(old));
  });
  test(
    'failed commit restores old record and never publishes authenticated',
    () async {
      await seed();
      events.clear();
      final old = store.entry('synthetic', 'synthetic.auth');
      final b = bridge(
        persist: () async => throw StateError('synthetic storage fault'),
      );
      await expectLater(
        complete(b, await request(b), 'authenticated'),
        errorCode('account_storage_failed'),
      );
      expect(store.entry('synthetic', 'synthetic.auth'), same(old));
      expect(events, isEmpty);
    },
  );
  test(
    'saved attempt consumes durable gate before secret returns; failure blocks restart',
    () async {
      await seed();
      final persisted = Completer<void>();
      final b = bridge(
        input: const ScriptPasswordInput.saved(),
        persist: () => persisted.future,
      );
      var delivered = false;
      final pending = request(b).then((value) {
        delivered = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(delivered, isFalse);
      expect(store.metadata('synthetic', 'synthetic.auth')!.blocked, isTrue);
      persisted.complete();
      final attempt = await pending;
      await complete(b, attempt, 'credentialsRejected');
      final restartedBackend = InMemorySecureStore(releaseMode: false);
      for (final entry in store.store.list()) {
        restartedBackend.put(entry);
      }
      final restarted = ScriptAccountStore(
        CredentialStore(store: restartedBackend),
      );
      await expectLater(
        restarted.claimAutomatic('synthetic', 'synthetic.auth', () async {}),
        errorCode('account_recovery_blocked'),
      );
      final manual = bridge(input: const ScriptPasswordInput.saved());
      await complete(manual, await request(manual), 'authenticated');
      expect(store.metadata('synthetic', 'synthetic.auth')!.blocked, isFalse);
    },
  );
  test('encrypted backend reopen retains consumed recovery budget', () async {
    final blobs = InMemoryBlobStore();
    final backend = await SoftwareSecureStore.open(blobs);
    store = ScriptAccountStore(CredentialStore(store: backend));
    final manual = bridge(persist: backend.flush);
    await complete(manual, await request(manual), 'authenticated');
    await store.claimAutomatic('synthetic', 'synthetic.auth', backend.flush);
    final recoveredBackend = await SoftwareSecureStore.open(blobs);
    final recovered = ScriptAccountStore(
      CredentialStore(store: recoveredBackend),
    );
    expect(recovered.metadata('synthetic', 'synthetic.auth')!.blocked, isTrue);
    await expectLater(
      recovered.claimAutomatic(
        'synthetic',
        'synthetic.auth',
        recoveredBackend.flush,
      ),
      errorCode('account_recovery_blocked'),
    );
    final sealed = await blobs.read('store.enc');
    expect(
      utf8.decode(sealed!, allowMalformed: true),
      isNot(contains('EXAMPLE_PASSWORD')),
    );
  });
  test(
    'concurrent automatic claims share one persistent revision budget',
    () async {
      await seed();
      final flush = Completer<void>();
      final first = store.claimAutomatic(
        'synthetic',
        'synthetic.auth',
        () => flush.future,
      );
      await expectLater(
        store.claimAutomatic('synthetic', 'synthetic.auth', () async {}),
        errorCode('account_recovery_blocked'),
      );
      flush.complete();
      await first;
      expect(store.metadata('synthetic', 'synthetic.auth')!.blocked, isTrue);
    },
  );
  test(
    'failed durable claim returns no password and retains conservative block',
    () async {
      await seed();
      final b = bridge(
        input: const ScriptPasswordInput.saved(),
        persist: () async => throw StateError('disk'),
      );
      await expectLater(request(b), errorCode('account_storage_failed'));
      expect(store.metadata('synthetic', 'synthetic.auth')!.blocked, isTrue);
    },
  );
  test(
    'manual login restricted to exact declared foreground operation',
    () async {
      for (final b in [
        bridge(interactive: false),
        bridge(capability: 'notice.list', params: {}),
        bridge(params: {'account': 'school', 'operation': 'status'}),
        bridge(params: {...loginParams, 'extra': true}),
      ]) {
        await expectLater(
          request(b),
          errorCode('account_manual_login_required'),
        );
      }
    },
  );
  test(
    'missing silent presenter remains unavailable without spending password budget',
    () async {
      await seed();
      await expectLater(
        bridge().call('password', 'school', {'mode': 'automatic'}),
        errorCode('account_silent_unavailable'),
      );
      expect(store.metadata('synthetic', 'synthetic.auth')!.blocked, isFalse);
    },
  );
  test(
    'cancellation during password prompt drops late secret and event',
    () async {
      final prompt = Completer<ScriptPasswordInput?>();
      final b = bridge(prompt: (_) => prompt.future);
      final pending = request(b);
      active = false;
      prompt.complete(
        const ScriptPasswordInput(
          username: 'EXAMPLE',
          password: 'EXAMPLE_SECRET',
          remember: true,
        ),
      );
      await expectLater(pending, errorCode('invocation_cancelled'));
      expect(writes, 0);
      expect(events, isEmpty);
    },
  );
  test(
    'wrong source attempt and mismatched structured event fail closed',
    () async {
      final b = bridge();
      final attempt = await request(b);
      await expectLater(
        complete(bridge(), attempt, 'authenticated'),
        errorCode('account_attempt_invalid'),
      );
      await expectLater(
        b.call('report', 'other', {
          'status': 'authenticated',
          'reason': 'verified',
        }),
        errorCode('account_not_declared'),
      );
      await expectLater(
        b.call('report', 'school', {
          'status': 'authenticated',
          'reason': 'credentialsRejected',
        }),
        errorCode('account_invalid_event'),
      );
      await expectLater(
        b.call('report', 'school', {
          'status': 'unknown',
          'reason': 'networkUnknown',
          'password': 'EXAMPLE',
        }),
        errorCode('account_invalid_request'),
      );
      expect(events, isEmpty);
    },
  );
  test(
    'explicit web fallback never exports or overwrites saved secret',
    () async {
      await seed();
      final b = bridge(input: const ScriptPasswordInput.web());
      await expectLater(request(b), errorCode('account_interactive_fallback'));
      expect(store.metadata('synthetic', 'synthetic.auth')!.blocked, isFalse);
    },
  );
  test('flush that writes then fails is durably rolled back', () async {
    await seed();
    final old = store.entry('synthetic', 'synthetic.auth');
    String? durable = old!.value;
    var flushes = 0;
    final b = bridge(
      input: const ScriptPasswordInput(
        username: 'NEW_EXAMPLE',
        password: 'NEW_SECRET',
        remember: true,
      ),
      persist: () async {
        durable = store.entry('synthetic', 'synthetic.auth')?.value;
        if (++flushes == 1) throw StateError('failure after write');
      },
    );
    final attempt = await request(b);
    await expectLater(
      complete(b, attempt, 'authenticated'),
      errorCode('account_storage_failed'),
    );
    expect(flushes, 2);
    expect(durable, old.value);
    expect(store.entry('synthetic', 'synthetic.auth'), same(old));
  });
  for (final deleted in [false, true]) {
    test(
      'cancellation during commit rolls back without reviving deleted record: $deleted',
      () async {
        await seed();
        events.clear();
        final old = store.entry('synthetic', 'synthetic.auth');
        final waiting = Completer<void>();
        final entered = Completer<void>();
        String? durable;
        var flushes = 0;
        final b = bridge(
          input: const ScriptPasswordInput(
            username: 'NEW_EXAMPLE',
            password: 'NEW_SECRET',
            remember: true,
          ),
          persist: () async {
            durable = store.entry('synthetic', 'synthetic.auth')?.value;
            if (++flushes == 1) {
              entered.complete();
              await waiting.future;
            }
          },
        );
        final attempt = await request(b);
        final result = complete(b, attempt, 'authenticated');
        final expectation = expectLater(
          result,
          errorCode('invocation_cancelled'),
        );
        await entered.future;
        active = false;
        if (deleted) {
          store.store.delete(store.ref('synthetic', 'synthetic.auth'));
        }
        waiting.complete();
        await expectation;
        expect(
          store.entry('synthetic', 'synthetic.auth'),
          deleted ? isNull : same(old),
        );
        expect(durable, deleted ? isNull : old!.value);
        expect(events, isEmpty);
      },
    );
  }
  test('revoked, expired and corrupt account records are never used', () async {
    await seed();
    final old = store.entry('synthetic', 'synthetic.auth')!;
    for (final status in [CredentialStatus.expired, CredentialStatus.revoked]) {
      store.store.put(
        CredentialEntry(
          ref: old.ref,
          schoolId: old.schoolId,
          type: old.type,
          scope: old.scope,
          value: old.value,
          acquiredAt: old.acquiredAt,
          expiresAt: null,
          status: status,
        ),
      );
      expect(
        () => store.read('synthetic', 'synthetic.auth'),
        throwsA(isA<ScriptAccountException>()),
      );
    }
    for (final patch in [
      {'revision': 'bad'},
      {'reason': 'server supplied arbitrary text'},
      {'extra': 'secret'},
    ]) {
      final data = Map<String, dynamic>.from(jsonDecode(old.value) as Map)
        ..addAll(patch);
      store.write('synthetic', 'synthetic.auth', data);
      expect(
        () => store.read('synthetic', 'synthetic.auth'),
        throwsA(isA<ScriptAccountException>()),
      );
    }
  });
  test('actual QuickJS bridge completes password and redacts logs', () async {
    final p = passwordPackage(
      source: '''export const capabilities={'account.session':async ctx=>{
      const pair=await ctx.accounts.password('school',{mode:'manual'});
      ctx.log('info',pair.password);
      await ctx.accounts.completePassword('school',{attemptId:pair.attemptId,outcome:'authenticated'});
      return {status:'authenticated'};
    }};''',
    );
    final b = ScriptAccountBridge(
      package: p,
      capability: 'account.session',
      params: loginParams,
      store: store,
      persist: () async {},
      isActive: () => active,
      interactive: true,
      passwordCall: (_) async => const ScriptPasswordInput(
        username: 'EXAMPLE_USER',
        password: 'EXAMPLE_PASSWORD',
        remember: true,
      ),
    );
    final logs = <String>[];
    final output = await const TrustedScriptRuntime().run(
      package: p,
      capability: 'account.session',
      params: loginParams,
      credentials: ScriptCredentials(
        store: store.store,
        schoolId: 'synthetic',
        scriptId: p.manifest.id,
        sdkVersion: 14,
      ),
      fetch: (_, _) async => throw StateError('no request'),
      accountCall: b.call,
      onLog: (_, message) => logs.add(message),
    );
    expect((output as Map)['status'], 'authenticated');
    expect(logs.join(), isNot(contains('EXAMPLE_PASSWORD')));
    expect(
      store.metadata('synthetic', 'synthetic.auth')!.username,
      'EXAMPLE_USER',
    );
  });
}
