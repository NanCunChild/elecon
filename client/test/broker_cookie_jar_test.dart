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
library;

import 'package:elecon/core/broker/cookie_jar.dart';
import 'package:elecon/core/broker/inject_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

EphemeralWriteInput _optsFromJson(Map<String, dynamic> o) =>
    EphemeralWriteInput(
      name: o['name'] as String,
      value: o['value'] as String,
      domain: o['domain'] as String,
      path: o['path'] as String?,
    );

void main() {
  final golden = readGolden('cookie-jar.json');

  group('B4 cookie-jar 纯决策（Dart，与 TS 双跑同一 golden）', () {
    final writeCases = (golden['decideEphemeralWrite'] as List)
        .cast<Map<String, dynamic>>();
    final matchCases = (golden['matchCookieForSend'] as List)
        .cast<Map<String, dynamic>>();
    final selectCases = (golden['selectCookies'] as List)
        .cast<Map<String, dynamic>>();

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
        final actual = matchCookieForSend((
          domain: cookie['domain'] as String,
          path: cookie['path'] as String,
          hostOnly: cookie['hostOnly'] as bool? ?? false,
        ), input['requestUrl'] as String);
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
      expect(v.first.hostOnly, isTrue);
      expect(v.first.path, '/a');
      expect(jar.cookieHeader('https://dean.xjtu.edu.cn/a/x'), 'sid=abc');
      expect(jar.cookieHeader('https://dean.xjtu.edu.cn/other'), '');
    });

    test('显式 Domain/Path 保留 domain 语义；父域合法', () {
      final jar = CookieJar()
        ..captureSetCookie([
          'sess=xyz; Domain=.xjtu.edu.cn; Path=/',
        ], 'https://dean.xjtu.edu.cn/login');
      final v = jar.harvestView();
      expect(v.first.domain, 'xjtu.edu.cn');
      expect(v.first.hostOnly, isFalse);
      expect(v.first.path, '/');
      expect(jar.cookieHeader('https://child.xjtu.edu.cn/'), 'sess=xyz');
    });

    test('无 Domain cookie 不发往子域', () {
      final jar = CookieJar()
        ..captureSetCookie([
          'sid=HOST_ONLY; Path=/',
        ], 'https://dean.xjtu.edu.cn/');
      expect(jar.cookieHeader('https://dean.xjtu.edu.cn/'), 'sid=HOST_ONLY');
      expect(jar.cookieHeader('https://sub.dean.xjtu.edu.cn/'), '');
    });

    test('非法 Domain 整条丢弃（#79 P0-4，RFC 6265 §5.3 step 6）', () {
      final jar = CookieJar()
        // 完全无关的域
        ..captureSetCookie([
          'evil=1; Domain=other.edu.cn',
        ], 'https://dean.xjtu.edu.cn/x')
        // 子域伪造（响应 host 是被声明域的父域，不 domain-match）
        ..captureSetCookie([
          'evil2=1; Domain=sub.dean.xjtu.edu.cn',
        ], 'https://dean.xjtu.edu.cn/x')
        // 过宽父域 / public suffix 类 Domain：会污染其他 *.edu.cn host
        ..captureSetCookie([
          'evil3=1; Domain=edu.cn',
        ], 'https://dean.xjtu.edu.cn/x');
      expect(
        jar.harvestView(),
        isEmpty,
        reason: '非法 Domain 的 Set-Cookie 必须整条丢弃',
      );
      expect(
        jar.cookieHeader('https://other.edu.cn/x'),
        '',
        reason: '伪造 cookie 不得发往他域',
      );
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

    test(
      'public-suffix 护栏常量 == contract/broker/public-suffixes.json（单源钉死）',
      () {
        // TS 侧运行时直接加载该 JSON；Dart 侧是编译期常量。本断言保证单边增删条目
        // 立即 CI 红（审阅建议：数据形式的双写下沉为 contract 单一 JSON）。
        final json = readJson(repoPath('contract/broker/public-suffixes.json'));
        final contractSuffixes = (json['multiLabelPublicSuffixes'] as List)
            .cast<String>()
            .map((s) => s.toLowerCase())
            .toSet();
        expect(contractSuffixes, isNotEmpty);
        expect(
          knownMultiLabelPublicSuffixes,
          equals(contractSuffixes),
          reason: '护栏列表与 contract 单源漂移：两处须同步增删',
        );
      },
    );

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
