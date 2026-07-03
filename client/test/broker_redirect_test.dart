/// B3 重定向双跑（客户端半边）—— Dart `decideRedirect` 对
/// `contract/golden/broker/redirect.json` 的产出必须等于每例 `expected`，
/// 与 TS `redirect.smoke.ts` 双跑同一向量（ADR-001 §8）。
///
///   - 服务端 TS  == expected  →  server/src/runtime/broker/redirect.smoke.ts 已证
///   - 客户端 Dart == expected  →  本测试
///   ⟹ 传递地，两端 broker 重定向决策零漂移。
///
/// 纯逻辑、不经 QuickJS → 无原生库依赖、不限 Linux。
///
///   运行：cd client && fvm flutter test test/broker_redirect_test.dart
import 'package:elecon/core/broker/redirect.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

RedirectInput _inputFromJson(Map<String, dynamic> i) => RedirectInput(
      status: i['status'] as int,
      location: i['location'] as String?,
      currentUrl: i['currentUrl'] as String,
      allow: (i['allow'] as List).cast<String>(),
      hopsSoFar: i['hopsSoFar'] as int,
      maxHops: i['maxHops'] as int,
    );

class _ScriptedFetcher implements RedirectFetcher {
  _ScriptedFetcher(this.script);

  final Map<String, RedirectHop> script;

  @override
  Future<RedirectHop> fetch(String url, String method) async =>
      script[url] ?? const RedirectHop(status: 404, location: null);
}

void main() {
  final cases = readGoldenCases('redirect.json');

  group('B3 redirect 决策（Dart，与 TS 双跑同一 golden）', () {
    test('golden 非空', () => expect(cases, isNotEmpty));

    for (final c in cases) {
      test(c['name'] as String, () {
        final decision = decideRedirect(_inputFromJson(c['input'] as Map<String, dynamic>));
        expect(decision.toJson(), equals(c['expected']));
      });
    }
  });

  group('B3 followRedirects driver（Dart，与 TS smoke 同场景）', () {
    const allow = ['https://h.edu.cn/*'];

    test('链路跟随到最终 200（含一跳相对 Location）', () async {
      final chain = _ScriptedFetcher({
        'https://h.edu.cn/a': const RedirectHop(status: 302, location: 'https://h.edu.cn/b'),
        'https://h.edu.cn/b': const RedirectHop(status: 302, location: '/c'),
        'https://h.edu.cn/c': const RedirectHop(status: 200, location: null),
      });
      final out = await followRedirects('https://h.edu.cn/a', chain, allow: allow);
      expect(out.finalUrl, 'https://h.edu.cn/c');
      expect(out.status, 200);
      expect(out.hops, 2);
      expect(out.stopReason, isNull);
    });

    test('自循环 → 触顶 maxHops 停止', () async {
      final loop = _ScriptedFetcher({
        'https://h.edu.cn/loop':
            const RedirectHop(status: 302, location: 'https://h.edu.cn/loop'),
      });
      final out = await followRedirects('https://h.edu.cn/loop', loop, allow: allow, maxHops: 5);
      expect(out.stopReason, 'max_hops');
      expect(out.hops, 5);
    });

    test('越 allow → 停止于 0 跳，交付当前 3xx（Location 不外泄）', () async {
      final evil = _ScriptedFetcher({
        'https://h.edu.cn/a':
            const RedirectHop(status: 302, location: 'https://evil.example.com/x'),
      });
      final out = await followRedirects('https://h.edu.cn/a', evil, allow: allow);
      expect(out.finalUrl, 'https://h.edu.cn/a');
      expect(out.status, 302);
      expect(out.hops, 0);
      expect(out.stopReason, 'outside_allow');
    });
  });
}
