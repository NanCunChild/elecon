import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/scripts/http_transport.dart';
import 'package:elecon/core/scripts/network_policy.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher failure(String code) => throwsA(
  isA<ScriptNetworkException>().having((error) => error.code, 'code', code),
);

void main() {
  late HttpServer server;
  late String origin;
  late Future<void> Function(HttpRequest) handler;
  final clients = <ScriptHttpTransport>[];

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    handler = (request) async {
      request.response.write('ok');
      await request.response.close();
    };
    server.listen((request) => unawaited(handler(request)));
  });

  tearDown(() async {
    for (final client in clients) {
      client.close();
    }
    clients.clear();
    await server.close(force: true);
  });

  ScriptHttpTransport transport({
    List<String>? origins,
    List<String>? ipAllow = const ['127.0.0.1'],
    ScriptAddressResolver? resolver,
    int maxRequests = 40,
    int maxResponseBytes = 8 * 1024 * 1024,
    int maxTotalResponseBytes = 16 * 1024 * 1024,
    int maxRedirects = 8,
    Duration requestTimeout = const Duration(seconds: 3),
  }) {
    final client = ScriptHttpTransport(
      policy: ScriptNetworkPolicy.fromJson({
        'origins': origins ?? [origin],
        'ipAllow': ?ipAllow,
      }),
      resolver: resolver,
      maxRequests: maxRequests,
      maxResponseBytes: maxResponseBytes,
      maxTotalResponseBytes: maxTotalResponseBytes,
      maxRedirects: maxRedirects,
      requestTimeout: requestTimeout,
    );
    clients.add(client);
    return client;
  }

  test(
    'script auth/body reaches origin and raw Set-Cookie remains readable',
    () async {
      handler = (request) async {
        expect(request.method, 'POST');
        expect(
          request.headers.value('authorization'),
          'Bearer SYNTHETIC_TOKEN',
        );
        expect(request.headers.value('cookie'), 'session=SYNTHETIC_COOKIE');
        expect(await utf8.decoder.bind(request).join(), '{"node":"SYNTHETIC"}');
        request.response.headers.add('set-cookie', 'a=ONE; HttpOnly; Path=/');
        request.response.headers.add('set-cookie', 'b=TWO; Path=/');
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"value":42}');
        await request.response.close();
      };
      final response = await transport().fetch('$origin/api', {
        'method': 'POST',
        'headers': {
          'Authorization': 'Bearer SYNTHETIC_TOKEN',
          'Cookie': 'session=SYNTHETIC_COOKIE',
        },
        'body': '{"node":"SYNTHETIC"}',
      });
      expect(response['status'], 200);
      expect(response['body'], '{"value":42}');
      expect((response['headers'] as Map)['set-cookie'], hasLength(2));
    },
  );

  test(
    'DNS result is pinned to socket while real hostname is retained',
    () async {
      var resolutions = 0;
      var requests = 0;
      handler = (request) async {
        requests++;
        expect(request.headers.value('host'), 'campus.invalid:${server.port}');
        request.response.write('pinned');
        await request.response.close();
      };
      final target = 'http://campus.invalid:${server.port}';
      final client = transport(
        origins: [target],
        resolver: (host) async {
          expect(host, 'campus.invalid');
          resolutions++;
          return [InternetAddress.loopbackIPv4];
        },
      );
      expect((await client.fetch('$target/one', {}))['body'], 'pinned');
      expect((await client.fetch('$target/two', {}))['body'], 'pinned');
      expect(resolutions, 2);
      expect(requests, 2);
    },
  );

  test(
    'origin denied before DNS and DNS IP denied before connection',
    () async {
      var resolutions = 0;
      final target = 'http://campus.invalid:${server.port}';
      final client = transport(
        origins: [target],
        resolver: (_) async {
          resolutions++;
          return [InternetAddress('192.0.2.1')];
        },
      );
      await expectLater(
        client.fetch('http://outside.invalid/private?token=SECRET', {}),
        failure('origin_not_allowed'),
      );
      expect(resolutions, 0);
      await expectLater(client.fetch(target, {}), failure('ip_not_allowed'));
      expect(resolutions, 1);
    },
  );

  test('empty IP allow denies literal targets', () async {
    await expectLater(
      transport(ipAllow: []).fetch(origin, {}),
      failure('ip_not_allowed'),
    );
  });

  test(
    'cross-origin redirect target rejected without leaking intermediate body',
    () async {
      handler = (request) async {
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          'http://outside.invalid/secret?token=SECRET',
        );
        request.response.write('SECRET_BODY');
        await request.response.close();
      };
      await expectLater(
        transport().fetch('$origin/start', {}),
        failure('origin_not_allowed'),
      );
    },
  );

  test('manual redirect exposes Location and error mode refuses it', () async {
    handler = (request) async {
      request.response.statusCode = 302;
      request.response.headers.set('location', '/next?ticket=SYNTHETIC');
      request.response.write('intermediate');
      await request.response.close();
    };
    final response = await transport().fetch('$origin/start', {
      'redirect': 'manual',
    });
    expect(response['status'], 302);
    expect((response['headers'] as Map)['location'], [
      '/next?ticket=SYNTHETIC',
    ]);
    await expectLater(
      transport().fetch('$origin/start', {'redirect': 'error'}),
      failure('redirect_disallowed'),
    );
  });

  test('follow does not turn Set-Cookie into an implicit jar', () async {
    handler = (request) async {
      if (request.uri.path == '/start') {
        request.response.statusCode = 302;
        request.response.headers.set('location', '/next');
        request.response.headers.add('set-cookie', 'session=SYNTHETIC');
      } else {
        expect(request.headers.value('cookie'), isNull);
        request.response.write('done');
      }
      await request.response.close();
    };
    expect((await transport().fetch('$origin/start', {}))['body'], 'done');
  });

  test(
    'admitted cross-origin redirects strip auth and custom secret headers',
    () async {
      final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final otherOrigin = 'http://127.0.0.1:${other.port}';
      final received = Completer<void>();
      other.listen((request) async {
        expect(request.headers.value('authorization'), isNull);
        expect(request.headers.value('cookie'), isNull);
        expect(request.headers.value('x-school-token'), isNull);
        expect(request.headers.value('accept'), 'application/json');
        request.response.write('other');
        await request.response.close();
        received.complete();
      });
      addTearDown(() => other.close(force: true));
      handler = (request) async {
        request.response.statusCode = 302;
        request.response.headers.set('location', '$otherOrigin/next');
        await request.response.close();
      };
      final response = await transport(origins: [origin, otherOrigin]).fetch(
        origin,
        {
          'headers': {
            'Authorization': 'SECRET',
            'Cookie': 'a=SECRET',
            'X-School-Token': 'SECRET',
            'Accept': 'application/json',
          },
        },
      );
      expect(response['body'], 'other');
      await received.future;
    },
  );

  test(
    '307 cross-origin body replay requires explicit manual handling',
    () async {
      final other = 'http://127.0.0.1:${server.port + 1}';
      handler = (request) async {
        await request.drain<void>();
        request.response.statusCode = 307;
        request.response.headers.set('location', other);
        await request.response.close();
      };
      await expectLater(
        transport(
          origins: [origin, other],
        ).fetch(origin, {'method': 'POST', 'body': 'SECRET'}),
        failure('redirect_body_requires_manual'),
      );
    },
  );

  test('redirect and cumulative hop budgets are enforced', () async {
    var seen = 0;
    handler = (request) async {
      seen++;
      request.response.statusCode = 302;
      request.response.headers.set('location', '/again');
      await request.response.close();
    };
    await expectLater(
      transport(maxRedirects: 1).fetch(origin, {}),
      failure('redirect_limit'),
    );
    expect(seen, 2);
    seen = 0;
    await expectLater(
      transport(maxRequests: 1).fetch(origin, {}),
      failure('request_count_limit'),
    );
    expect(seen, 1);
  });

  test('response and cumulative byte budgets reject oversized data', () async {
    handler = (request) async {
      request.response.write('12345');
      await request.response.close();
    };
    await expectLater(
      transport(maxResponseBytes: 4).fetch(origin, {}),
      failure('response_body_limit'),
    );
    final client = transport(maxTotalResponseBytes: 8);
    await client.fetch(origin, {});
    await expectLater(client.fetch(origin, {}), failure('response_body_limit'));
  });

  test('close cancels pending DNS and prevents late connections', () async {
    final lookup = Completer<List<InternetAddress>>();
    var seen = 0;
    handler = (request) async {
      seen++;
      await request.response.close();
    };
    final target = 'http://campus.invalid:${server.port}';
    final client = transport(origins: [target], resolver: (_) => lookup.future);
    final run = expectLater(
      client.fetch(target, {}),
      failure('transport_closed'),
    );
    await Future<void>.delayed(Duration.zero);
    client.close();
    lookup.complete([InternetAddress.loopbackIPv4]);
    await run;
    expect(seen, 0);
    await expectLater(client.fetch(target, {}), failure('transport_closed'));
  });

  test('timeout closes transport work and never includes secret URL', () async {
    handler = (request) async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      try {
        await request.response.close();
      } catch (_) {}
    };
    final client = transport(requestTimeout: const Duration(milliseconds: 30));
    await expectLater(
      client.fetch('$origin/?token=SECRET', {}),
      failure('request_timeout'),
    );
  });

  test(
    'framing headers, invalid methods and injected header lines are denied',
    () async {
      for (final header in [
        'Host',
        'Content-Length',
        'Connection',
        'Proxy-Authorization',
      ]) {
        await expectLater(
          transport().fetch(origin, {
            'headers': {header: 'SECRET'},
          }),
          failure('reserved_header'),
        );
      }
      await expectLater(
        transport().fetch(origin, {'method': 'GET\r\nBAD'}),
        failure('invalid_method'),
      );
      await expectLater(
        transport().fetch(origin, {
          'headers': {'x-test': 'SECRET\r\nInjected: value'},
        }),
        failure('invalid_headers'),
      );
    },
  );
  test('request budget is reserved atomically before concurrent DNS', () async {
    final lookup = Completer<List<InternetAddress>>();
    final target = 'http://campus.invalid:${server.port}';
    final client = transport(
      origins: [target],
      maxRequests: 1,
      resolver: (_) => lookup.future,
    );
    final first = client.fetch(target, {});
    await Future<void>.delayed(Duration.zero);
    await expectLater(client.fetch(target, {}), failure('request_count_limit'));
    lookup.complete([InternetAddress.loopbackIPv4]);
    expect((await first)['body'], 'ok');
  });

  test('HTTPS connector performs TLS and never sends plain HTTP', () async {
    final socketServer = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final firstByte = Completer<int>();
    socketServer.listen((socket) {
      socket.listen((bytes) {
        if (!firstByte.isCompleted) firstByte.complete(bytes.first);
        socket.destroy();
      }, onError: (_) {});
    });
    addTearDown(() => socketServer.close());
    final target = 'https://127.0.0.1:${socketServer.port}';
    await expectLater(
      transport(origins: [target]).fetch(target, {}),
      failure('connection_failed'),
    );
    expect(await firstByte.future, 22); // TLS handshake content type.
  });

  test('close aborts an active response stream', () async {
    final started = Completer<void>();
    handler = (request) async {
      request.response.write('partial');
      await request.response.flush();
      started.complete();
    };
    final client = transport();
    final result = expectLater(
      client.fetch(origin, {}),
      failure('transport_closed'),
    );
    await started.future;
    client.close();
    await result;
  });

  test('request body size and malformed URL fail before connecting', () async {
    final client = ScriptHttpTransport(
      policy: ScriptNetworkPolicy.fromJson({
        'origins': [origin],
      }),
      maxRequestBytes: 4,
    );
    clients.add(client);
    await expectLater(
      client.fetch(origin, {'method': 'POST', 'body': '12345'}),
      failure('request_body_limit'),
    );
    await expectLater(
      client.fetch('http://[invalid?token=SECRET', {}),
      failure('invalid_url'),
    );
  });
}
