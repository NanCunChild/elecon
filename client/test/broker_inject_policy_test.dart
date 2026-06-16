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
import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/broker/inject_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// 从当前工作目录向上找到仓库内的某个相对路径（同 dual_run_test 的定位手法）。
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

BrokerManifestView _viewFromJson(Map<String, dynamic> v) {
  final credentials = <String, CredentialDecl>{};
  final c = v['credentials'] as Map<String, dynamic>?;
  if (c != null) {
    c.forEach((ref, decl) {
      final d = decl as Map<String, dynamic>;
      credentials[ref] = CredentialDecl(
        scope: (d['scope'] as List).cast<String>(),
        type: d['type'] as String,
      );
    });
  }
  return BrokerManifestView(
    allow: (v['allow'] as List).cast<String>(),
    credentials: credentials,
  );
}

void main() {
  final goldenPath =
      '${_repoPath('contract/golden/broker')}/inject-policy.json';
  final golden =
      jsonDecode(File(goldenPath).readAsStringSync()) as Map<String, dynamic>;
  final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();

  group('B1 inject-policy（Dart，与 TS 双跑同一 golden）', () {
    test('golden 非空', () {
      expect(cases, isNotEmpty);
    });

    for (final c in cases) {
      test(c['name'] as String, () {
        final view = _viewFromJson(c['view'] as Map<String, dynamic>);
        final decision = decideInjection(c['url'] as String, view);
        expect(decision.toJson(), equals(c['expected']));
      });
    }
  });
}
