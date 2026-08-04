/// B6b-Dart 拼装驱动测试 —— Dart `proxyFetch` 用 fake Transport 驱动，与 TS 侧
/// `assemble.smoke.ts` 的 driver 段语义对齐（fail-closed / 重定向链 / 跨跳带 cookie /
/// Location 不外泄 / ephemeral / adapter 自设凭证头剥除）。
///
/// 驱动触 async/transport，不可纯 golden 化（计划 §2）；纯 Dart、不经 QuickJS → 无原生库依赖。
/// 与 JS 引擎桥接（ctx.fetch → 后台 isolate）属 adapter_runtime.dart 接线，另测。
///
///   运行：cd client && fvm flutter test test/broker_fetch_proxy_test.dart
library;

import 'package:elecon/core/broker/assemble.dart';
import 'package:elecon/core/broker/cookie_jar.dart';
import 'package:elecon/core/broker/fetch_proxy.dart';
import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/broker/harvest.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

void main() {
  group('B6b-Dart proxyFetch（fake transport，与 TS driver 对齐）', () {
    test('fail-closed：allow 外抛 BrokerFetchRejected，零出网', () async {
      final view = const BrokerManifestView(allow: ['https://h.edu.cn/api/*']);
      final transport = FakeTransport([]);
      await expectLater(
        proxyFetch(
          'https://evil.example.com/x',
          const RequestInit(),
          FetchProxyDeps(
            view: view,
            resolver: FakeResolver({}),
            jar: CookieJar(),
            transport: transport,
          ),
        ),
        throwsA(
          isA<BrokerFetchRejected>().having(
            (e) => e.reason,
            'reason',
            'outside_allow',
          ),
        ),
      );
      expect(transport.seen, isEmpty);
    });

    test('inject 端到端：broker cookie 出站；响应 Set-Cookie 脱敏剥除', () async {
      final view = const BrokerManifestView(
        allow: ['https://h.edu.cn/api/*'],
        credentials: {
          'session': CredentialDecl(
            scope: ['https://h.edu.cn/api/*'],
            type: 'cookie',
          ),
        },
      );
      final transport = FakeTransport([
        const TransportResponse(
          status: 200,
          headers: {'Content-Type': 'application/json', 'Set-Cookie': 'leak=1'},
          setCookie: ['leak=1'],
          body: '{}',
        ),
      ]);
      final out = await proxyFetch(
        'https://h.edu.cn/api/grades',
        const RequestInit(),
        FetchProxyDeps(
          view: view,
          resolver: FakeResolver({
            'session': const ResolvedCredential(
              via: 'cookie',
              value: 'JSESSIONID=S1',
            ),
          }),
          jar: CookieJar(),
          transport: transport,
        ),
      );
      expect(transport.seen[0].headers['Cookie'], 'JSESSIONID=S1');
      expect(out.headers.containsKey('Set-Cookie'), isFalse);
      expect(out.status, 200);
      expect(out.requestCount, 1);
    });

    test('query credential 覆盖伪值并只写入 URL', () async {
      const credentialValue = 'opaque+student/id';
      const view = BrokerManifestView(
        allow: ['https://card.h.edu.cn/*'],
        credentials: {
          'session': CredentialDecl(
            scope: ['https://card.h.edu.cn/*'],
            type: 'query',
            queryParam: 'openid',
          ),
        },
      );
      final transport = FakeTransport([
        const TransportResponse(status: 200, body: '{}'),
      ]);
      await proxyFetch(
        'https://card.h.edu.cn/account?keep=1&openid=attacker&openid=duplicate#fragment',
        const RequestInit(
          headers: {'Cookie': 'attacker=1', 'Authorization': 'Bearer attacker'},
        ),
        FetchProxyDeps(
          view: view,
          resolver: FakeResolver({
            'session': const ResolvedCredential(
              via: 'query',
              value: credentialValue,
            ),
          }),
          jar: CookieJar(),
          transport: transport,
        ),
      );
      final sent = transport.seen.single;
      expect(
        sent.url,
        'https://card.h.edu.cn/account?keep=1&openid=opaque%2Bstudent%2Fid#fragment',
      );
      expect(sent.logUrl, 'https://card.h.edu.cn/account?keep=1#fragment');
      expect(sent.headers.containsKey('Cookie'), isFalse);
      expect(sent.headers.containsKey('Authorization'), isFalse);
    });

    test('命名 header 从 policy 经 resolver 注入 transport，伪值不存活', () async {
      const view = BrokerManifestView(
        allow: ['https://gxkt.example.edu/*'],
        credentials: {
          'session': CredentialDecl(
            scope: ['https://gxkt.example.edu/*'],
            type: 'header',
            headerName: 'x-access-token',
          ),
        },
      );
      final transport = FakeTransport([
        const TransportResponse(
          status: 200,
          headers: {'x-access-token': 'upstream-echo'},
          body: '{}',
        ),
      ]);
      final out = await proxyFetch(
        'https://gxkt.example.edu/api/status',
        const RequestInit(
          headers: {
            'x-access-token': 'adapter-forged',
            'Authorization': 'adapter-forged',
          },
        ),
        FetchProxyDeps(
          view: view,
          resolver: FakeResolver({
            'session': const ResolvedCredential(
              via: 'header',
              value: 'opaque-fixture-token',
            ),
          }),
          jar: CookieJar(),
          transport: transport,
        ),
      );
      final sent = transport.seen.single;
      expect(sent.headers['x-access-token'], 'opaque-fixture-token');
      expect(sent.headers.containsKey('Authorization'), isFalse);
      expect(out.headers.containsKey('x-access-token'), isFalse);
    });

    test('重定向链：逐跳捕获 Set-Cookie；跨跳携带；中间 Location 不外泄；requestCount=2', () async {
      final view = const BrokerManifestView(allow: ['https://h.edu.cn/*']);
      final transport = FakeTransport([
        const TransportResponse(
          status: 302,
          location: 'https://h.edu.cn/step2',
          setCookie: ['hop1=a'],
        ),
        const TransportResponse(
          status: 200,
          headers: {
            'Content-Type': 'text/html',
            'Location': 'https://h.edu.cn/leak?t=x',
          },
          setCookie: ['hop2=b'],
          body: 'ok',
        ),
      ]);
      final out = await proxyFetch(
        'https://h.edu.cn/step1',
        const RequestInit(),
        FetchProxyDeps(
          view: view,
          resolver: FakeResolver({}),
          jar: CookieJar(),
          transport: transport,
        ),
      );
      expect(out.status, 200);
      expect(out.requestCount, 2);
      expect(out.headers.containsKey('Location'), isFalse);
      expect(transport.seen[1].headers['Cookie'], 'hop1=a');
    });

    test('重定向越出 allow → stop，交付当前响应，Location 脱敏剥除', () async {
      final view = const BrokerManifestView(allow: ['https://h.edu.cn/*']);
      final transport = FakeTransport([
        const TransportResponse(
          status: 302,
          location: 'https://evil.example.com/grab?t=secret',
          headers: {'Location': 'https://evil.example.com/grab?t=secret'},
        ),
      ]);
      final out = await proxyFetch(
        'https://h.edu.cn/start',
        const RequestInit(),
        FetchProxyDeps(
          view: view,
          resolver: FakeResolver({}),
          jar: CookieJar(),
          transport: transport,
        ),
      );
      expect(out.status, 302);
      expect(out.requestCount, 1);
      expect(out.headers.containsKey('Location'), isFalse);
    });

    test('仅收割通过 allow 且确定跟随的 query credential 重定向目标', () async {
      const injectView = BrokerManifestView(
        allow: ['https://ids.h.edu.cn/*', 'https://card.h.edu.cn/*'],
      );
      const harvestView = BrokerManifestView(
        allow: ['https://ids.h.edu.cn/*', 'https://card.h.edu.cn/*'],
        credentials: {
          'card': CredentialDecl(
            scope: ['https://card.h.edu.cn/*'],
            type: 'query',
            queryParam: 'openid',
          ),
        },
      );
      final entries = <({String ref, String value})>[];
      final transport = FakeTransport([
        const TransportResponse(
          status: 302,
          location: 'https://card.h.edu.cn/home?openid=opaque',
        ),
        const TransportResponse(status: 200, body: 'ok'),
      ]);
      await proxyFetch(
        'https://ids.h.edu.cn/login',
        const RequestInit(),
        FetchProxyDeps(
          view: injectView,
          resolver: FakeResolver({}),
          jar: CookieJar(),
          transport: transport,
          queryHarvest: QueryHarvestTarget(
            view: harvestView,
            put: (entry) => entries.add((ref: entry.ref, value: entry.value)),
            schoolId: 'school',
            now: () => 1,
          ),
        ),
      );
      expect(entries, [(ref: 'card', value: 'opaque')]);
      expect(transport.seen[1].url, contains('openid=opaque'));
      expect(transport.seen[1].logUrl, 'https://card.h.edu.cn/home');
    });

    test('passthrough：ephemeral cookie 写入后在出站携带（XJT body-token 缺口）', () async {
      final view = const BrokerManifestView(
        allow: ['https://dean.xjtu.edu.cn/*'],
      );
      final jar = CookieJar();
      final warnings = <String>[];
      final ok = jar.writeEphemeral(
        const EphemeralWriteInput(
          name: 'client_id',
          value: 'abc',
          domain: 'dean.xjtu.edu.cn',
        ),
        view,
        warnings.add,
      );
      expect(ok && warnings.isEmpty, isTrue);
      final transport = FakeTransport([
        const TransportResponse(status: 200, body: '[]'),
      ]);
      await proxyFetch(
        'https://dean.xjtu.edu.cn/list',
        const RequestInit(),
        FetchProxyDeps(
          view: view,
          resolver: FakeResolver({}),
          jar: jar,
          transport: transport,
        ),
      );
      expect(transport.seen[0].headers['Cookie'], 'client_id=abc');
    });

    test('adapter 自设 Cookie/Authorization 出站被剥除（纵深防御）', () async {
      final view = const BrokerManifestView(allow: ['https://h.edu.cn/*']);
      final transport = FakeTransport([const TransportResponse(status: 200)]);
      await proxyFetch(
        'https://h.edu.cn/x',
        const RequestInit(
          headers: {
            'Cookie': 'forged=1',
            'Authorization': 'Bearer forged',
            'Accept': '*/*',
          },
        ),
        FetchProxyDeps(
          view: view,
          resolver: FakeResolver({}),
          jar: CookieJar(),
          transport: transport,
        ),
      );
      final sent = transport.seen[0].headers;
      expect(sent.containsKey('Cookie'), isFalse);
      expect(sent.containsKey('Authorization'), isFalse);
      expect(sent['Accept'], '*/*');
    });
  });
}
