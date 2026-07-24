/// ADR-023 声明式数据流**接线**端到端（客户端）—— [fulfillDeclarativeRequests] 带
/// binds/computes/injects 的编排：拓扑代取 → 脱敏前抽取 → compute → 注入 → 回显剥离。
///
/// 用 FakeTransport 驱动，不经真实网络。重点是**接线正确 + 安全 fail-closed**：
/// header 源脱敏前可读、url/header 注入落到出站请求、注入值回显被剥、缺失/成环 fail-closed。
/// 数据流**语义**（逐 op / 抽取）的两端一致由 broker_dataflow_test.dart（golden 双跑）保证。
///
///   运行：cd client && fvm flutter test test/declarative_dataflow_host_test.dart
///
/// 🔒 覆盖红线 #1 数据流路径；与被测代码一并须人工 + 安全清单复核（不得 AI 独自闭环）。
library;

import 'package:elecon/core/broker/fetch_proxy.dart' show TransportResponse;
import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/broker/ports.dart';
import 'package:elecon/core/declarative_host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

void main() {
  group('数据流接线：challenge → 抽取 → 注入 → 代取 → 回显剥离', () {
    test('regex 抽 client_id → url 注入下一跳（驱动场景）', () async {
      final view = const BrokerManifestView(
        allow: ['https://h.edu/challenge*', 'https://h.edu/api/*'],
        credentials: {
          'session': CredentialDecl(
            scope: ['https://h.edu/api/*'],
            type: 'cookie',
          ),
        },
      );
      final transport = FakeTransport([
        // chal（passthrough，无凭证）：body 藏 client_id
        const TransportResponse(
          status: 200,
          body: "window.cfg={client_id:'cust42'};",
        ),
        // raw（带 session cookie）：应带上注入的 ?cid=cust42
        const TransportResponse(status: 200, body: '{"grades":[]}'),
      ]);
      final out = await fulfillDeclarativeRequests(
        requests: const [
          DeclarativeRequestDecl(
            key: 'chal',
            method: 'GET',
            url: 'https://h.edu/challenge',
          ),
          DeclarativeRequestDecl(
            key: 'raw',
            method: 'GET',
            url: 'https://h.edu/api/grades',
            credential: 'session',
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
        binds: const [
          BindDecl(
            varName: 'cid',
            from: 'chal',
            source: 'regex',
            extract: {'pattern': r"client_id:'(\w+)'", 'group': 1},
          ),
        ],
        injects: const [
          InjectDecl(varName: 'cid', into: 'raw', at: 'url', name: 'cid'),
        ],
      );

      // 拓扑序：chal 先、raw 后。
      expect(transport.seen[0].url, 'https://h.edu/challenge');
      expect(transport.seen[1].url, 'https://h.edu/api/grades?cid=cust42');
      // raw 带上 session 凭证（注入不干扰凭证注入）。
      expect(transport.seen[1].headers['Cookie'], 'JSESSIONID=S1');
      expect(out['raw']?['body'], '{"grades":[]}');
    });

    test('header 源脱敏前可读 + header 注入落到出站', () async {
      final view = const BrokerManifestView(allow: ['https://h.edu/*']);
      final transport = FakeTransport([
        // A：X-Token 在响应头（不在响应 allowlist，脱敏会丢——须脱敏前抽取）
        const TransportResponse(
          status: 200,
          headers: {'X-Token': 'tok-abc123', 'Content-Type': 'text/plain'},
          body: 'ok',
        ),
        const TransportResponse(status: 200, body: 'done'),
      ]);
      final out = await fulfillDeclarativeRequests(
        requests: const [
          DeclarativeRequestDecl(
            key: 'a',
            method: 'GET',
            url: 'https://h.edu/a',
          ),
          DeclarativeRequestDecl(
            key: 'b',
            method: 'GET',
            url: 'https://h.edu/b',
          ),
        ],
        params: const {},
        view: view,
        resolver: FakeResolver({}),
        transport: transport,
        binds: const [
          BindDecl(
            varName: 'tk',
            from: 'a',
            source: 'header',
            extract: {'name': 'X-Token'},
          ),
        ],
        injects: const [
          InjectDecl(varName: 'tk', into: 'b', at: 'header', name: 'X-Relay'),
        ],
      );
      // 注入头落到 b 的出站请求。
      expect(transport.seen[1].headers['X-Relay'], 'tok-abc123');
      // 交回 adapter 的 a 响应已脱敏：X-Token 不在响应里。
      expect((out['a']?['headers'] as Map).containsKey('X-Token'), isFalse);
    });

    test('注入值回显被剥离（堵回读）', () async {
      final view = const BrokerManifestView(allow: ['https://h.edu/*']);
      final transport = FakeTransport([
        const TransportResponse(status: 200, body: 'seed=longsecret9911'),
        // b 的响应回显了注入值 → 交回 adapter 前须被掩码
        const TransportResponse(
          status: 200,
          body: 'you sent longsecret9911 ok',
        ),
      ]);
      final out = await fulfillDeclarativeRequests(
        requests: const [
          DeclarativeRequestDecl(
            key: 'a',
            method: 'GET',
            url: 'https://h.edu/a',
          ),
          DeclarativeRequestDecl(
            key: 'b',
            method: 'GET',
            url: 'https://h.edu/b',
          ),
        ],
        params: const {},
        view: view,
        resolver: FakeResolver({}),
        transport: transport,
        binds: const [
          BindDecl(
            varName: 's',
            from: 'a',
            source: 'regex',
            extract: {'pattern': r'seed=(\w+)', 'group': 1},
          ),
        ],
        injects: const [
          InjectDecl(varName: 's', into: 'b', at: 'url', name: 'echo'),
        ],
      );
      expect((out['b']?['body'] as String).contains('longsecret9911'), isFalse);
      expect((out['b']?['body'] as String).contains('[stripped]'), isTrue);
    });
  });

  group('安全负例：fail-closed', () {
    test('bind 抽取失败（无匹配）→ DeclarativeHostException，不发下游', () async {
      final view = const BrokerManifestView(allow: ['https://h.edu/*']);
      final transport = FakeTransport([
        const TransportResponse(status: 200, body: 'no token here'),
      ]);
      await expectLater(
        fulfillDeclarativeRequests(
          requests: const [
            DeclarativeRequestDecl(
              key: 'a',
              method: 'GET',
              url: 'https://h.edu/a',
            ),
            DeclarativeRequestDecl(
              key: 'b',
              method: 'GET',
              url: 'https://h.edu/b',
            ),
          ],
          params: const {},
          view: view,
          resolver: FakeResolver({}),
          transport: transport,
          binds: const [
            BindDecl(
              varName: 't',
              from: 'a',
              source: 'regex',
              extract: {'pattern': r'token=(\w+)', 'group': 1},
            ),
          ],
          injects: const [
            InjectDecl(varName: 't', into: 'b', at: 'url', name: 'tk'),
          ],
        ),
        throwsA(isA<DeclarativeHostException>()),
      );
      // a 发了、b 因抽取失败没发（fail-closed，不带缺失参数发未认证请求）。
      expect(transport.seen.length, 1);
      expect(transport.seen[0].url, 'https://h.edu/a');
    });

    test('注入 header 命中凭证头护栏 → 拒绝（纵深防御 D16）', () async {
      final view = const BrokerManifestView(allow: ['https://h.edu/*']);
      final transport = FakeTransport([
        const TransportResponse(
          status: 200,
          headers: {'X-V': 'v12345678'},
          body: 'ok',
        ),
        const TransportResponse(status: 200, body: 'done'),
      ]);
      await expectLater(
        fulfillDeclarativeRequests(
          requests: const [
            DeclarativeRequestDecl(
              key: 'a',
              method: 'GET',
              url: 'https://h.edu/a',
            ),
            DeclarativeRequestDecl(
              key: 'b',
              method: 'GET',
              url: 'https://h.edu/b',
            ),
          ],
          params: const {},
          view: view,
          resolver: FakeResolver({}),
          transport: transport,
          binds: const [
            BindDecl(
              varName: 'v',
              from: 'a',
              source: 'header',
              extract: {'name': 'X-V'},
            ),
          ],
          // 运行期护栏：即便越过校验器，broker 也拒绝把句柄注入 Authorization。
          injects: const [
            InjectDecl(
              varName: 'v',
              into: 'b',
              at: 'header',
              name: 'Authorization',
            ),
          ],
        ),
        throwsA(isA<DeclarativeHostException>()),
      );
    });

    test('无数据流 → 退化为平铺代取（等价，回归保护）', () async {
      final view = const BrokerManifestView(allow: ['https://h.edu/*']);
      final transport = FakeTransport([
        const TransportResponse(status: 200, body: 'p1'),
        const TransportResponse(status: 200, body: 'p2'),
      ]);
      final out = await fulfillDeclarativeRequests(
        requests: const [
          DeclarativeRequestDecl(
            key: 'x',
            method: 'GET',
            url: 'https://h.edu/x',
          ),
          DeclarativeRequestDecl(
            key: 'y',
            method: 'GET',
            url: 'https://h.edu/y',
          ),
        ],
        params: const {},
        view: view,
        resolver: FakeResolver({}),
        transport: transport,
      );
      expect(out['x']?['body'], 'p1');
      expect(out['y']?['body'], 'p2');
      expect(transport.seen.map((r) => r.url).toList(), [
        'https://h.edu/x',
        'https://h.edu/y',
      ]);
    });
  });
}
