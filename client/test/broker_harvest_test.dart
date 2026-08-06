/// B5 收割桥接双跑（客户端半边）—— Dart `decideHarvest` 对
/// `contract/golden/broker/harvest.json` 的产出必须等于每例 `expected`，
/// 与 TS `harvest.smoke.ts` 双跑同一向量（ADR-001 §8）。
///
/// 纯逻辑、不经 QuickJS → 无原生库依赖、不限 Linux。
///
///   运行：cd client && fvm flutter test test/broker_harvest_test.dart
///
/// ⚠️ 夹具值为显式假值（红线 #8）：绝不使用真实凭证/会话。
library;

import 'package:elecon/core/broker/cookie_jar.dart';
import 'package:elecon/core/broker/harvest.dart';
import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

void main() {
  final cases = readGoldenCases('harvest.json');
  final queryCases = readGoldenCases('harvest.json', 'queryCases');

  group('B5 harvest 决策（Dart，与 TS 双跑同一 golden）', () {
    test('golden 非空', () => expect(cases, isNotEmpty));

    for (final c in cases) {
      test(c['name'] as String, () {
        final input = c['input'] as Map<String, dynamic>;
        final cookies = (input['originCookies'] as List)
            .cast<Map<String, dynamic>>()
            .map(cookieFromJson)
            .toList();
        final view = viewFromJson(input['view'] as Map<String, dynamic>);
        final plan = decideHarvest(cookies, view);
        expect(plan.map((e) => e.toJson()).toList(), equals(c['expected']));
      });
    }
  });

  group('query 收割决策（Dart，与 TS 双跑同一 golden · ADR-020 §2.3）', () {
    test('golden 非空', () => expect(queryCases, isNotEmpty));

    for (final c in queryCases) {
      test(c['name'] as String, () {
        final input = c['input'] as Map<String, dynamic>;
        final view = viewFromJson(input['view'] as Map<String, dynamic>);
        final plan = decideQueryHarvest(input['url'] as String, view);
        expect(plan.map((e) => e.toJson()).toList(), equals(c['expected']));
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
        source: 'origin',
      ),
      const JarCookie(
        name: 'CASTGC',
        value: 'C1',
        domain: 'ids.xjtu.edu.cn',
        path: '/',
        source: 'origin',
      ),
    ];

    test('收割 → 入库 → get 取到序列化值（B6 注入即用此值）', () async {
      var clock = 5000;
      final store = CredentialStore(now: () => clock);
      harvestInto(
        decideHarvest(cookies, view),
        view,
        store.put,
        schoolId: 'xjt',
        now: () => clock,
      );

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
      harvestInto(
        decideHarvest(cookies, view),
        view,
        store.put,
        schoolId: 'xjt',
        now: () => clock,
      );
      clock = 6000;
      final rotated = [
        const JarCookie(
          name: 'JSESSIONID',
          value: 'S2',
          domain: 'ids.xjtu.edu.cn',
          path: '/',
          source: 'origin',
        ),
      ];
      harvestInto(
        decideHarvest(rotated, view),
        view,
        store.put,
        schoolId: 'xjt',
        now: () => clock,
      );
      final after = await store.get('sess');
      expect(after?.value, 'JSESSIONID=S2');
    });

    test('无声明 ref → 空计划不写库', () {
      final store = CredentialStore(now: () => 5000);
      const noCred = BrokerManifestView(
        allow: ['https://ids.xjtu.edu.cn/*'],
        credentials: {},
      );
      harvestInto(
        decideHarvest(cookies, noCred),
        noCred,
        store.put,
        schoolId: 'xjt',
        now: () => 5000,
      );
      expect(store.list(), isEmpty);
    });

    test('Set-Cookie parser 的 host-only 标记阻止子域 scope 收割', () {
      const subdomainView = BrokerManifestView(
        allow: ['https://sub.ids.xjtu.edu.cn/*'],
        credentials: {
          'sub': CredentialDecl(
            scope: ['https://sub.ids.xjtu.edu.cn/*'],
            type: 'cookie',
          ),
        },
      );
      final jar = CookieJar()
        ..captureSetCookie([
          'SID=HOST_ONLY; Path=/',
        ], 'https://ids.xjtu.edu.cn/login');
      expect(decideHarvest(jar.harvestView(), subdomainView), isEmpty);
    });
  });

  test('query 收割 → 入库 → get 序列化值（决策由 golden 覆盖，此处验集成）', () async {
    const view = BrokerManifestView(
      allow: ['https://card.xidian.edu.cn/*'],
      credentials: {
        'card': CredentialDecl(
          scope: ['https://card.xidian.edu.cn/*'],
          type: 'query',
          queryParam: 'openid',
        ),
      },
    );
    final store = CredentialStore(now: () => 6000);
    harvestInto(
      decideQueryHarvest('https://card.xidian.edu.cn/home?openid=opaque', view),
      view,
      store.put,
      schoolId: 'xidian',
      now: () => 6000,
    );
    final card = await store.get('card');
    expect(card?.via, 'query');
    expect(card?.value, 'opaque');
  });
}
