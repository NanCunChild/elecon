/// B2 头净化双跑（客户端半边）—— Dart sanitize{Request,Response}Headers 对
/// `contract/golden/broker/header-sanitize.json` 的产出必须等于每例 `expected`。
///
/// 两端一致闸门（ADR-001 §8）：TS smoke == expected ∧ Dart test == expected ⟹ 零漂移。
/// B2 是纯逻辑、不经 QuickJS → 无原生库依赖、不限 Linux。
///
///   运行：cd client && fvm flutter test test/broker_header_sanitize_test.dart
library;

import 'package:elecon/core/broker/header_sanitize.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

void main() {
  final cases = readGoldenCases('header-sanitize.json');

  group('B2 header-sanitize（Dart，与 TS 双跑同一 golden）', () {
    test('golden 非空', () => expect(cases, isNotEmpty));

    for (final c in cases) {
      test('${c['name']} (${c['direction']})', () {
        final input = headersFromJson(c['input']);
        final expected = headersFromJson(c['expected']);
        final actual = c['direction'] == 'request'
            ? sanitizeRequestHeaders(input)
            : sanitizeResponseHeaders(input);
        expect(actual, equals(expected));
      });
    }
  });
}
