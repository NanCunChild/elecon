/// B6a 拼装管线双跑（客户端半边 = B6c）—— Dart `assembleRequest`/`processResponse` 对
/// `contract/golden/broker/assemble.json` 的产出必须等于每例 `expected`。
///
/// 两端一致闸门（ADR-001 §8）：TS smoke == expected ∧ Dart test == expected ⟹ 零漂移。
/// 拼装/脱敏是纯逻辑、不经 QuickJS → 无原生库依赖、不限 Linux。
/// 有态驱动（proxyFetch / transport / 重定向链）属 B6b 运行时，不在本镜像。
///
///   运行：cd client && fvm flutter test test/broker_assemble_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/broker/assemble.dart';
import 'package:elecon/core/broker/inject_policy.dart';
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

/// 解析 golden 内嵌的 B1 decision（mirror inject_policy 的 toJson 形）。
InjectionDecision _decisionFromJson(Map<String, dynamic> j) {
  switch (j['kind'] as String) {
    case 'reject':
      return RejectDecision(j['reason'] as String);
    case 'passthrough':
      return const PassthroughDecision();
    case 'inject':
      return InjectDecision(ref: j['ref'] as String, via: j['via'] as String);
    default:
      throw StateError('未知 decision.kind: ${j['kind']}');
  }
}

AssembleRequestInput _assembleInputFromJson(Map<String, dynamic> j) {
  final initJson = j['init'] as Map<String, dynamic>;
  final init = RequestInit(
    method: initJson['method'] as String?,
    headers: initJson['headers'] == null ? null : _headers(initJson['headers']),
    body: initJson['body'] as String?,
  );
  final resolvedJson = j['resolved'] as Map<String, dynamic>?;
  final resolved = resolvedJson == null
      ? null
      : ResolvedCredential(
          via: resolvedJson['via'] as String,
          value: resolvedJson['value'] as String,
        );
  final jarCookies = (j['jarCookies'] as List)
      .map((e) => CookiePair((e as Map)['name'] as String, e['value'] as String))
      .toList();
  return AssembleRequestInput(
    init: init,
    decision: _decisionFromJson(j['decision'] as Map<String, dynamic>),
    resolved: resolved,
    jarCookies: jarCookies,
  );
}

RawResponse _rawFromJson(Map<String, dynamic> j) => RawResponse(
      status: j['status'] as int,
      headers: _headers(j['headers']),
      body: j['body'] as String?,
    );

void main() {
  final goldenPath = '${_repoPath('contract/golden/broker')}/assemble.json';
  final golden =
      jsonDecode(File(goldenPath).readAsStringSync()) as Map<String, dynamic>;
  final assembleCases = (golden['assemble'] as List).cast<Map<String, dynamic>>();
  final processCases = (golden['process'] as List).cast<Map<String, dynamic>>();

  group('B6a assemble（Dart，与 TS 双跑同一 golden）', () {
    test('golden 非空', () {
      expect(assembleCases, isNotEmpty);
      expect(processCases, isNotEmpty);
    });

    for (final c in assembleCases) {
      test('assemble · ${c['name']}', () {
        final input = _assembleInputFromJson(c['input'] as Map<String, dynamic>);
        expect(assembleRequest(input).toJson(), equals(c['expected']));
      });
    }

    for (final c in processCases) {
      test('process · ${c['name']}', () {
        final actual = processResponse(_rawFromJson(c['input'] as Map<String, dynamic>));
        expect(actual.toJson(), equals(c['expected']));
      });
    }
  });
}
