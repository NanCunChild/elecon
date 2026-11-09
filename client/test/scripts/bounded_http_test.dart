import 'dart:async';
import 'dart:io';
import 'package:elecon/core/scripts/http_transport.dart';
import 'package:elecon/core/scripts/network_policy.dart';
import 'package:elecon/core/scripts/request_budget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'global HTTP admits eight requests, at most two per origin, and releases permits',
    () async {
      final servers = <HttpServer>[],
          clients = <ScriptHttpTransport>[],
          requests = <HttpRequest>[];
      final ready = Completer<void>();
      addTearDown(() async {
        for (final c in clients) {
          c.close();
        }
        for (final s in servers) {
          await s.close(force: true);
        }
      });
      for (var i = 0; i < 5; i++) {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        servers.add(server);
        final origin = 'http://127.0.0.1:${server.port}';
        server.listen((r) {
          requests.add(r);
          if (requests.length == 8 && !ready.isCompleted) ready.complete();
        });
        clients.add(
          ScriptHttpTransport(
            policy: ScriptNetworkPolicy.fromJson({
              'origins': [origin],
              'ipAllow': ['127.0.0.1'],
            }),
          ),
        );
      }
      final calls = <Future<Map<String, Object?>>>[];
      for (var i = 0; i < 5; i++) {
        for (var j = 0; j < 2; j++) {
          calls.add(
            clients[i].fetch('http://127.0.0.1:${servers[i].port}', {}),
          );
        }
      }
      await ready.future.timeout(const Duration(seconds: 3));
      expect(requests.length, 8);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(requests.length, 8);
      for (final r in requests.toList()) {
        await r.response.close();
      }
      for (var i = 0; i < 100 && requests.length < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(requests.length, 10);
      for (final r in requests.skip(8)) {
        await r.response.close();
      }
      await Future.wait(calls);
    },
  );
  test(
    'per-origin HTTP queues the third call and parent budget spans transports',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}',
          pending = <HttpRequest>[];
      final two = Completer<void>();
      server.listen((r) {
        pending.add(r);
        if (pending.length == 2) two.complete();
      });
      final budget = ScriptRequestBudget(limit: 3);
      final clients = List.generate(
        3,
        (_) => ScriptHttpTransport(
          policy: ScriptNetworkPolicy.fromJson({
            'origins': [origin],
            'ipAllow': ['127.0.0.1'],
          }),
          budget: budget,
        ),
      );
      addTearDown(() {
        for (final c in clients) {
          c.close();
        }
      });
      final calls = [for (final c in clients) c.fetch(origin, {})];
      await two.future;
      expect(pending.length, 2);
      expect(budget.remaining, 1);
      await pending.first.response.close();
      for (var i = 0; i < 100 && pending.length < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(pending.length, 3);
      for (final r in pending.skip(1)) {
        await r.response.close();
      }
      await Future.wait(calls);
      await expectLater(
        clients.first.fetch(origin, {}),
        throwsA(
          isA<ScriptNetworkException>().having(
            (e) => e.code,
            'code',
            'process_request_limit',
          ),
        ),
      );
    },
  );
  test(
    'HTTP 429 pauses the shared source window before another transport dispatches',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var calls = 0;
      server.listen((r) {
        calls++;
        r.response.statusCode = 429;
        r.response.headers.set('retry-after', '60');
        unawaited(r.response.close());
      });
      final origin = 'http://127.0.0.1:${server.port}',
          window = ScriptRequestWindow();
      final policy = ScriptNetworkPolicy.fromJson({
        'origins': [origin],
        'ipAllow': ['127.0.0.1'],
      });
      final first = ScriptHttpTransport(policy: policy, window: window),
          second = ScriptHttpTransport(policy: policy, window: window);
      addTearDown(() {
        first.close();
        second.close();
      });
      expect((await first.fetch(origin, {}))['status'], 429);
      await expectLater(
        second.fetch(origin, {}),
        throwsA(
          isA<ScriptNetworkException>().having(
            (e) => e.code,
            'code',
            'process_request_limit',
          ),
        ),
      );
      expect(calls, 1);
    },
  );
  test(
    'DNS timeout frees all global permits even when resolver futures never finish',
    () async {
      final clients = <ScriptHttpTransport>[];
      addTearDown(() {
        for (final c in clients) {
          c.close();
        }
      });
      final failures = <Future<void>>[];
      for (var i = 0; i < 8; i++) {
        final origin = 'http://never-$i.invalid';
        final c = ScriptHttpTransport(
          policy: ScriptNetworkPolicy.fromJson({
            'origins': [origin],
          }),
          resolver: (_) => Completer<List<InternetAddress>>().future,
          requestTimeout: const Duration(milliseconds: 60),
        );
        clients.add(c);
        failures.add(
          expectLater(
            c.fetch(origin, {}),
            throwsA(
              isA<ScriptNetworkException>().having(
                (e) => e.code,
                'code',
                'request_timeout',
              ),
            ),
          ),
        );
      }
      await Future.wait(failures);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) => r.response.close());
      final origin = 'http://127.0.0.1:${server.port}';
      final normal = ScriptHttpTransport(
        policy: ScriptNetworkPolicy.fromJson({
          'origins': [origin],
          'ipAllow': ['127.0.0.1'],
        }),
        requestTimeout: const Duration(seconds: 1),
      );
      clients.add(normal);
      expect((await normal.fetch(origin, {}))['status'], 200);
    },
  );
}
