/// 响应凭证收割与投影引擎双跑（客户端半边，ADR-026 §2.8 / 工程说明 §6）—— Dart 产出必须等于
/// `contract/golden/broker/response-masker.json` 每例 expected。
///
/// 两端一致闸门（ADR-001 §8）：
///   - 服务端 TS  == expected  →  server/src/runtime/broker/response-masker.smoke.ts 已证
///   - 客户端 Dart == expected  →  本测试
///   ⟹ 传递地，两端收割 / 投影语义（含 JSON 剪接逐字节）零漂移。
///
/// 纯逻辑、不经 QuickJS，故无原生库依赖、不限平台。
///
///   运行：cd client && fvm flutter test test/broker_response_masker_test.dart
///
/// 🔒 覆盖红线 #1 凭证路径；与被测代码一并须人工 + 安全清单复核（不得 AI 独自闭环）。
library;

import 'package:elecon/core/broker/response_masker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

MaskerRawResponse _resp(Map<String, dynamic> j) =>
    MaskerRawResponse.fromJson(j);

List<MaskerRule> _rules(List<dynamic> raw) =>
    raw.cast<Map<String, dynamic>>().map(MaskerRule.fromJson).toList();

/// 断言 [fn] 抛出 MaskerException 且 code 匹配；给了 expectedKey 时还校验结构化 key（B5）。
void _expectError(
  void Function() fn,
  String code,
  String label, {
  String? expectedKey,
}) {
  try {
    fn();
    fail('$label：期望 fail-closed（$code），但未抛错');
  } on MaskerException catch (e) {
    expect(e.code, code, reason: '$label：错误码不符');
    if (expectedKey != null) {
      expect(e.key, expectedKey, reason: '$label：重复键结构化 key 不符');
    }
  }
}

/// 投影响应 → golden 可比对形。
Map<String, dynamic> _projectedToJson(MaskerRawResponse r) => {
  'status': r.status,
  'headers': r.headers,
  'body': r.body,
};

void main() {
  final golden = readGolden('response-masker.json');

  test('golden 非空', () {
    expect(golden['captureJson'] as List, isNotEmpty);
  });

  group('generatedLimits（共享描述符生成超限输入）', () {
    for (final raw
        in (golden['generatedLimits'] as List).cast<Map<String, dynamic>>()) {
      test(raw['name'] as String, () {
        final kind = raw['kind'] as String;
        final unit = raw['unit'] as String? ?? '';
        final repeat = raw['repeat'] as int? ?? 0;
        final error = raw['error'] as String;
        if (kind == 'header') {
          final value = List.filled(repeat, unit).join();
          _expectError(
            () => captureHeader(
              'X-Limit',
              MaskerRawResponse(
                status: 200,
                headers: {'X-Limit': value},
                body: '',
              ),
            ),
            error,
            raw['name'] as String,
          );
        } else if (kind == 'body') {
          final body = '${List.filled(repeat, unit).join()}{}';
          _expectError(
            () => captureJson(
              r'$',
              MaskerRawResponse(status: 200, headers: const {}, body: body),
            ),
            error,
            raw['name'] as String,
          );
        } else if (kind == 'captureValue') {
          final value = List.filled(repeat, unit).join();
          final body = '{"token":"$value"}';
          _expectError(
            () => captureJson(
              r'$.token',
              MaskerRawResponse(status: 200, headers: const {}, body: body),
            ),
            error,
            raw['name'] as String,
          );
        } else {
          final entries = <String>[];
          for (var k = 0; k < (raw['entries'] as int? ?? 0); k++) {
            entries.add('"k$k":"v$k"');
          }
          final rules = <MaskerRule>[];
          for (var k = 0; k < (raw['rules'] as int? ?? 0); k++) {
            rules.add(
              MaskerRule(
                id: 'r$k',
                capture: MaskerCaptureDecl(
                  source: 'json',
                  path: '\$.k$k',
                  destinationKind: 'redact',
                ),
                project: 'replace',
              ),
            );
          }
          _expectError(
            () => applyResponseMasker(
              rules,
              MaskerRawResponse(
                status: 200,
                headers: const {'content-type': 'application/json'},
                body: '{${entries.join(',')}}',
              ),
            ),
            error,
            raw['name'] as String,
          );
        }
      });
    }
  });

  group('captureHeader（收割 + fail-closed）', () {
    for (final raw
        in (golden['captureHeader'] as List).cast<Map<String, dynamic>>()) {
      test(raw['name'] as String, () {
        final response = _resp(
          (raw['response'] as Map).cast<String, dynamic>(),
        );
        final name = raw['headerName'] as String;
        if (raw['error'] != null) {
          _expectError(
            () => captureHeader(name, response),
            raw['error'] as String,
            raw['name'] as String,
          );
        } else {
          expect(captureHeader(name, response), raw['expected']);
        }
      });
    }
  });

  group('captureJson（收割 + fail-closed）', () {
    for (final raw
        in (golden['captureJson'] as List).cast<Map<String, dynamic>>()) {
      test(raw['name'] as String, () {
        final response = _resp(
          (raw['response'] as Map).cast<String, dynamic>(),
        );
        final path = raw['path'] as String;
        if (raw['error'] != null) {
          _expectError(
            () => captureJson(path, response),
            raw['error'] as String,
            raw['name'] as String,
            expectedKey: raw['errorKey'] as String?,
          );
        } else {
          expect(captureJson(path, response), raw['expected']);
        }
      });
    }
  });

  group('project（投影 + 实体头清理）', () {
    for (final raw
        in (golden['project'] as List).cast<Map<String, dynamic>>()) {
      test(raw['name'] as String, () {
        final rules = _rules(raw['rules'] as List);
        final response = _resp(
          (raw['response'] as Map).cast<String, dynamic>(),
        );
        final actual = _projectedToJson(projectResponse(rules, response));
        final expected = (raw['expected'] as Map).cast<String, dynamic>();
        expect(actual['status'], expected['status']);
        expect(actual['body'], expected['body']);
        expect(
          actual['headers'],
          equals((expected['headers'] as Map).cast<String, String>()),
        );
      });
    }
  });

  group('transaction（Capture→Project 原子性）', () {
    for (final raw
        in (golden['transaction'] as List).cast<Map<String, dynamic>>()) {
      test(raw['name'] as String, () {
        final rules = _rules(raw['rules'] as List);
        final response = _resp(
          (raw['response'] as Map).cast<String, dynamic>(),
        );
        if (raw['error'] != null) {
          _expectError(
            () => applyResponseMasker(rules, response),
            raw['error'] as String,
            raw['name'] as String,
          );
        } else {
          final outcome = applyResponseMasker(rules, response);
          final expected = (raw['expected'] as Map).cast<String, dynamic>();
          final expectedCaptured = (expected['captured'] as List)
              .cast<Map<String, dynamic>>();
          expect(outcome.captured.length, expectedCaptured.length);
          for (var i = 0; i < expectedCaptured.length; i++) {
            expect(outcome.captured[i].ruleId, expectedCaptured[i]['ruleId']);
            expect(outcome.captured[i].ref, expectedCaptured[i]['ref']);
            expect(outcome.captured[i].value, expectedCaptured[i]['value']);
          }
          final projected = _projectedToJson(outcome.projected);
          final expectedProjected = (expected['projected'] as Map)
              .cast<String, dynamic>();
          expect(projected['status'], expectedProjected['status']);
          expect(projected['body'], expectedProjected['body']);
          expect(
            projected['headers'],
            equals(
              (expectedProjected['headers'] as Map).cast<String, String>(),
            ),
          );
        }
      });
    }
  });
}
