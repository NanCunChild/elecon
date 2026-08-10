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

    // P1-06 双端对齐：缺省 jar 的时钟必须是**执行冻结钟**（nowMs），与 TS 侧
    // `sandbox.ts` 的 execNowMs 同构；此前用 `DateTime.now()` 活钟，只有 decideHarvest
    // 吃冻结钟，「捕获/选择/收割共用同一时刻」在客户端并不成立。
    //
    // 本例靠「Expires 落在 nowMs 之后、但落在真实墙钟之前」来判别两种钟：
    //   - 冻结钟（nowMs=2020-09）⟹ 2021-12 的 Expires 尚未到点 ⟹ cookie 存活、随第二跳发出；
    //   - 墙钟（真实 2026+）⟹ 2021-12 已过期 ⟹ captureSetCookie 按删除语义丢弃 ⟹ 第二跳无 Cookie。
    // 故这条断言在退回活钟时必然失败——不是一条永远为真的空断言。
    test('缺省 jar 用执行冻结钟（nowMs），非墙钟（P1-06 双端对齐）', () async {
      const view = BrokerManifestView(allow: ['https://h.edu/*']);
      final transport = FakeTransport([
        const TransportResponse(
          status: 200,
          setCookie: ['sid=alive; Expires=Wed, 01 Dec 2021 00:00:00 GMT'],
          body: 'first',
        ),
        const TransportResponse(status: 200, body: 'second'),
      ]);
      await fulfillDeclarativeRequests(
        requests: const [
          DeclarativeRequestDecl(
            key: 'a',
            method: 'GET',
            url: 'https://h.edu/1',
          ),
          DeclarativeRequestDecl(
            key: 'b',
            method: 'GET',
            url: 'https://h.edu/2',
          ),
        ],
        params: const {},
        view: view,
        resolver: FakeResolver({}),
        transport: transport,
        nowMs: 1600000000000, // 2020-09-13，早于 Expires
      );
      expect(transport.seen[1].headers['Cookie'], 'sid=alive');
    });
  });
}
