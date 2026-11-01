import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:elecon/core/scripts/network_policy.dart';
import 'package:elecon/core/scripts/websocket_transport.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher failure(String code) =>
    throwsA(isA<ScriptNetworkException>().having((e) => e.code, 'code', code));
void main() {
  late HttpServer server;
  late String origin;
  late SecurityContext trusted;
  late Future<void> Function(HttpRequest) handler;
  final transports = <ScriptWebSocketTransport>[];
  final peers = <WebSocket>[];
  final rawPeers = <Socket>[];
  setUp(() async {
    final tls = SecurityContext()
      ..useCertificateChain('test/fixtures/websocket/synthetic-cert.txt')
      ..usePrivateKey('test/fixtures/websocket/synthetic-key.txt');
    trusted = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates('test/fixtures/websocket/synthetic-cert.txt');
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls);
    origin = 'wss://localhost:${server.port}';
    handler = (request) async {
      final peer = await WebSocketTransformer.upgrade(request);
      peers.add(peer);
      peer.listen(peer.add, onError: (Object _) {});
    };
    server.listen((request) {
      unawaited(handler(request));
    }, onError: (Object _) {});
  });
  tearDown(() async {
    for (final transport in transports) {
      transport.close();
    }
    transports.clear();
    for (final peer in peers) {
      unawaited(peer.close());
    }
    peers.clear();
    for (final peer in rawPeers) {
      peer.destroy();
    }
    rawPeers.clear();
    await server.close(force: true);
  });
  ScriptWebSocketTransport make({
    List<String>? ipAllow,
    SecurityContext? trust,
  }) {
    final t = ScriptWebSocketTransport(
      policy: ScriptNetworkPolicy.fromJson({
        'origins': [origin.replaceFirst('wss:', 'https:')],
        'ipAllow': ipAllow ?? ['127.0.0.1'],
      }),
      resolver: (_) async => [InternetAddress.loopbackIPv4],
      securityContext: trust ?? trusted,
    );
    transports.add(t);
    return t;
  }

  Future<Socket> rawUpgrade(HttpRequest request) async {
    final key = request.headers.value('sec-websocket-key')!;
    request.response.statusCode = 101;
    request.response.headers.set('upgrade', 'websocket');
    request.response.headers.set('connection', 'Upgrade');
    request.response.headers.set(
      'sec-websocket-accept',
      base64Encode(
        sha1
            .convert(ascii.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
            .bytes,
      ),
    );
    final peer = await request.response.detachSocket(writeHeaders: true);
    rawPeers.add(peer);
    unawaited(peer.done.then<void>((_) {}, onError: (Object _) {}));
    return peer;
  }

  test(
    'pinned DNS with real TLS, masked binary sends and timeout without reconnect',
    () async {
      final t = make();
      await t.call('open', {'url': '$origin/messages'});
      await t.call('send', {
        'bytes': [0, 127, 128, 255],
      });
      expect(await t.call('receive', {'timeoutMs': 1000}), [0, 127, 128, 255]);
      expect(await t.call('receive', {'timeoutMs': 10}), isNull);
      await expectLater(
        t.call('open', {'url': origin}),
        failure('websocket_open_limit'),
      );
    },
  );
  test(
    'wrong origin, plaintext and credentials in URL never connect',
    () async {
      final t = make();
      for (final url in [
        'ws://localhost:${server.port}',
        'wss://other.invalid',
        'wss://user@localhost:${server.port}',
        '$origin/#fragment',
      ]) {
        await expectLater(
          t.call('open', {'url': url}),
          throwsA(isA<ScriptNetworkException>()),
        );
      }
      expect(peers, isEmpty);
    },
  );
  test('IP deny and untrusted certificate fail handshake', () async {
    await expectLater(
      make(ipAllow: []).call('open', {'url': origin}),
      failure('websocket_handshake_failed'),
    );
    await expectLater(
      make(
        trust: SecurityContext(withTrustedRoots: false),
      ).call('open', {'url': origin}),
      failure('websocket_handshake_failed'),
    );
    expect(peers, isEmpty);
  });
  test('redirect is rejected before a second request', () async {
    var requests = 0;
    handler = (request) async {
      requests++;
      request.response.statusCode = 302;
      request.response.headers.set('location', '$origin/other');
      await request.response.close();
    };
    await expectLater(
      make().call('open', {'url': origin}),
      failure('websocket_handshake_failed'),
    );
    expect(requests, 1);
  });
  test('fragmented binary with interleaved ping reassembles', () async {
    handler = (request) async {
      final peer = await rawUpgrade(request);
      peer.add([2, 2, 1, 2, 137, 1, 7, 128, 2, 3, 4]);
    };
    final t = make();
    await t.call('open', {'url': origin});
    expect(await t.call('receive', {'timeoutMs': 1000}), [1, 2, 3, 4]);
  });
  for (final entry in <String, List<int>>{
    'oversized header': [130, 127, 0, 0, 0, 0, 0, 2, 0, 0],
    'masked server frame': [130, 128],
    'orphan continuation': [128, 0],
    'RSV compression': [194, 0],
    'unbounded fragmented data': [
      2,
      126,
      255,
      255,
      ...List.filled(65535, 1),
      128,
      2,
      2,
      3,
    ],
  }.entries) {
    test('${entry.key} closes before delivering data', () async {
      handler = (request) async {
        final peer = await rawUpgrade(request);
        peer.add(entry.value);
      };
      final t = make();
      await t.call('open', {'url': origin});
      await expectLater(
        t.call('receive', {'timeoutMs': 1000}),
        throwsA(isA<ScriptNetworkException>()),
      );
    });
  }
  test(
    'cancellation releases a pending receive and prevents later sends',
    () async {
      final t = make();
      await t.call('open', {'url': origin});
      final pending = t.call('receive', {'timeoutMs': 5000});
      final assertion = expectLater(pending, failure('websocket_closed'));
      t.close();
      await assertion;
      await expectLater(
        t.call('send', {
          'bytes': [1],
        }),
        failure('websocket_closed'),
      );
    },
  );
}
