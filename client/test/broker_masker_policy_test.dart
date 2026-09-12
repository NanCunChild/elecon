/// Masker 策略装配双跑（客户端半边，ADR-026 §2.7.1 落地）—— Dart 的 `masker.json` 严格解析
/// 与 firewall ② 步规则选取必须与 `contract/golden/broker/masker-policy.json` 每例一致。
///
/// 两端一致闸门（ADR-001 §8）：
///   - 服务端 TS  == golden  →  server/src/runtime/broker/masker-policy.smoke.ts 已证
///   - 客户端 Dart == golden  →  本测试
///   ⟹ 传递地，两端「哪些规则对这条响应生效」零漂移——这是 ADR-002 §3 风险 5 的重点面：
///      选规则漂移 = 一端收割、另一端不收割 = 凭证要么泄漏要么丢失。
///
/// 纯逻辑、不经 QuickJS，故无原生库依赖、不限平台。
///
///   运行：cd client && fvm flutter test test/broker_masker_policy_test.dart
///
/// 🔒 覆盖红线 #1 凭证路径；与被测代码一并须人工 + 安全清单复核（不得 AI 独自闭环）。
library;

import 'dart:convert';

import 'package:elecon/core/broker/masker_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

void main() {
  final golden = readGolden('masker-policy.json');
  final errorCodes = (golden['parseErrorCodes'] as List).cast<String>();

  group('parseMaskerPolicy（严格解析，形状偏差一律 fail-closed）', () {
    for (final raw in (golden['parse'] as List).cast<Map<String, dynamic>>()) {
      final name = raw['name'] as String;
      test(name, () {
        final text = raw['text'] as String;
        if (raw['ok'] == true) {
          final policy = parseMaskerPolicy(text);
          expect(policy.rules.length, raw['ruleCount'], reason: '$name：规则条数');
        } else {
          final expectedCode = raw['error'] as String;
          expect(
            errorCodes.contains(expectedCode),
            isTrue,
            reason: '$name：错误码须在 golden 词表内',
          );
          try {
            parseMaskerPolicy(text);
            fail('$name：期望 fail-closed（$expectedCode），但未抛错');
          } on MaskerPolicyException catch (e) {
            expect(e.code, expectedCode, reason: '$name：错误码不符');
          }
        }
      });
    }
  });

  group('selectMaskerRules（firewall ② 步，AND 语义 + 保持策略序）', () {
    // 先经 parse 往返，保证 golden 策略本身合法（与 TS smoke 同一口径）。
    final policy = parseMaskerPolicy(jsonEncode(golden['selectPolicy']));

    for (final raw in (golden['select'] as List).cast<Map<String, dynamic>>()) {
      final name = raw['name'] as String;
      test(name, () {
        final ctxRaw = (raw['context'] as Map).cast<String, dynamic>();
        final ids = selectMaskerRules(
          policy,
          MaskerSelectContext(
            capability: ctxRaw['capability'] as String,
            method: ctxRaw['method'] as String,
            finalUrl: ctxRaw['finalUrl'] as String,
            requestKey: ctxRaw['requestKey'] as String?,
          ),
        ).map((r) => r.id).toList();
        expect(
          ids,
          (raw['expectedRuleIds'] as List).cast<String>(),
          reason: '$name：选出的规则 id 序列不符',
        );
      });
    }

    test('handle 目标不进引擎（policy 里有、选出的规则集里没有）', () {
      expect(
        policy.rules.any((r) => r.handleRef != null),
        isTrue,
        reason: 'golden 策略应含至少一条 handle 规则以覆盖本断言',
      );
      final picked = selectMaskerRules(
        policy,
        const MaskerSelectContext(
          capability: 'grades.list',
          method: 'GET',
          finalUrl: 'https://api.example.edu/page',
          requestKey: 'page',
        ),
      );
      expect(picked, isEmpty);
    });
  });
}
