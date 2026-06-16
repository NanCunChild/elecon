/// B5 收割桥接双跑（客户端半边）—— Dart `decideHarvest` 对
/// `contract/golden/broker/harvest.json` 的产出必须等于每例 `expected`，
/// 与 TS `harvest.smoke.ts` 双跑同一向量（ADR-001 §8）。
///
/// 纯逻辑、不经 QuickJS → 无原生库依赖、不限 Linux。
///
///   运行：cd client && fvm flutter test test/broker_harvest_test.dart
///
/// ⚠️ 夹具值为显式假值（红线 #8）：绝不使用真实凭证/会话。
import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/broker/cookie_jar.dart';
import 'package:elecon/core/broker/harvest.dart';
import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/credential/store.dart';
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

JarCookie _cookieFromJson(Map<String, dynamic> c) => JarCookie(
      name: c['name'] as String,
      value: c['value'] as String,
      domain: c['domain'] as String,
      path: c['path'] as String,
      source: c['source'] as String,
    );

void main() {
  final goldenPath = '${_repoPath('contract/golden/broker')}/harvest.json';
  final golden =
      jsonDecode(File(goldenPath).readAsStringSync()) as Map<String, dynamic>;
  final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();

  group('B5 harvest 决策（Dart，与 TS 双跑同一 golden）', () {
    test('golden 非空', () => expect(cases, isNotEmpty));

    for (final c in cases) {
      test(c['name'] as String, () {
        final input = c['input'] as Map<String, dynamic>;
        final cookies = (input['originCookies'] as List)
            .cast<Map<String, dynamic>>()
            .map(_cookieFromJson)
            .toList();
        final view = _viewFromJson(input['view'] as Map<String, dynamic>);
        final plan = decideHarvest(cookies, view);
        expect(
          plan.map((e) => e.toJson()).toList(),
          equals(c['expected']),
        );
      });
    }
  });

  group('B5 harvest 集成（Dart，与 TS smoke 同场景）', () {
    const view = BrokerManifestView(
      allow: ['https://ids.xjtu.edu.cn/*'],
      credentials: {
        'sess': CredentialDecl(
          scope: ['https://ids.xjtu.edu.cn/*'],
          type: 'cookie',
        ),
      },
    );
    final cookies = [
      const JarCookie(
          name: 'JSESSIONID',
          value: 'S1',
          domain: 'ids.xjtu.edu.cn',
          path: '/',
          source: 'origin'),
      const JarCookie(
          name: 'CASTGC',
          value: 'C1',
          domain: 'ids.xjtu.edu.cn',
          path: '/',
          source: 'origin'),
    ];

    test('收割 → 入库 → get 取到序列化值（B6 注入即用此值）', () async {
      var clock = 5000;
      final store = CredentialStore(now: () => clock);
      harvestInto(decideHarvest(cookies, view), view, store.put,
          schoolId: 'xjt', now: () => clock);

      final resolved = await store.get('sess');
      expect(resolved, isNotNull);
      expect(resolved!.via, 'cookie');
      expect(resolved.value, 'CASTGC=C1; JSESSIONID=S1');

      final entry = store.list().firstWhere((e) => e.ref == 'sess');
      expect(entry.scope, ['https://ids.xjtu.edu.cn/*']);
      expect(entry.schoolId, 'xjt');
      expect(entry.expiresAt, isNull);
    });

    test('会话轮换：同 ref 再收割覆盖旧值', () async {
      var clock = 5000;
      final store = CredentialStore(now: () => clock);
      harvestInto(decideHarvest(cookies, view), view, store.put,
          schoolId: 'xjt', now: () => clock);
      clock = 6000;
      final rotated = [
        const JarCookie(
            name: 'JSESSIONID',
            value: 'S2',
            domain: 'ids.xjtu.edu.cn',
            path: '/',
            source: 'origin'),
      ];
      harvestInto(decideHarvest(rotated, view), view, store.put,
          schoolId: 'xjt', now: () => clock);
      final after = await store.get('sess');
      expect(after?.value, 'JSESSIONID=S2');
    });

    test('无声明 ref → 空计划不写库', () {
      final store = CredentialStore(now: () => 5000);
      const noCred =
          BrokerManifestView(allow: ['https://ids.xjtu.edu.cn/*'], credentials: {});
      harvestInto(decideHarvest(cookies, noCred), noCred, store.put,
          schoolId: 'xjt', now: () => 5000);
      expect(store.list(), isEmpty);
    });
  });
}
