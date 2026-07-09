/// URL 匹配原语双跑（客户端半边）—— Dart `url_match.dart` 的 urlCoveredByAllow /
/// scopeMatches / scopePrefix 对 `contract/golden/broker/url-match.json` 的产出必须
/// 等于每例 `expected`。
///
/// 这是 broker 匹配约定的三方一致闸门（同 ADR-001 §8 双跑精神）：
///   - 服务端 TS broker  == expected → server/src/runtime/broker/url-match.smoke.ts
///   - tools 校验器内联   == expected → tools/src/validator/url-match.smoke.ts（子集）
///   - 客户端 Dart       == expected → 本测试
///   ⟹ 传递地，三方 URL 匹配（注入面边界）零漂移。
///
/// 纯逻辑、不经 QuickJS，故无原生库依赖、不限 Linux。
///
///   运行：cd client && fvm flutter test test/broker_url_match_test.dart
library;

import 'package:elecon/core/broker/url_match.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

void main() {
  final golden = readGolden('url-match.json');

  final coverCases =
      (golden['urlCoveredByAllow'] as List).cast<Map<String, dynamic>>();
  final scopeCases =
      (golden['scopeMatches'] as List).cast<Map<String, dynamic>>();
  final prefixCases =
      (golden['scopePrefix'] as List).cast<Map<String, dynamic>>();

  group('url-match（Dart，与 TS broker + 校验器共享 golden）', () {
    test('golden 非空', () {
      expect(coverCases, isNotEmpty);
      expect(scopeCases, isNotEmpty);
      expect(prefixCases, isNotEmpty);
    });

    for (final c in coverCases) {
      test('urlCoveredByAllow · ${c['name']}', () {
        final allow = (c['allow'] as List).cast<String>();
        expect(urlCoveredByAllow(c['url'] as String, allow),
            equals(c['expected']));
      });
    }

    for (final c in scopeCases) {
      test('scopeMatches · ${c['name']}', () {
        expect(scopeMatches(c['url'] as String, c['pattern'] as String),
            equals(c['expected']));
      });
    }

    for (final c in prefixCases) {
      test('scopePrefix · ${c['name']}', () {
        expect(scopePrefix(c['pattern'] as String), equals(c['expected']));
      });
    }
  });
}
