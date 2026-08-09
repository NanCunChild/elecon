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
import 'package:elecon/core/broker/cookie_match.dart'
    show parseCookieDate, parseMaxAge;
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

/// 旧向量无 nowMs 字段（其 cookie 也无 expiresAt）；补 0 不改变任一例的判定。
const int _defaultNowMs = 0;

void main() {
  final golden = readGolden('cookie-jar.json');

  group('B4 cookie-jar 纯决策（Dart，与 TS 双跑同一 golden）', () {
    final writeCases = (golden['decideEphemeralWrite'] as List)
        .cast<Map<String, dynamic>>();
    final matchCases = (golden['matchCookieForSend'] as List)
        .cast<Map<String, dynamic>>();
    final selectCases = (golden['selectCookies'] as List)
        .cast<Map<String, dynamic>>();
    final dateCases = (golden['parseCookieDate'] as List)
        .cast<Map<String, dynamic>>();
    final maxAgeCases = (golden['parseMaxAge'] as List)
        .cast<Map<String, dynamic>>();
    final setCookieCases = (golden['parseSetCookie'] as List)
        .cast<Map<String, dynamic>>();

    test('golden 各组非空', () {
      expect(writeCases, isNotEmpty);
      expect(matchCases, isNotEmpty);
      expect(selectCases, isNotEmpty);
      expect(dateCases, isNotEmpty);
      expect(maxAgeCases, isNotEmpty);
      expect(setCookieCases, isNotEmpty);
    });

    for (final c in dateCases) {
      test('parseCookieDate · ${c['name']}', () {
        expect(parseCookieDate(c['input'] as String), equals(c['expected']));
      });
    }

    for (final c in maxAgeCases) {
      test('parseMaxAge · ${c['name']}', () {
        expect(parseMaxAge(c['input'] as String), equals(c['expected']));
      });
    }

    for (final c in setCookieCases) {
      test('parseSetCookie · ${c['name']}', () {
        final input = c['input'] as Map<String, dynamic>;
        final actual = parseSetCookie(
          input['header'] as String,
          input['requestUrl'] as String,
          input['nowMs'] as int,
        );
        expect(actual?.toJson(), equals(c['expected']));
      });
    }

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
        // 该组向量只给发送判据相关字段；补齐 JarCookie 必填项（不参与判定）。
        final actual = matchCookieForSend(
          JarCookie(
            name: 'n',
            value: 'v',
            domain: cookie['domain'] as String,
            path: cookie['path'] as String,
            hostOnly: cookie['hostOnly'] as bool? ?? false,
            source: 'origin',
            secure: cookie['secure'] as bool? ?? false,
            expiresAt: cookie['expiresAt'] as int?,
          ),
          input['requestUrl'] as String,
          input['nowMs'] as int? ?? _defaultNowMs,
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
        final actual = selectCookies(
          cookies,
          input['requestUrl'] as String,
          input['nowMs'] as int? ?? _defaultNowMs,
        );
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

  // 与 TS `cookie-jar.smoke.ts` 的「P1-05 / P1-06 有态行为」逐条同场景（2026-08-07）。
  group('B4 cookie-jar 有态 · P1-05 同名多 Path / P1-06 生命周期（Dart）', () {
    const now = 1600000000000;
    CookieJar at(int t) => CookieJar(() => t);

    test('P1-05：同名不同 Path 并存，两条都发（长 Path 先）', () {
      final jar = at(now)
        ..captureSetCookie(['sid=ROOT; Path=/'], 'https://dean.xjtu.edu.cn/')
        ..captureSetCookie([
          'sid=API; Path=/api',
        ], 'https://dean.xjtu.edu.cn/api/x');
      expect(
        jar.harvestView().length,
        2,
        reason: '同名不同 Path 必须并存（旧实现折叠成 1 条）',
      );
      expect(
        jar.cookieHeader('https://dean.xjtu.edu.cn/api/grades'),
        'sid=API; sid=ROOT',
      );
      expect(jar.cookieHeader('https://dean.xjtu.edu.cn/portal'), 'sid=ROOT');
    });

    test('覆盖键 = (name, domain, path)：同名同域同 Path 新值替换旧值', () {
      final jar = at(now)
        ..captureSetCookie([
          'sid=OLD; Path=/api',
        ], 'https://dean.xjtu.edu.cn/api/x')
        ..captureSetCookie([
          'sid=NEW; Path=/api',
        ], 'https://dean.xjtu.edu.cn/api/x');
      expect(jar.harvestView().length, 1);
      expect(jar.cookieHeader('https://dean.xjtu.edu.cn/api/x'), 'sid=NEW');
    });

    test('P1-06：Max-Age=0 删除该 cookie（不留死条目）', () {
      final jar = at(now)
        ..captureSetCookie(['sid=LIVE; Path=/'], 'https://dean.xjtu.edu.cn/')
        ..captureSetCookie([
          'sid=; Path=/; Max-Age=0',
        ], 'https://dean.xjtu.edu.cn/');
      expect(jar.harvestView(), isEmpty, reason: 'Max-Age=0 必须删除该 cookie');
      expect(jar.cookieHeader('https://dean.xjtu.edu.cn/'), '');
    });

    test('删除只命中同 Path 的那条，不误删同名其它 Path', () {
      final jar = at(now)
        ..captureSetCookie(['sid=ROOT; Path=/'], 'https://dean.xjtu.edu.cn/')
        ..captureSetCookie([
          'sid=API; Path=/api',
        ], 'https://dean.xjtu.edu.cn/api/x')
        ..captureSetCookie([
          'sid=; Path=/api; Max-Age=0',
        ], 'https://dean.xjtu.edu.cn/api/x');
      expect(jar.cookieHeader('https://dean.xjtu.edu.cn/api/x'), 'sid=ROOT');
    });

    test('P1-06：过去的 Expires 同样是删除信号', () {
      final jar = at(now)
        ..captureSetCookie(['sid=LIVE'], 'https://dean.xjtu.edu.cn/')
        ..captureSetCookie([
          'sid=X; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
        ], 'https://dean.xjtu.edu.cn/');
      expect(
        jar.harvestView(),
        isEmpty,
        reason: '过去的 Expires 必须删除该 cookie',
      );
    });

    test('P1-06：捕获后自然到点 → 不再发送、不再收割', () {
      var clock = now;
      final jar = CookieJar(() => clock)
        ..captureSetCookie([
          'sid=abc; Max-Age=60',
        ], 'https://dean.xjtu.edu.cn/');
      expect(jar.cookieHeader('https://dean.xjtu.edu.cn/'), 'sid=abc');
      expect(jar.harvestView().length, 1);
      clock = now + 61000;
      expect(
        jar.cookieHeader('https://dean.xjtu.edu.cn/'),
        '',
        reason: '过期后不得再发出',
      );
      expect(jar.harvestView(), isEmpty, reason: '过期后不得再进收割');
    });

    test('P1-06：Secure 只随 https 出门', () {
      final jar = at(now)
        ..captureSetCookie([
          'sess=S; Secure',
          'pref=P',
        ], 'https://dean.xjtu.edu.cn/');
      expect(jar.cookieHeader('https://dean.xjtu.edu.cn/'), 'pref=P; sess=S');
      expect(
        jar.cookieHeader('http://dean.xjtu.edu.cn/'),
        'pref=P',
        reason: 'Secure 不得随 http 发出',
      );
    });
  });
}
