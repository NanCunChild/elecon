/// `direct` 档传输集成测试（Gate A · ADR-003 §2.2）—— 对本地 HttpServer 验证 DirectTransport
/// 正确映射请求/响应、暴露原始 Set-Cookie/Location、**不自动跟随重定向**（单跳）。
///
/// 纯 dart:io（host VM），不经 QuickJS。真实出网由 broker 经 Transport seam 消费（B6b 运行时）。
///
///   运行：cd client && fvm flutter test test/transport_direct_test.dart
///
/// 🔒 transport 承载注入凭证的真实请求（红线 #1 路径）：与被测代码一并须人工 + 安全清单复核。
library;

import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/broker/assemble.dart' show RequestInit;
import 'package:elecon/core/broker/cookie_jar.dart';
import 'package:elecon/core/broker/fetch_proxy.dart';
import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/broker/masker_commit.dart';
import 'package:elecon/core/broker/masker_policy.dart';
import 'package:elecon/core/broker/ports.dart';
import 'package:elecon/core/broker/response_masker.dart' show MaskerException;
import 'package:elecon/core/credential/types.dart';
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

  // 🔒 P1-04 夹具：`HttpServer` 在**写出时**就把同名头折叠成 `name: A, B` 单行，
  // 因此无法用它构造「线上真的两行同名头」。用原始 socket 手写最小 HTTP/1.1 响应，
  // 才能让 Dart 客户端解析器看到两个值（已实测：forEach 得到 2 个 values）。
  late ServerSocket rawServer;
  late String rawBase;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    transport = DirectTransport();

    rawServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    rawBase = 'http://${rawServer.address.host}:${rawServer.port}';
    rawServer.listen((sock) {
      sock.listen((_) {}, onError: (_) {});
      const body = '{"ok":true}';
      sock.write(
        'HTTP/1.1 200 OK\r\n'
        'content-type: application/json\r\n'
        'x-session-secret: TOK_A_FICTITIOUS\r\n'
        'x-session-secret: TOK_B_FICTITIOUS\r\n'
        'content-length: ${body.length}\r\n'
        'connection: close\r\n\r\n$body',
      );
      sock.flush().then((_) => sock.destroy()).catchError((_) {});
    });

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
        case '/big':
          res.statusCode = 200;
          res.headers.set('content-type', 'text/plain');
          res.write('0123456789');
          await res.close();
        case '/single-token-header':
          res.statusCode = 200;
          res.headers.set('content-type', 'application/json');
          res.headers.set('x-session-secret', 'TOK_SINGLE_FICTITIOUS');
          res.write('{"ok":true}');
          await res.close();
        case '/non-utf8-charset':
          res.statusCode = 200;
          res.headers.set('content-type', 'text/plain; charset=gbk');
          res.add(const [0x61, 0x62, 0x63]);
          await res.close();
        case '/invalid-utf8':
          res.statusCode = 200;
          res.headers.set('content-type', 'application/octet-stream');
          res.add(const [0xff, 0xfe, 0x00]);
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
    await rawServer.close();
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
      expect(resp.decodeOk, isTrue, reason: '合法 UTF-8 响应须通过 A3 明文判定');
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

    test('响应 body 超上限 → fail-closed', () async {
      final tiny = DirectTransport(maxBodyBytes: 4);
      addTearDown(tiny.close);
      await expectLater(
        tiny.fetch(TransportRequest(
          url: '$base/big',
          method: 'GET',
          headers: const {},
        )),
        throwsA(isA<TransportBodyLimitException>()),
      );
    });

    test('非 UTF-8 charset 不猜测转码，decodeOk=false', () async {
      final resp = await transport.fetch(TransportRequest(
        url: '$base/non-utf8-charset',
        method: 'GET',
        headers: const {},
      ));
      expect(
        resp.body,
        'abc',
        reason: '保留响应形状供 firewall fail-closed，不将 body 当成已确认明文',
      );
      expect(resp.decodeOk, isFalse);
    });

    test('二进制非法 UTF-8 不抛解码异常，标记 decodeOk=false', () async {
      final resp = await transport.fetch(TransportRequest(
        url: '$base/invalid-utf8',
        method: 'GET',
        headers: const {},
      ));
      expect(
        resp.body,
        isNotNull,
        reason: 'transport 响应结构保持兼容；交付由 firewall 拒绝',
      );
      expect(resp.decodeOk, isFalse);
    });

    test('P1-04：同名头出现两次 → 记录原始基数并声明可证明', () async {
      final resp = await transport.fetch(TransportRequest(
        url: '$rawBase/dup-token-header',
        method: 'GET',
        headers: const {},
      ));
      expect(
        resp.headers['x-session-secret'],
        'TOK_A_FICTITIOUS, TOK_B_FICTITIOUS',
        reason: '折叠视图仍是逗号连接（与旧行为一致）',
      );
      expect(
        resp.repeatedHeaders,
        contains('x-session-secret'),
        reason: '折叠前的原始基数须被记录',
      );
      expect(
        resp.headerCardinalityAttested,
        isTrue,
        reason: 'Dart HttpHeaders.forEach 逐名给 List<String>，客户端可证明基数',
      );
    });

    test('P1-04：同名头只出现一次 → repeatedHeaders 不含它', () async {
      final resp = await transport.fetch(TransportRequest(
        url: '$base/single-token-header',
        method: 'GET',
        headers: const {},
      ));
      expect(resp.repeatedHeaders, isNot(contains('x-session-secret')));
      expect(resp.headerCardinalityAttested, isTrue);
    });
  });

  group('proxyFetch over DirectTransport（端到端真网络）', () {
    // 🔒 P1-04 端到端（B4 要求的「真实 HTTP 同名 token header 拒绝」客户端半边）：
    // origin 真发两个 x-session-secret，header 源 Masker 规则必须 capture_ambiguous
    // fail-closed —— 绝不把折叠后的 'A, B' 当单值凭证收割，也绝不交付。
    test('两个同名 token header → Masker capture_ambiguous fail-closed，不落库', () async {
      final view = BrokerManifestView(
        allow: ['$rawBase/*'],
        credentials: const {
          'aircon-session': CredentialDecl(
            scope: ['https://actuator.invalid/*'],
            type: 'header',
            headerName: 'x-access-token',
          ),
        },
      );
      final committed = <CredentialEntry>[];
      const policyJson = '{"schemaVersion":1,"rules":[{"id":"dup-token",'
          '"match":{"capability":"notice.list","method":"GET",'
          '"urlScope":"URLSCOPE"},'
          '"capture":{"source":"header","name":"x-session-secret","exactly":1,'
          '"destination":{"kind":"credential","ref":"aircon-session"}},'
          '"project":"delete"}]}';
      final policy = parseMaskerPolicy(
        policyJson.replaceFirst('URLSCOPE', '$rawBase/*'),
      );
      await expectLater(
        proxyFetch(
          '$rawBase/dup-token-header',
          const RequestInit(),
          FetchProxyDeps(
            view: view,
            resolver: _NoResolver(),
            jar: CookieJar(),
            transport: transport,
            masker: FetchProxyMasker(
              policy: policy,
              capability: 'notice.list',
              sink: committed.add,
              context: MaskerCommitContext(schoolId: 'test', now: () => 0),
            ),
          ),
        ),
        throwsA(
          isA<MaskerException>().having((e) => e.code, 'code', 'capture_ambiguous'),
        ),
      );
      expect(committed, isEmpty, reason: '歧义时绝不落库');
    });

    test('同名头只出现一次 → 正常收割，原值只落核心 store、不交付', () async {
      final view = BrokerManifestView(
        allow: ['$base/*'],
        credentials: const {
          'aircon-session': CredentialDecl(
            scope: ['https://actuator.invalid/*'],
            type: 'header',
            headerName: 'x-access-token',
          ),
        },
      );
      final committed = <CredentialEntry>[];
      const policyJson = '{"schemaVersion":1,"rules":[{"id":"dup-token",'
          '"match":{"capability":"notice.list","method":"GET",'
          '"urlScope":"URLSCOPE"},'
          '"capture":{"source":"header","name":"x-session-secret","exactly":1,'
          '"destination":{"kind":"credential","ref":"aircon-session"}},'
          '"project":"delete"}]}';
      final policy = parseMaskerPolicy(
        policyJson.replaceFirst('URLSCOPE', '$base/*'),
      );
      final out = await proxyFetch(
        '$base/single-token-header',
        const RequestInit(),
        FetchProxyDeps(
          view: view,
          resolver: _NoResolver(),
          jar: CookieJar(),
          transport: transport,
          masker: FetchProxyMasker(
            policy: policy,
            capability: 'notice.list',
            sink: committed.add,
            context: MaskerCommitContext(schoolId: 'test', now: () => 0),
          ),
        ),
      );
      expect(
        out.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('x-session-secret')),
        reason: '命中头须在交付前删除',
      );
      expect(committed.single.value, 'TOK_SINGLE_FICTITIOUS');
      expect(committed.single.schoolId, 'test');
    });

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
