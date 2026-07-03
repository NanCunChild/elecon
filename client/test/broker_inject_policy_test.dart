/// B1 注入策略双跑（客户端半边）—— Dart `decideInjection` 对
/// `contract/golden/broker/inject-policy.json` 的产出必须等于每例 `expected`。
///
/// 这是 broker 决策的两端一致闸门（同 ADR-001 §8 parser 双跑的精神）：
///   - 服务端 TS  == expected  →  server/src/runtime/broker/inject-policy.smoke.ts 已证
///   - 客户端 Dart == expected  →  本测试
///   ⟹ 传递地，两端 broker 注入决策零漂移。
///
/// 与 dual_run_test 不同：B1 是**纯逻辑**、不经 QuickJS，故**无原生库依赖、不限 Linux**。
///
///   运行：cd client && fvm flutter test test/broker_inject_policy_test.dart
import 'package:elecon/core/broker/inject_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

void main() {
  final cases = readGoldenCases('inject-policy.json');

  group('B1 inject-policy（Dart，与 TS 双跑同一 golden）', () {
    test('golden 非空', () {
      expect(cases, isNotEmpty);
    });

    for (final c in cases) {
      test(c['name'] as String, () {
        final view = viewFromJson(c['view'] as Map<String, dynamic>);
        final decision = decideInjection(c['url'] as String, view);
        expect(decision.toJson(), equals(c['expected']));
      });
    }
  });
}
