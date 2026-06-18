/// `direct` 档传输集成测试（Gate A · ADR-003 §2.2）—— 对本地 HttpServer 验证 DirectTransport
/// 正确映射请求/响应、暴露原始 Set-Cookie/Location、**不自动跟随重定向**（单跳）。
///
/// 纯 dart:io（host VM），不经 QuickJS。真实出网由 broker 经 Transport seam 消费（B6b 运行时）。
///
///   运行：cd client && fvm flutter test test/transport_direct_test.dart
///
/// 🔒 transport 承载注入凭证的真实请求（红线 #1 路径）：与被测代码一并须人工 + 安全清单复核。
import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/broker/assemble.dart' show RequestInit;
import 'package:elecon/core/broker/cookie_jar.dart';
import 'package:elecon/core/broker/fetch_proxy.dart';
import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/broker/ports.dart';
import 'package:elecon/core/transport/direct.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoResolver implements CredentialResolver {
  @override
  Future<ResolvedCredential?> get(String ref) async => null;
}

void main() {
  late HttpServer server;
  late String base;
  late DirectTransport transport;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    transport = DirectTransport();
    server.listen((req) async {
      final res = req.response;
      switch (req.uri.path) {
        case '/echo':
          final body = await utf8.decoder.bind(req).join();
          res.statusCode = 200;
          res.headers.set('content-type', 'application/json');
          res.headers.add('set-cookie', 'a=1');
          res.headers.add('set-cookie', 'b=2'); // 多条 Set-Cookie
          res.write(jsonEncode({
            'method': req.method,
            'gotCookie': req.headers.value('cookie'),
            'gotAuth': req.headers.value('authorization'),
            'body': body,
          }));
          await res.close();
        case '/redirect':
          res.statusCode = 302;
          res.headers.set('location', '$base/echo');
          await res.close();
        default:
          res.statusCode = 404;
          await res.close();
      }
    });
  });

  tearDown(() async {
    transport.close();
    await server.close(force: true);
  });

  group('DirectTransport（对本地 HttpServer）', () {
    test('GET 映射 + 响应字段 + 多条 Set-Cookie 单独暴露', () async {
      final resp = await transport.fetch(TransportRequest(
        url: '$base/echo',
        method: 'GET',
        headers: const {'Cookie': 'JSESSIONID=S1', 'Authorization': 'Bearer T'},
      ));
      expect(resp.status, 200);
      final body = jsonDecode(resp.body!) as Map;
      expect(body['method'], 'GET');
      expect(body['gotCookie'], 'JSESSIONID=S1', reason: 'broker 注入的 Cookie 头应出站');
      expect(body['gotAuth'], 'Bearer T');
      expect(resp.setCookie, ['a=1', 'b=2'], reason: '原始 Set-Cookie 多条单独交回');
      expect(resp.headers.containsKey('set-cookie'), isFalse,
          reason: 'Set-Cookie 不并入普通响应头');
      expect(resp.headers['content-type'], contains('application/json'));
    });

    test('POST 携带 body', () async {
      final resp = await transport.fetch(TransportRequest(
        url: '$base/echo',
        method: 'POST',
        headers: const {'Content-Type': 'text/plain'},
        body: 'hello-body',
      ));
      final body = jsonDecode(resp.body!) as Map;
      expect(body['method'], 'POST');
      expect(body['body'], 'hello-body');
    });

    test('重定向不自动跟随（单跳）→ 302 + Location 交回核心', () async {
      final resp = await transport.fetch(TransportRequest(
        url: '$base/redirect',
        method: 'GET',
        headers: const {},
      ));
      expect(resp.status, 302, reason: '不跟随 → 返回 302 本身（跟随了会是 200）');
      expect(resp.location, '$base/echo', reason: 'Location 暴露给核心（B3 跟随）');
      expect(resp.body, isEmpty, reason: '未自动抓取 /echo');
    });
  });

  group('proxyFetch over DirectTransport（端到端真网络）', () {
    test('核心自跟随重定向 + 逐跳捕获 Set-Cookie + 响应脱敏', () async {
      final view = BrokerManifestView(allow: ['$base/*']);
      final jar = CookieJar();
      final out = await proxyFetch(
        '$base/redirect',
        const RequestInit(),
        FetchProxyDeps(
          view: view,
          resolver: _NoResolver(),
          jar: jar,
          transport: transport,
        ),
      );
      // 302 → 核心跟随到 /echo → 200；每跳各计一次。
      expect(out.status, 200, reason: 'B3 自跟随到 /echo');
      expect(out.requestCount, 2, reason: '/redirect + /echo 各计一次');
      expect((jsonDecode(out.body!) as Map)['method'], 'GET');
      // /echo 下发的 Set-Cookie 被 jar 捕获、脱敏后不交回 adapter。
      expect(out.headers.containsKey('set-cookie'), isFalse,
          reason: 'Set-Cookie 脱敏剥除');
      expect(jar.harvestView().map((c) => '${c.name}=${c.value}').toSet(),
          {'a=1', 'b=2'}, reason: '逐跳 Set-Cookie 进 jar origin 区');
    });
  });
}
