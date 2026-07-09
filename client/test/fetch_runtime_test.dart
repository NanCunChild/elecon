/// fetch 模式运行时集成测试（Gate A · B6b-Dart）—— 镜像服务端 sandbox.fetch.smoke.ts。
///
/// adapter（async handler）→ ctx.fetch（host-fn 通道）→ proxyFetch（主 isolate）→ FakeTransport
///   ① inject 出站 + 响应脱敏交回 adapter + 执行结束 B5 收割
///   ② 多步握手 + setEphemeralCookie 跨步携带（XJT body-token 缺口）
///   ③ fail-closed：allow 外 ctx.fetch 被拒、adapter 可 catch、零出网
///   ④ 限额：单次 ≤N 请求超限 → fetchLimit、fail 不收割
///
/// 运行时触 QuickJS 引擎、不可纯 golden 化（计划 §2），用 fake transport 驱动集成。
/// **凭证只在主 isolate 闭包侧**（FakeResolver/FakeTransport 都在主 isolate），worker/JS 仅见脱敏结果。
///
///   运行：cd client && fvm flutter test test/fetch_runtime_test.dart
///
/// 🔒 红线 #1 凭证注入 + 出网承重路径：与被测代码一并须人工 + 安全清单复核。
library;

import 'package:elecon/core/adapter_runtime.dart';
import 'package:elecon/core/broker/fetch_proxy.dart';
import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/broker/ports.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

const _now = 1700000000000;

void main() {
  group('B6b-Dart fetch 运行时（host-fn 通道 + fake transport）', () {
    test('inject 出站 + 响应脱敏 + 执行结束 B5 收割', () async {
      final view = const BrokerManifestView(
        allow: ['https://h.edu.cn/api/*'],
        credentials: {
          'session':
              CredentialDecl(scope: ['https://h.edu.cn/api/*'], type: 'cookie'),
        },
      );
      final transport = FakeTransport([
        const TransportResponse(
          status: 200,
          headers: {'Content-Type': 'application/json', 'Set-Cookie': 'JSESSIONID=ROT'},
          setCookie: ['JSESSIONID=ROT'],
          body: '[{"id":1,"t":"hi"}]',
        ),
      ]);
      final store = CredentialStore(now: () => _now);
      const source = '''
        export const capabilities = {
          'notice.list': async (ctx) => {
            const res = await ctx.fetch('https://h.edu.cn/api/list');
            return { items: await res.json(), gotHeaders: res.headers };
          }
        };''';

      final data = await runFetchAdapter(
        source: source,
        capability: 'notice.list',
        view: view,
        resolver: FakeResolver({
          'session': const ResolvedCredential(via: 'cookie', value: 'JSESSIONID=S1'),
        }),
        transport: transport,
        harvest: HarvestTarget(put: store.put, schoolId: 'xidian'),
        nowMs: _now,
      ) as Map;

      expect(data['items'], [
        {'id': 1, 't': 'hi'}
      ]);
      expect(transport.seen[0].headers['Cookie'], 'JSESSIONID=S1',
          reason: 'broker 注入 cookie 应出站');
      expect((data['gotHeaders'] as Map).containsKey('Set-Cookie'), isFalse,
          reason: 'Set-Cookie 不得回交 adapter');
      final harvested = await store.get('session');
      expect(harvested?.value, 'JSESSIONID=ROT', reason: '声明 ref 应被收割入库');
    });

    test('多步握手 + setEphemeralCookie 跨步携带（XJT body-token 缺口）', () async {
      final view = const BrokerManifestView(allow: ['https://dean.xjtu.edu.cn/*']);
      final transport = FakeTransport([
        const TransportResponse(status: 200, body: '{"client_id":"XYZ"}'),
        const TransportResponse(status: 200, body: '[1,2,3]'),
      ]);
      const source = '''
        export const capabilities = {
          'notice.list': async (ctx) => {
            const a = await ctx.fetch('https://dean.xjtu.edu.cn/challenge');
            const cid = (await a.json()).client_id;
            ctx.setEphemeralCookie('client_id', cid, { domain: 'dean.xjtu.edu.cn' });
            const b = await ctx.fetch('https://dean.xjtu.edu.cn/list');
            return { rows: await b.json() };
          }
        };''';

      final data = await runFetchAdapter(
        source: source,
        capability: 'notice.list',
        view: view,
        resolver: FakeResolver({}),
        transport: transport,
        nowMs: _now,
      ) as Map;

      expect(data['rows'], [1, 2, 3]);
      expect(transport.seen[1].headers['Cookie'], 'client_id=XYZ',
          reason: 'ephemeral cookie 应在第二步携带');
    });

    test('fail-closed：allow 外被拒、adapter 可 catch、零出网', () async {
      final view = const BrokerManifestView(allow: ['https://h.edu.cn/*']);
      final transport = FakeTransport([]);
      const source = '''
        export const capabilities = {
          'notice.list': async (ctx) => {
            try { await ctx.fetch('https://evil.com/x'); return { reached: true }; }
            catch (e) { return { blocked: true }; }
          }
        };''';

      final data = await runFetchAdapter(
        source: source,
        capability: 'notice.list',
        view: view,
        resolver: FakeResolver({}),
        transport: transport,
        nowMs: _now,
      ) as Map;

      expect(data['blocked'], true);
      expect(transport.seen, isEmpty, reason: 'fail-closed 不得发任何请求');
    });

    test('请求数限额超限 → fetchLimit + fail 不收割', () async {
      final view = const BrokerManifestView(
        allow: ['https://h.edu.cn/api/*'],
        credentials: {
          'session':
              CredentialDecl(scope: ['https://h.edu.cn/api/*'], type: 'cookie'),
        },
      );
      final transport = FakeTransport([
        const TransportResponse(status: 200, setCookie: ['JSESSIONID=A'], body: '{}'),
        const TransportResponse(status: 200, setCookie: ['JSESSIONID=B'], body: '{}'),
      ]);
      final store = CredentialStore(now: () => _now);
      const source = '''
        export const capabilities = {
          'notice.list': async (ctx) => {
            await ctx.fetch('https://h.edu.cn/api/a');
            await ctx.fetch('https://h.edu.cn/api/b');
            return { ok: true };
          }
        };''';

      await expectLater(
        runFetchAdapter(
          source: source,
          capability: 'notice.list',
          view: view,
          resolver: FakeResolver({
            'session': const ResolvedCredential(via: 'cookie', value: 'S'),
          }),
          transport: transport,
          harvest: HarvestTarget(put: store.put, schoolId: 'xidian'),
          nowMs: _now,
          fetchLimits: const FetchLimits(maxRequests: 1),
        ),
        throwsA(isA<AdapterRunException>()
            .having((e) => e.reason, 'reason', AdapterFailureReason.fetchLimit)),
      );
      expect(store.list(), isEmpty, reason: '失败执行不得收割（fail 不收割）');
    });
  });
}
