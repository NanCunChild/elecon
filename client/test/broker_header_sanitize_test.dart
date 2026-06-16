/// B2 头净化双跑（客户端半边）—— Dart sanitize{Request,Response}Headers 对
/// `contract/golden/broker/header-sanitize.json` 的产出必须等于每例 `expected`。
///
/// 两端一致闸门（ADR-001 §8）：TS smoke == expected ∧ Dart test == expected ⟹ 零漂移。
/// B2 是纯逻辑、不经 QuickJS → 无原生库依赖、不限 Linux。
///
///   运行：cd client && fvm flutter test test/broker_header_sanitize_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/broker/header_sanitize.dart';
import 'package:flutter_test/flutter_test.dart';

String _repoPath(String relPath) {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final candidate = '${dir.path}/$relPath';
    if (File(candidate).existsSync() || Directory(candidate).existsSync()) {
      return candidate;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return '../$relPath';
}

Map<String, String> _headers(Object? json) =>
    (json as Map).map((k, v) => MapEntry(k as String, v as String));

void main() {
  final goldenPath =
      '${_repoPath('contract/golden/broker')}/header-sanitize.json';
  final golden =
      jsonDecode(File(goldenPath).readAsStringSync()) as Map<String, dynamic>;
  final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();

  group('B2 header-sanitize（Dart，与 TS 双跑同一 golden）', () {
    test('golden 非空', () => expect(cases, isNotEmpty));

    for (final c in cases) {
      test('${c['name']} (${c['direction']})', () {
        final input = _headers(c['input']);
        final expected = _headers(c['expected']);
        final actual = c['direction'] == 'request'
            ? sanitizeRequestHeaders(input)
            : sanitizeResponseHeaders(input);
        expect(actual, equals(expected));
      });
    }
  });
}
