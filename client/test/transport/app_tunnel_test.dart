import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/adapter_service.dart';
import '../support/school_fixture.dart';
import 'package:elecon/core/scripts/http_transport.dart';
import 'package:elecon/core/scripts/network_policy.dart';
import 'package:elecon/core/scripts/websocket_transport.dart';
import 'package:elecon/core/transport/app_tunnel.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class SyntheticProvider implements AppTunnelProvider {
  @override
  String get id => 'synthetic';
  @override
  String get name => 'Synthetic';
  @override
  bool isAvailable = true;
  final connection = SyntheticConnection();
  int opens = 0;
  Completer<AppTunnelConnection>? opening;
  @override
  Future<AppTunnelConnection> open({required String schoolId}) async {
    opens++;
    return opening?.future ?? connection;
  }
}

class SyntheticConnection implements AppTunnelConnection {
  final hosts = <String>[];
  final destinations = <String>[];
  List<InternetAddress> addresses = [InternetAddress.loopbackIPv4];
  bool failDns = false;
  bool failDial = false;
  int closed = 0;
  Completer<List<InternetAddress>>? resolving;
  Completer<Socket>? dialing;
  @override
  Future<List<InternetAddress>> resolve(String host) async {
    hosts.add(host);
    if (failDns) throw StateError('SYNTHETIC_PRIVATE_ERROR');
    return resolving?.future ?? addresses;
  }

  @override
  Future<ConnectionTask<Socket>> connect(
    String host,
    InternetAddress address,
    int port,
  ) {
    destinations.add('$host/${address.address}:$port');
    if (failDial) throw StateError('SYNTHETIC_PRIVATE_ERROR');
    return dialing == null
        ? Socket.startConnect(address, port)
        : Future.value(ConnectionTask.fromSocket(dialing!.future, () {}));
  }

  @override
  void close() => closed++;
}

class FailingBlobs extends InMemoryBlobStore {
  @override
  Future<void> write(String name, List<int> bytes) async =>
      throw StateError('disk');
}

class CorruptRouteBlobs extends InMemoryBlobStore {
  bool corrupt = true;
  @override
  Future<Uint8List?> read(String name) async => corrupt
      ? Uint8List.fromList(utf8.encode('{"version":1,"schoolId":"a"}'))
      : super.read(name);
  @override
  Future<void> write(String name, List<int> bytes) async {
    corrupt = false;
    await super.write(name, bytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // These checks intentionally exercise actual loopback sockets, including TLS.
  HttpOverrides.global = null;
  test(
    'host selection revokes in-flight work, blocks browser bypass and restores per school',
    () async {
      final blobs = InMemoryBlobStore();
      final provider = SyntheticProvider();
      final session = SessionController(
        appTunnelProviders: [provider],
        blobStoreProvider: () async => blobs,
      );
      addTearDown(session.dispose);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var hits = 0;
      server.listen((r) {
        hits++;
        r.response.close();
      });
      final origin = 'http://synthetic.invalid:${server.port}';
      ScriptPackage package(String school) => ScriptPackage.parse(
        jsonEncode({
          'format': 'elecon-script/1',
          'manifest': {
            'sdkVersion': 9,
            'id': 'synthetic-$school',
            'schoolId': school,
            'version': '1.0.0',
            'name': 'Synthetic',
            'browser': true,
            'network': {
              'origins': [origin],
            },
            'capabilities': [
              {
                'id': 'notice.list',
                'schema': 'elecon.notice.list',
                'schemaVersion': '1.1',
              },
              {
                'id': 'messages.session',
                'schema': 'elecon.messages.session',
                'schemaVersion': '1.0',
              },
            ],
          },
          'source':
              '''export const capabilities = {
        'notice.list': async ctx => { await ctx.fetch('$origin/read'); return {items: []}; },
        'messages.session': async ctx => {
          await ctx.browser.open('$origin/login');
          return {serviceId:'synthetic',serviceName:'Synthetic',status:'signedOut'};
        }
      };''',
        }),
      );
      final first = package('first');
      final second = package('second');
      for (final p in [first, second]) {
        await session.installTrustedScript(p, approvedDigest: p.digest);
      }
      await session.selectTrustedScriptSchool(first.manifest.id);
      final generation = session.trustedScriptViewGeneration;
      await session.selectAppTunnel(provider.id);
      expect(session.trustedScriptViewGeneration, greaterThan(generation));
      expect(await session.appTunnelChoice(), provider.id);
      final good = await session.runTrustedScript(
        first.manifest.id,
        'notice.list',
      );
      expect(good.ok, isTrue, reason: good.reason);
      expect(hits, 1);
      var browserCalls = 0;
      final blocked = await session.runTrustedScript(
        first.manifest.id,
        'messages.session',
        params: {'operation': 'login'},
        browserCall: (_, _) async {
          browserCalls++;
          return null;
        },
      );
      expect(blocked.ok, isFalse);
      expect(browserCalls, 0);
      provider.connection.resolving = Completer<List<InternetAddress>>();
      final pending = session.runTrustedScript(
        first.manifest.id,
        'notice.list',
      );
      while (provider.connection.hosts.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await session.selectAppTunnel(null);
      provider.connection.resolving!.complete([InternetAddress.loopbackIPv4]);
      expect((await pending).ok, isFalse);
      expect(hits, 1);
      await session.selectTrustedScriptSchool(second.manifest.id);
      expect(await session.appTunnelChoice(), isNull);
      await session.selectAppTunnel(provider.id);
      await session.selectTrustedScriptSchool(first.manifest.id);
      expect(await session.appTunnelChoice(), isNull);
    },
  );
  test(
    'corrupt selection cannot become direct and individual cancelled dials destroy late sockets',
    () async {
      final malformed = CorruptRouteBlobs();
      final provider = SyntheticProvider();
      final routing = AppTunnelRouting(
        blobs: () async => malformed,
        providers: [provider],
      );
      await expectLater(
        routing.choice('a'),
        throwsA(isA<AppTunnelException>()),
      );
      await routing.save('a', null);
      expect(await routing.choice('a'), isNull);
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final ended = Completer<void>();
      server.listen((peer) {
        peer.listen(
          (_) {},
          onDone: () {
            if (!ended.isCompleted) ended.complete();
            peer.destroy();
          },
        );
      });
      provider.connection.dialing = Completer<Socket>();
      final route = AppTunnelRoute(provider, 'a');
      addTearDown(route.close);
      final task = await route.connect(
        'localhost',
        InternetAddress.loopbackIPv4,
        server.port,
      );
      final failed = expectLater(
        task.socket,
        throwsA(isA<AppTunnelException>()),
      );
      task.cancel();
      provider.connection.dialing!.complete(
        await Socket.connect(InternetAddress.loopbackIPv4, server.port),
      );
      await failed;
      await ended.future.timeout(const Duration(seconds: 2));
      // This request was cancelled, not the entire script's tunnel lease.
      expect(await route.resolve('localhost'), isNotEmpty);
    },
  );

  test(
    'V1 work prevents a route switch until its uncancellable operation finishes',
    () async {
      final entered = Completer<void>();
      final service = Completer<AdapterService?>();
      final provider = SyntheticProvider();
      final session = SessionController(
        appTunnelProviders: [provider],
        adapterServiceProvider: () {
          entered.complete();
          return service.future;
        },
      );
      addTearDown(session.dispose);
      final school = testSchool();
      session.selectSchool(school);
      final pending = session.runAdapterCapability(
        adapterId: school.adapterId,
        capability: 'notice.list',
        htmlStdlib: '',
      );
      await entered.future;
      await expectLater(
        session.selectAppTunnel(provider.id),
        throwsA(isA<AppTunnelException>()),
      );
      expect(await session.appTunnelChoice(), isNull);
      service.complete(null);
      await pending;
      await session.selectAppTunnel(provider.id);
      await expectLater(
        session.createWebViewAuthBridge(login: school.login),
        throwsA(isA<AppTunnelException>()),
      );
    },
  );

  test(
    'routing choices persist independently per school/profile and preserve unavailable selections',
    () async {
      final blobs = InMemoryBlobStore();
      final provider = SyntheticProvider();
      final routing = AppTunnelRouting(
        blobs: () async => blobs,
        providers: [provider],
      );
      expect(await routing.choice('a'), isNull);
      await routing.save('a', provider.id);
      expect(await routing.choice('b'), isNull);
      final reopened = AppTunnelRouting(
        blobs: () async => blobs,
        providers: [],
      );
      expect(await reopened.choice('a'), provider.id);
      await expectLater(
        reopened.route('a'),
        throwsA(isA<AppTunnelException>()),
      );
      expect(
        await AppTunnelRouting(
          blobs: () async => InMemoryBlobStore(),
          providers: [provider],
        ).choice('a'),
        isNull,
      );
      final failing = AppTunnelRouting(
        blobs: () async => FailingBlobs(),
        providers: [provider],
      );
      expect(await failing.choice('a'), isNull);
      await expectLater(failing.save('a', provider.id), throwsStateError);
      expect(await failing.choice('a'), isNull);
    },
  );

  test(
    'actual HTTP uses tunnel DNS and the admitted address; an origin redirect cannot bypass policy',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          'http://forbidden.invalid/secret',
        );
        await request.response.close();
      });
      final provider = SyntheticProvider();
      final route = AppTunnelRoute(provider, 'synthetic-school');
      addTearDown(route.close);
      final origin = 'http://tunnel.invalid:${server.port}';
      final transport = ScriptHttpTransport(
        policy: ScriptNetworkPolicy.fromJson({
          'origins': [origin],
          'ipAllow': ['127.0.0.1'],
        }),
        appTunnel: route,
        resolver: (_) async => throw StateError('must not resolve directly'),
      );
      addTearDown(transport.close);
      await expectLater(
        transport.fetch('$origin/start', {}),
        throwsA(isA<ScriptNetworkException>()),
      );
      expect(requests, 1);
      expect(provider.opens, 1);
      expect(provider.connection.hosts, ['tunnel.invalid']);
      expect(provider.connection.destinations, [
        'tunnel.invalid/127.0.0.1:${server.port}',
      ]);
    },
  );

  test(
    'tunnel DNS failure, unavailable provider and CIDR rejection never dial directly',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) {
        requests++;
        request.response.close();
      });
      for (final mode in ['dns', 'unavailable', 'cidr', 'dial']) {
        final provider = SyntheticProvider();
        provider.isAvailable = mode != 'unavailable';
        provider.connection.failDns = mode == 'dns';
        provider.connection.failDial = mode == 'dial';
        final route = AppTunnelRoute(provider, 'synthetic-school');
        final transport = ScriptHttpTransport(
          policy: ScriptNetworkPolicy.fromJson({
            'origins': ['http://localhost:${server.port}'],
            'ipAllow': [mode == 'cidr' ? '192.0.2.0/24' : '127.0.0.1'],
          }),
          appTunnel: route,
        );
        await expectLater(
          transport.fetch('http://localhost:${server.port}/', {}),
          throwsA(isA<ScriptNetworkException>()),
        );
        expect(provider.connection.destinations.length, mode == 'dial' ? 1 : 0);
        transport.close();
        route.close();
      }
      expect(requests, 0);
    },
  );

  test('WSS retains target TLS verification through the tunnel', () async {
    final tls = SecurityContext()
      ..useCertificateChain('test/fixtures/websocket/synthetic-cert.txt')
      ..usePrivateKey('test/fixtures/websocket/synthetic-key.txt');
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      tls,
    );
    addTearDown(() => server.close(force: true));
    final peers = <WebSocket>[];
    addTearDown(() async {
      for (final p in peers) {
        await p.close();
      }
    });
    var upgrades = 0;
    server.listen((request) async {
      upgrades++;
      final peer = await WebSocketTransformer.upgrade(request);
      peers.add(peer);
      peer.listen(peer.add);
    });
    for (final trust in [false, true]) {
      final provider = SyntheticProvider();
      final route = AppTunnelRoute(provider, 'synthetic-school');
      final transport = ScriptWebSocketTransport(
        policy: ScriptNetworkPolicy.fromJson({
          'origins': ['https://localhost:${server.port}'],
        }),
        appTunnel: route,
        securityContext: trust
            ? (SecurityContext(withTrustedRoots: false)..setTrustedCertificates(
                'test/fixtures/websocket/synthetic-cert.txt',
              ))
            : null,
      );
      if (trust) {
        await transport.call('open', {
          'url': 'wss://localhost:${server.port}/',
        });
        await transport.call('send', {
          'bytes': [1, 2, 3],
        });
        expect(await transport.call('receive', {'timeoutMs': 1000}), [1, 2, 3]);
      } else {
        await expectLater(
          transport.call('open', {'url': 'wss://localhost:${server.port}/'}),
          throwsA(isA<ScriptNetworkException>()),
        );
      }
      transport.close();
      route.close();
    }
    expect(upgrades, 1);
  });

  test(
    'cancellation disposes late native initialization and blocks late DNS',
    () async {
      final provider = SyntheticProvider()
        ..opening = Completer<AppTunnelConnection>();
      final route = AppTunnelRoute(provider, 'a');
      final future = route.resolve('synthetic.invalid');
      final expectation = expectLater(
        future,
        throwsA(isA<AppTunnelException>()),
      );
      route.close();
      provider.opening!.complete(provider.connection);
      await expectation;
      expect(provider.connection.closed, 1);
      expect(provider.connection.hosts, isEmpty);
      final second = SyntheticProvider();
      second.connection.resolving = Completer<List<InternetAddress>>();
      final secondRoute = AppTunnelRoute(second, 'a');
      final lookup = secondRoute.resolve('synthetic.invalid');
      final check = expectLater(lookup, throwsA(isA<AppTunnelException>()));
      await Future<void>.delayed(Duration.zero);
      secondRoute.close();
      second.connection.resolving!.complete([InternetAddress.loopbackIPv4]);
      await check;
      expect(second.connection.destinations, isEmpty);
      expect(second.connection.closed, 1);
    },
  );
}
