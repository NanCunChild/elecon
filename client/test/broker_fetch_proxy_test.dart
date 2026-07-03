/// B6b-Dart 拼装驱动测试 —— Dart `proxyFetch` 用 fake Transport 驱动，与 TS 侧
/// `assemble.smoke.ts` 的 driver 段语义对齐（fail-closed / 重定向链 / 跨跳带 cookie /
/// Location 不外泄 / ephemeral / adapter 自设凭证头剥除）。
///
/// 驱动触 async/transport，不可纯 golden 化（计划 §2）；纯 Dart、不经 QuickJS → 无原生库依赖。
/// 与 JS 引擎桥接（ctx.fetch → 后台 isolate）属 adapter_runtime.dart 接线，另测。
///
///   运行：cd client && fvm flutter test test/broker_fetch_proxy_test.dart
import 'package:elecon/core/broker/assemble.dart';
import 'package:elecon/core/broker/cookie_jar.dart';
import 'package:elecon/core/broker/fetch_proxy.dart';
import 'package:elecon/core/broker/inject_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

void main() {
  group('B6b-Dart proxyFetch（fake transport，与 TS driver 对齐）', () {
    test('fail-closed：allow 外抛 BrokerFetchRejected，零出网', () async {
      final view = const BrokerManifestView(allow: ['https://h.edu.cn/api/*']);
      final transport = FakeTransport([]);
      await expectLater(
        proxyFetch('https://evil.example.com/x', const RequestInit(), FetchProxyDeps(
          view: view,
          resolver: FakeResolver({}),
          jar: CookieJar(),
          transport: transport,
        )),
        throwsA(isA<BrokerFetchRejected>()
            .having((e) => e.reason, 'reason', 'outside_allow')),
      );
      expect(transport.seen, isEmpty);
    });

    test('inject 端到端：broker cookie 出站；响应 Set-Cookie 脱敏剥除', () async {
      final view = const BrokerManifestView(
        allow: ['https://h.edu.cn/api/*'],
        credentials: {
          'session': CredentialDecl(scope: ['https://h.edu.cn/api/*'], type: 'cookie'),
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
      final out = await proxyFetch('https://h.edu.cn/api/grades', const RequestInit(), FetchProxyDeps(
        view: view,
        resolver: FakeResolver({'session': const ResolvedCredential(via: 'cookie', value: 'JSESSIONID=S1')}),
        jar: CookieJar(),
        transport: transport,
      ));
      expect(transport.seen[0].headers['Cookie'], 'JSESSIONID=S1');
      expect(out.headers.containsKey('Set-Cookie'), isFalse);
      expect(out.status, 200);
      expect(out.requestCount, 1);
    });

    test('重定向链：逐跳捕获 Set-Cookie；跨跳携带；中间 Location 不外泄；requestCount=2', () async {
      final view = const BrokerManifestView(allow: ['https://h.edu.cn/*']);
      final transport = FakeTransport([
        const TransportResponse(status: 302, location: 'https://h.edu.cn/step2', setCookie: ['hop1=a']),
        const TransportResponse(
          status: 200,
          headers: {'Content-Type': 'text/html', 'Location': 'https://h.edu.cn/leak?t=x'},
          setCookie: ['hop2=b'],
          body: 'ok',
        ),
      ]);
      final out = await proxyFetch('https://h.edu.cn/step1', const RequestInit(), FetchProxyDeps(
        view: view,
        resolver: FakeResolver({}),
        jar: CookieJar(),
        transport: transport,
      ));
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
      final out = await proxyFetch('https://h.edu.cn/start', const RequestInit(), FetchProxyDeps(
        view: view,
        resolver: FakeResolver({}),
        jar: CookieJar(),
        transport: transport,
      ));
      expect(out.status, 302);
      expect(out.requestCount, 1);
      expect(out.headers.containsKey('Location'), isFalse);
    });

    test('passthrough：ephemeral cookie 写入后在出站携带（XJT body-token 缺口）', () async {
      final view = const BrokerManifestView(allow: ['https://dean.xjtu.edu.cn/*']);
      final jar = CookieJar();
      final warnings = <String>[];
      final ok = jar.writeEphemeral(
        const EphemeralWriteInput(name: 'client_id', value: 'abc', domain: 'dean.xjtu.edu.cn'),
        view,
        warnings.add,
      );
      expect(ok && warnings.isEmpty, isTrue);
      final transport = FakeTransport([const TransportResponse(status: 200, body: '[]')]);
      await proxyFetch('https://dean.xjtu.edu.cn/list', const RequestInit(), FetchProxyDeps(
        view: view,
        resolver: FakeResolver({}),
        jar: jar,
        transport: transport,
      ));
      expect(transport.seen[0].headers['Cookie'], 'client_id=abc');
    });

    test('adapter 自设 Cookie/Authorization 出站被剥除（纵深防御）', () async {
      final view = const BrokerManifestView(allow: ['https://h.edu.cn/*']);
      final transport = FakeTransport([const TransportResponse(status: 200)]);
      await proxyFetch(
        'https://h.edu.cn/x',
        const RequestInit(headers: {'Cookie': 'forged=1', 'Authorization': 'Bearer forged', 'Accept': '*/*'}),
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
