/// B4 cookie jar 双跑（客户端半边）—— Dart 纯决策对
/// `contract/golden/broker/cookie-jar.json` 的产出必须等于每例 `expected`，
/// 与 TS `cookie-jar.smoke.ts` 双跑同一向量（ADR-001 §8）。
///
///   - 服务端 TS  == expected  →  server/src/runtime/broker/cookie-jar.smoke.ts 已证
///   - 客户端 Dart == expected  →  本测试
///   ⟹ 传递地，两端 cookie jar 决策零漂移。
///
/// 纯逻辑、不经 QuickJS → 无原生库依赖、不限 Linux。
///
///   运行：cd client && fvm flutter test test/broker_cookie_jar_test.dart
///
/// ⚠️ 夹具值为显式假值（红线 #8）：绝不使用真实凭证/会话。
import 'package:elecon/core/broker/cookie_jar.dart';
import 'package:elecon/core/broker/inject_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

EphemeralWriteInput _optsFromJson(Map<String, dynamic> o) => EphemeralWriteInput(
      name: o['name'] as String,
      value: o['value'] as String,
      domain: o['domain'] as String,
      path: o['path'] as String?,
    );

void main() {
  final golden = readGolden('cookie-jar.json');

  group('B4 cookie-jar 纯决策（Dart，与 TS 双跑同一 golden）', () {
    final writeCases =
        (golden['decideEphemeralWrite'] as List).cast<Map<String, dynamic>>();
    final matchCases =
        (golden['matchCookieForSend'] as List).cast<Map<String, dynamic>>();
    final selectCases =
        (golden['selectCookies'] as List).cast<Map<String, dynamic>>();

    test('golden 各组非空', () {
      expect(writeCases, isNotEmpty);
      expect(matchCases, isNotEmpty);
      expect(selectCases, isNotEmpty);
    });

    for (final c in writeCases) {
      test('decideEphemeralWrite · ${c['name']}', () {
        final input = c['input'] as Map<String, dynamic>;
        final decision = decideEphemeralWrite(
          _optsFromJson(input['opts'] as Map<String, dynamic>),
          viewFromJson(input['view'] as Map<String, dynamic>),
        );
        expect(decision.toJson(), equals(c['expected']));
      });
    }

    for (final c in matchCases) {
      test('matchCookieForSend · ${c['name']}', () {
        final input = c['input'] as Map<String, dynamic>;
        final cookie = input['cookie'] as Map<String, dynamic>;
        final actual = matchCookieForSend(
          (domain: cookie['domain'] as String, path: cookie['path'] as String),
          input['requestUrl'] as String,
        );
        expect(actual, equals(c['expected']));
      });
    }

    for (final c in selectCases) {
      test('selectCookies · ${c['name']}', () {
        final input = c['input'] as Map<String, dynamic>;
        final cookies = (input['cookies'] as List)
            .cast<Map<String, dynamic>>()
            .map(cookieFromJson)
            .toList();
        final actual = selectCookies(cookies, input['requestUrl'] as String);
        expect(actual, equals(c['expected']));
      });
    }
  });

  group('B4 cookie-jar 有态（Dart，与 TS smoke 同场景）', () {
    const view = BrokerManifestView(
      allow: ['https://dean.xjtu.edu.cn/*', 'https://ids.xjtu.edu.cn/*'],
      credentials: {
        'sess': CredentialDecl(
          scope: ['https://ids.xjtu.edu.cn/*'],
          type: 'cookie',
        ),
      },
    );

    test('捕获缺省 domain/path（host-only + default-path）', () {
      final jar = CookieJar()
        ..captureSetCookie(['sid=abc'], 'https://dean.xjtu.edu.cn/a/b');
      final v = jar.harvestView();
      expect(v.length, 1);
      expect(v.first.domain, 'dean.xjtu.edu.cn');
      expect(v.first.path, '/a');
      expect(jar.cookieHeader('https://dean.xjtu.edu.cn/a/x'), 'sid=abc');
      expect(jar.cookieHeader('https://dean.xjtu.edu.cn/other'), '');
    });

    test('显式 Domain/Path（前导点归一为 host-only）', () {
      final jar = CookieJar()
        ..captureSetCookie(
          ['sess=xyz; Domain=.xjtu.edu.cn; Path=/'],
          'https://dean.xjtu.edu.cn/login',
        );
      final v = jar.harvestView();
      expect(v.first.domain, 'xjtu.edu.cn');
      expect(v.first.path, '/');
    });

    test('跨跳累计 + 同 (name,domain,path) 轮换覆盖', () {
      final jar = CookieJar()
        ..captureSetCookie(['a=1'], 'https://dean.xjtu.edu.cn/')
        ..captureSetCookie(['b=2'], 'https://dean.xjtu.edu.cn/')
        ..captureSetCookie(['a=ROTATED'], 'https://dean.xjtu.edu.cn/');
      expect(jar.harvestView().length, 2);
      expect(jar.cookieHeader('https://dean.xjtu.edu.cn/'), 'a=ROTATED; b=2');
    });

    test('ephemeral 接受但同名让位 origin（栅栏 2）+ 不进收割（栅栏 3）', () {
      final warns = <String>[];
      final jar = CookieJar()
        ..captureSetCookie(['client_id=ORIGIN'], 'https://dean.xjtu.edu.cn/');
      final ok = jar.writeEphemeral(
        const EphemeralWriteInput(
          name: 'client_id',
          value: 'EPH',
          domain: 'dean.xjtu.edu.cn',
        ),
        view,
        warns.add,
      );
      expect(ok, isTrue);
      expect(jar.cookieHeader('https://dean.xjtu.edu.cn/'), 'client_id=ORIGIN');
      expect(jar.harvestView().length, 1);
      expect(jar.harvestView().every((c) => c.source == 'origin'), isTrue);
    });

    test('ephemeral 被拒（凭证域）→ 静默丢弃 + warn（栅栏 1.2，不抛错）', () {
      final warns = <String>[];
      final jar = CookieJar();
      final ok = jar.writeEphemeral(
        const EphemeralWriteInput(
          name: 'x',
          value: 'v',
          domain: 'ids.xjtu.edu.cn',
        ),
        view,
        warns.add,
      );
      expect(ok, isFalse);
      expect(jar.cookieHeader('https://ids.xjtu.edu.cn/'), '');
      expect(jar.harvestView(), isEmpty);
      expect(warns.any((w) => w.contains('domain_is_credential')), isTrue);
    });

    test('ephemeral-only 在无 origin 同名时生效，且仍不收割', () {
      final warns = <String>[];
      final jar = CookieJar();
      final ok = jar.writeEphemeral(
        const EphemeralWriteInput(
          name: 'client_id',
          value: 'EPH',
          domain: 'dean.xjtu.edu.cn',
        ),
        view,
        warns.add,
      );
      expect(ok, isTrue);
      expect(jar.cookieHeader('https://dean.xjtu.edu.cn/'), 'client_id=EPH');
      expect(jar.harvestView(), isEmpty);
    });
  });
}
