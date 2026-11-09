import 'dart:async';
import 'dart:convert';
import 'package:elecon/core/adapter_service.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage source({
  String id = 'synthetic.concurrent',
  int sdk = 20,
  List<Map<String, String>>? keys = const [],
  String extra = '',
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': sdk,
      'id': id,
      'schoolId': 'synthetic',
      'version': '1.0.0',
      'name': 'Synthetic',
      'browser': false,
      'accounts': [],
      'network': {'origins': []},
      'home': [],
      'capabilities': [
        {
          'id': 'grades.list',
          'schema': 'elecon.grades.list',
          'schemaVersion': '1.1',
          if (keys != null) 'concurrency': {'credentials': keys},
        },
      ],
    },
    'source':
        """export const capabilities={'grades.list':async(ctx,p)=>{
    ctx.log('info',p.label||'entered'); $extra
    await new Promise(r=>setTimeout(r,p.delay||1));
    return {term:p.term||'synthetic',items:[],hasNext:false};
  }};""",
  }),
);
Future<SessionController> prepare(List<ScriptPackage> packages) async {
  final session = SessionController();
  addTearDown(session.dispose);
  for (final p in packages) {
    await session.installTrustedScript(p, approvedDigest: p.digest);
  }
  await session.selectTrustedScriptSchool(packages.first.manifest.id);
  return session;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'three real engines run independent calls; fourth waits and cancelled waiter completes promptly',
    () async {
      final p = source();
      final session = await prepare([p]);
      final entered = <String>[];
      final ready = Completer<void>();
      final tokens = List.generate(5, (_) => ScriptRunCancellation());
      for (final t in tokens) {
        addTearDown(t.dispose);
      }
      final calls = [
        for (var i = 0; i < 5; i++)
          session.runTrustedScript(
            p.manifest.id,
            'grades.list',
            params: {'label': '$i', 'delay': 3000},
            cancellation: tokens[i],
            onLog: (_, m) {
              entered.add(m);
              if (entered.length == 3 && !ready.isCompleted) ready.complete();
            },
          ),
      ];
      await ready.future.timeout(const Duration(seconds: 3));
      expect(entered, unorderedEquals(['0', '1', '2']));
      tokens[4].cancel();
      expect(
        (await calls[4].timeout(const Duration(milliseconds: 200))).reason,
        'script_cancelled',
      );
      tokens[0].cancel();
      for (var i = 0; i < 100 && !entered.contains('3'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(entered, unorderedEquals(['0', '1', '2', '3']));
      for (final t in tokens) {
        t.cancel();
      }
      await Future.wait(calls);
    },
  );
  test(
    'cross-package shared credential addresses serialize; independent addresses run',
    () async {
      final a = source(
        id: 'synthetic.a',
        keys: [
          {'namespace': 'shared.auth', 'key': 'cookie'},
        ],
      );
      final b = source(
        id: 'synthetic.b',
        keys: [
          {'namespace': 'shared.auth', 'key': 'cookie'},
        ],
      );
      final c = source(
        id: 'synthetic.c',
        keys: [
          {'namespace': 'other.auth', 'key': 'cookie'},
        ],
      );
      final session = await prepare([a, b, c]);
      final events = <String>[];
      final first = Completer<void>();
      Future<CapabilityRun> run(ScriptPackage p, String name, int delay) =>
          session.runTrustedScript(
            p.manifest.id,
            'grades.list',
            params: {'label': name, 'delay': delay},
            onLog: (_, m) {
              events.add(m);
              if (m == 'a') first.complete();
            },
          );
      final pa = run(a, 'a', 300);
      await first.future;
      final pb = run(b, 'b', 1), pc = run(c, 'c', 1);
      await pc;
      expect(events, ['a', 'c']);
      await Future.wait([pa, pb]);
      expect(events, ['a', 'c', 'b']);
    },
  );
  test(
    'old SDK invocation excludes new calls and missing credential declarations fail closed',
    () async {
      final old = source(id: 'synthetic.old', sdk: 19, keys: null);
      final modern = source(
        id: 'synthetic.modern',
        extra: "await ctx.credentials.get('cookie',{namespace:'shared.auth'});",
      );
      final session = await prepare([old, modern]);
      final entered = Completer<void>();
      final events = <String>[];
      final first = session.runTrustedScript(
        old.manifest.id,
        'grades.list',
        params: {'delay': 200},
        onLog: (_, m) {
          entered.complete();
        },
      );
      await entered.future;
      final next = session.runTrustedScript(
        modern.manifest.id,
        'grades.list',
        onLog: (_, m) => events.add(m),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(events, isEmpty);
      expect((await first).ok, isTrue);
      expect((await next).reason, 'credential_scope_mismatch');
    },
  );
  test(
    'equal queries share work; one consumer cancellation does not revoke another',
    () async {
      final p = source(
        extra:
            "await ctx.credentials.set('marker','once',{namespace:'shared.auth'});",
        keys: [
          {'namespace': 'shared.auth', 'key': 'marker'},
        ],
      );
      final session = await prepare([p]);
      final one = ScriptRunCancellation(), two = ScriptRunCancellation();
      addTearDown(one.dispose);
      addTearDown(two.dispose);
      final a = session.runTrustedScript(
        p.manifest.id,
        'grades.list',
        interactive: false,
        params: {'delay': 150},
        cancellation: one,
      );
      final b = session.runTrustedScript(
        p.manifest.id,
        'grades.list',
        interactive: false,
        params: {'delay': 150},
        cancellation: two,
      );
      one.cancel();
      expect((await a).reason, 'script_cancelled');
      expect((await b).ok, isTrue);
    },
  );
  test(
    'SDK20 cannot swallow a hard host transport budget; older SDK semantics stay intact',
    () async {
      for (final sdk in [19, 20]) {
        final raw =
            jsonDecode(
                  source(
                    sdk: sdk,
                    keys: sdk < 20 ? null : [],
                    extra:
                        "try {await ctx.fetch('https://synthetic.invalid/');} catch (_) {}",
                  ).encode(),
                )
                as Map<String, dynamic>;
        raw['manifest']['network'] = {
          'origins': ['https://synthetic.invalid'],
        };
        final p = ScriptPackage.parse(jsonEncode(raw));
        final result = const TrustedScriptRuntime().run(
          package: p,
          capability: 'grades.list',
          credentials: ScriptCredentials(
            store: CredentialStore(
              store: InMemorySecureStore(releaseMode: false),
            ),
            schoolId: 'synthetic',
            scriptId: p.manifest.id,
            sdkVersion: sdk,
          ),
          fetch: (_, _) async =>
              throw const ScriptRunException('process_request_limit'),
        );
        if (sdk == 20) {
          await expectLater(
            result,
            throwsA(
              isA<ScriptRunException>().having(
                (e) => e.code,
                'code',
                'process_request_limit',
              ),
            ),
          );
        } else {
          expect(await result, isA<Map>());
        }
      }
    },
  );
  test(
    'queued invocation pins the digest whose credential declaration acquired the lease',
    () async {
      final original = source(id: 'synthetic.pinned');
      final blocker = source(id: 'synthetic.blocker', sdk: 19, keys: null);
      final session = await prepare([original, blocker]);
      final started = Completer<void>();
      final cancellation = ScriptRunCancellation();
      addTearDown(cancellation.dispose);
      final running = session.runTrustedScript(
        blocker.manifest.id,
        'grades.list',
        params: {'delay': 3000},
        cancellation: cancellation,
        onLog: (_, _) {
          if (!started.isCompleted) started.complete();
        },
      );
      await started.future;
      final queued = session.runTrustedScript(
        original.manifest.id,
        'grades.list',
        params: {'delay': 1},
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final raw =
          jsonDecode(
                source(
                  id: 'synthetic.pinned',
                  keys: [
                    {'namespace': 'shared.auth', 'key': 'new'},
                  ],
                  extra:
                      "await ctx.credentials.set('new','unexpected',{namespace:'shared.auth'});",
                ).encode(),
              )
              as Map<String, dynamic>;
      raw['manifest']['version'] = '2.0.0';
      final replacement = ScriptPackage.parse(jsonEncode(raw));
      // Change the registry epoch without Session's broader generation invalidation,
      // reproducing an update observed during its asynchronous persistence window.
      await (await session.scriptRegistry).install(
        replacement,
        approvedDigest: replacement.digest,
      );
      cancellation.cancel();
      await running;
      expect((await queued).reason, 'script_not_authorized');
      expect(
        session.credentialCount,
        0,
        reason:
            'New source must not execute under the old empty credential lease.',
      );
    },
  );
}
