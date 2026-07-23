/// A2 核心代取 declarative 请求 —— [fulfillDeclarativeRequests] / [expandRequestUrl]。
///
/// 用 FakeTransport 驱动，不经真实网络；验证 allow 闸门、脱敏、URL 模板展开。
library;

import 'package:elecon/core/broker/cookie_jar.dart';
import 'package:elecon/core/broker/fetch_proxy.dart';
import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/broker/ports.dart';
import 'package:elecon/core/declarative_host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

void main() {
  group('expandRequestUrl', () {
    test('替换 {param} 并 encode', () {
      expect(
        expandRequestUrl('https://x.edu/a?term={term}', {'term': '2024 春'}),
        'https://x.edu/a?term=2024%20%E6%98%A5',
      );
    });

    test('缺参抛 FormatException', () {
      expect(
        () => expandRequestUrl('https://x.edu/{id}', {}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('fulfillDeclarativeRequests', () {
    test('公开 GET：body 交回且 Set-Cookie 不进 responses', () async {
      final view = const BrokerManifestView(
        allow: ['https://jwc.example.edu/*'],
      );
      final transport = FakeTransport([
        const TransportResponse(
          status: 200,
          headers: {
            'Content-Type': 'text/html',
            'Set-Cookie': 'secret=1',
          },
          setCookie: ['secret=1'],
          body: '<html>ok</html>',
        ),
      ]);
      final out = await fulfillDeclarativeRequests(
        requests: const [
          DeclarativeRequestDecl(
            key: 'page',
            method: 'GET',
            url: 'https://jwc.example.edu/index.htm',
          ),
        ],
        params: const {},
        view: view,
        resolver: FakeResolver({}),
        transport: transport,
      );
      expect(out['page']?['status'], 200);
      expect(out['page']?['body'], '<html>ok</html>');
      expect(
        (out['page']?['headers'] as Map).containsKey('Set-Cookie'),
        isFalse,
      );
      expect(transport.seen.single.url, 'https://jwc.example.edu/index.htm');
      expect(transport.seen.single.method, 'GET');
    });

    test('allow 外 → DeclarativeHostException，零出网', () async {
      final transport = FakeTransport([]);
      await expectLater(
        fulfillDeclarativeRequests(
          requests: const [
            DeclarativeRequestDecl(
              key: 'page',
              method: 'GET',
              url: 'https://evil.example.com/x',
            ),
          ],
          params: const {},
          view: const BrokerManifestView(allow: ['https://ok.edu/*']),
          resolver: FakeResolver({}),
          transport: transport,
        ),
        throwsA(isA<DeclarativeHostException>()),
      );
      expect(transport.seen, isEmpty);
    });

    test('credential 声明但 scope 未命中 → 拒绝', () async {
      final transport = FakeTransport([]);
      await expectLater(
        fulfillDeclarativeRequests(
          requests: const [
            DeclarativeRequestDecl(
              key: 'raw',
              method: 'GET',
              url: 'https://h.edu/api/x',
              credential: 'session',
            ),
          ],
          params: const {},
          view: const BrokerManifestView(
            allow: ['https://h.edu/*'],
            // credentials 空 → passthrough，与声明 credential 冲突
          ),
          resolver: FakeResolver({}),
          transport: transport,
        ),
        throwsA(isA<DeclarativeHostException>()),
      );
      expect(transport.seen, isEmpty);
    });

    test('未声明 credential 但 URL 落在凭证 scope → 拒绝，零出网', () async {
      // 双向权威：请求没写 credential，却因 URL 命中 session 的 scope 会被静默注入 →
      // fail-closed，绝不放行（否则 manifest 的 credential 字段不可审计）。
      final view = const BrokerManifestView(
        allow: ['https://h.edu/*'],
        credentials: {
          'session': CredentialDecl(
            scope: ['https://h.edu/*'],
            type: 'cookie',
          ),
        },
      );
      final transport = FakeTransport([]);
      await expectLater(
        fulfillDeclarativeRequests(
          requests: const [
            DeclarativeRequestDecl(
              key: 'raw',
              method: 'GET',
              url: 'https://h.edu/api/x',
              // 故意不写 credential —— 但 URL 落在 session scope 内
            ),
          ],
          params: const {},
          view: view,
          resolver: FakeResolver({
            'session': const ResolvedCredential(
              via: 'cookie',
              value: 'JSESSIONID=S1',
            ),
          }),
          transport: transport,
        ),
        throwsA(isA<DeclarativeHostException>()),
      );
      expect(transport.seen, isEmpty);
    });

    test('credential inject 端到端', () async {
      final view = const BrokerManifestView(
        allow: ['https://h.edu/*'],
        credentials: {
          'session': CredentialDecl(
            scope: ['https://h.edu/*'],
            type: 'cookie',
          ),
        },
      );
      final transport = FakeTransport([
        const TransportResponse(status: 200, body: '{"ok":true}'),
      ]);
      final out = await fulfillDeclarativeRequests(
        requests: const [
          DeclarativeRequestDecl(
            key: 'raw',
            method: 'GET',
            url: 'https://h.edu/api?term={term}',
            credential: 'session',
          ),
        ],
        params: const {'term': '2024'},
        view: view,
        resolver: FakeResolver({
          'session': const ResolvedCredential(
            via: 'cookie',
            value: 'JSESSIONID=S1',
          ),
        }),
        transport: transport,
        jar: CookieJar(),
      );
      expect(transport.seen.single.headers['Cookie'], 'JSESSIONID=S1');
      expect(transport.seen.single.url, 'https://h.edu/api?term=2024');
      expect(out['raw']?['body'], '{"ok":true}');
    });
  });
}
