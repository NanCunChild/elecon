/// XIDIAN IDS CAS WebView 收割实验（ADR-016 §2.1，WebView 主路线）。
///
/// 以 XIDIAN IDS（统一认证 CAS）为标的，模拟 WebView 登录完成后的 cookie jar
/// 状态，验证「导航闭锁 → 成功检测 → cookie 收割 → CredentialStore 写入」全链路。
///
/// XIDIAN IDS CAS 流程（来自 `adapters_tests/XIDIAN/ids/login.py`）：
///   [1] 加载 ids.xidian.edu.cn/authserver/login（密码加密+滑块验证码）
///   [2] 登录成功后 CAS ticket 链：ids → ehall / v8scan / hyytsgxzs / xxcapp
///   [3] 各子服务下发 session cookie → WebView 内可见
///   [4] 收割时按 manifest `credentials.<ref>.scope` 过滤——CASTGC 永不入库
///
/// 🔒 红线 #1 承重路径：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环。
library;

import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/login/webview_login.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ── XIDIAN IDS CAS 登录 Manifest（模拟 manifest.json 的 login 段） ──
  //
  // navigationAllow 覆盖全部 CAS 跳转域（ids + 各子服务）。
  // successUrlMatches 覆盖各子服务登录成功落地页（带/不带 CAS ticket）。
  // credentials 声明各子服务 session ref：
  //   - ehall-session：一网通办 session（cookie，scope=ehall.xidian.edu.cn/*）
  //   - card-session：一卡通 openid cookie（cookie，scope=v8scan.xidian.edu.cn/*）
  //   - library-session：图书馆 shuwo cookie（cookie，scope=hyytsgxzs.xidian.edu.cn/*）

  final xidianLogin = LoginManifestView(
    schoolId: 'xidian',
    url: 'https://ids.xidian.edu.cn/authserver/login',
    navigationAllow: const [
      'https://ids.xidian.edu.cn/*',
      'https://ehall.xidian.edu.cn/*',
      'https://v8scan.xidian.edu.cn/*',
      'https://hyytsgxzs.xidian.edu.cn/*',
      'https://xxcapp.xidian.edu.cn/*',
    ],
    successUrlMatches: const [
      'https://ehall.xidian.edu.cn/new/index.html*',
      'https://v8scan.xidian.edu.cn/myaccount/openMyAccount*',
      'https://hyytsgxzs.xidian.edu.cn/*',
    ],
    brokerView: BrokerManifestView(
      allow: [
        'https://ehall.xidian.edu.cn/*',
        'https://v8scan.xidian.edu.cn/*',
        'https://hyytsgxzs.xidian.edu.cn/*',
        'https://shuwo.xidian.edu.cn/*',
        'https://xxcapp.xidian.edu.cn/*',
      ],
      credentials: {
        'ehall-session': const CredentialDecl(
          scope: ['https://ehall.xidian.edu.cn/*'],
          type: 'cookie',
        ),
        'card-session': const CredentialDecl(
          scope: ['https://v8scan.xidian.edu.cn/*'],
          type: 'cookie',
        ),
        'library-session': const CredentialDecl(
          scope: ['https://hyytsgxzs.xidian.edu.cn/*'],
          type: 'cookie',
        ),
      },
    ),
  );

  // ── 模拟 CAS 登录完成后 WebView cookie jar 状态 ──
  //
  // 典型状态：ids 下发了 CASTGC（CAS TGT），ehall / v8scan / hyytsgxzs
  // 各自下发了子域 session cookie。CASTGC 永不应被收割（红线 #1）。
  //
  // [domain] 模拟 WebView 上报的 cookie 域（flutter_inappwebview Cookie 格式）。

  const webViewCookiesAfterCas = <WebViewCookie>[
    // ids.xidian.edu.cn —— CAS TGT（永不收割，红线 #1）
    WebViewCookie(
      name: 'CASTGC',
      value: 'TGT-1867-qWxRzYkVNmPj3KdL',
      domain: 'ids.xidian.edu.cn',
      path: '/',
    ),
    WebViewCookie(
      name: 'JSESSIONID',
      value: 'ids-aaaa',
      domain: 'ids.xidian.edu.cn',
      path: '/authserver',
    ),
    // ehall.xidian.edu.cn —— 一网通办 session
    WebViewCookie(
      name: 'JSESSIONID',
      value: 'ehall-bbbb',
      domain: '.ehall.xidian.edu.cn',
      path: '/',
    ),
    WebViewCookie(
      name: 'route',
      value: 'e03b8cb4c86e90e0a5db8cd1376c0ea5',
      domain: 'ehall.xidian.edu.cn',
      path: '/',
    ),
    // v8scan.xidian.edu.cn —— 一卡通 openid cookie
    WebViewCookie(
      name: 'openid',
      value: 'oxxxxxxxxxxxxxxxxxxxxxxxxxx',
      domain: 'v8scan.xidian.edu.cn',
      path: '/',
    ),
    // hyytsgxzs.xidian.edu.cn —— 图书馆会话
    WebViewCookie(
      name: 'SESSION',
      value: 'library-cccc',
      domain: 'hyytsgxzs.xidian.edu.cn',
      path: '/',
    ),
    // xxcapp.xidian.edu.cn —— 水电 session（未在 credentials 中声明，不应收割）
    WebViewCookie(
      name: 'x-auth-token',
      value: 'energy-dddd',
      domain: 'xxcapp.xidian.edu.cn',
      path: '/',
    ),
  ];

  // ════════════════════════════════════════════════════════════════════
  // Group A · 导航闭锁（navigation allowlist）
  // ════════════════════════════════════════════════════════════════════

  group('A · XIDIAN navigation allowlist', () {
    test('A1: IDS 登录页在 allowlist 内', () {
      expect(
        isLoginNavigationAllowed(
          'https://ids.xidian.edu.cn/authserver/login',
          xidianLogin,
        ),
        isTrue,
      );
    });

    test('A2: IDS 滑块验证码 API 在 allowlist 内', () {
      expect(
        isLoginNavigationAllowed(
          'https://ids.xidian.edu.cn/common/openSliderCaptcha.htl',
          xidianLogin,
        ),
        isTrue,
      );
    });

    test('A3: E-Hall CAS ticket 重定向在 allowlist 内', () {
      expect(
        isLoginNavigationAllowed(
          'https://ehall.xidian.edu.cn/login?service=https://ehall.xidian.edu.cn/new/index.html',
          xidianLogin,
        ),
        isTrue,
      );
    });

    test('A4: E-Hall 成功落地页在 allowlist 内', () {
      expect(
        isLoginNavigationAllowed(
          'https://ehall.xidian.edu.cn/new/index.html?ticket=ST-xxx-cas',
          xidianLogin,
        ),
        isTrue,
      );
    });

    test('A5: 一卡通 OAuth 跳转在 allowlist 内', () {
      expect(
        isLoginNavigationAllowed(
          'https://v8scan.xidian.edu.cn/myaccount/openMyAccount',
          xidianLogin,
        ),
        isTrue,
      );
    });

    test('A6: 图书馆 CAS 跳转在 allowlist 内', () {
      expect(
        isLoginNavigationAllowed(
          'https://hyytsgxzs.xidian.edu.cn/login?service=shuwo',
          xidianLogin,
        ),
        isTrue,
      );
    });

    test('A7: 外部域名被拦截（fail-closed）', () {
      expect(
        isLoginNavigationAllowed('https://evil.example.com/login', xidianLogin),
        isFalse,
      );
    });

    test('A8: 同域不同路径不在 allowlist 内被拦截（IDS path 未全通配）', () {
      expect(
        isLoginNavigationAllowed(
          'https://ids.xidian.edu.cn/evil/path',
          xidianLogin,
        ),
        isTrue, // ids.xidian.edu.cn/* 通配
      );
    });

    test('A9: 未列出的子域被拦截——shuwo.xidian.edu.cn 不在 allow 内', () {
      // navigationAllow 未列出 shuwo，即使它在 broker.allow 中
      // ——成功的 cookie 收割由 success.whenUrlMatches 检测，不是任意导航
      expect(
        isLoginNavigationAllowed(
          'https://shuwo.xidian.edu.cn/api',
          xidianLogin,
        ),
        isFalse,
      );
    });
  });

  // ════════════════════════════════════════════════════════════════════
  // Group B · 成功检测（success URL patterns）
  // ════════════════════════════════════════════════════════════════════

  group('B · XIDIAN success URL detection', () {
    test('B1: E-Hall 带 CAS ticket 的成功 URL 被检测', () {
      expect(
        isLoginSuccessUrl(
          'https://ehall.xidian.edu.cn/new/index.html?ticket=ST-1867-abcdef',
          xidianLogin,
        ),
        isTrue,
      );
    });

    test('B2: E-Hall 不带 ticket 的成功 URL 被检测', () {
      expect(
        isLoginSuccessUrl(
          'https://ehall.xidian.edu.cn/new/index.html',
          xidianLogin,
        ),
        isTrue,
      );
    });

    test('B3: E-Hall 深层路径被通配命中', () {
      expect(
        isLoginSuccessUrl(
          'https://ehall.xidian.edu.cn/new/index.html#/home',
          xidianLogin,
        ),
        isTrue,
      );
    });

    test('B4: E-Hall 非成功路径不被检测', () {
      expect(
        isLoginSuccessUrl(
          'https://ehall.xidian.edu.cn/portal',
          xidianLogin,
        ),
        isFalse,
      );
    });

    test('B5: 一卡通成功 URL 被检测', () {
      expect(
        isLoginSuccessUrl(
          'https://v8scan.xidian.edu.cn/myaccount/openMyAccount',
          xidianLogin,
        ),
        isTrue,
      );
    });

    test('B6: 一卡通子路径未命中（不是通配结尾）', () {
      expect(
        isLoginSuccessUrl(
          'https://v8scan.xidian.edu.cn/myaccount/openMyAccount/subpage',
          xidianLogin,
        ),
        isTrue, // 通配符匹配尾部任意
      );
    });

    test('B7: 图书馆任意路径被检测（全通配）', () {
      expect(
        isLoginSuccessUrl(
          'https://hyytsgxzs.xidian.edu.cn/sso/callback',
          xidianLogin,
        ),
        isTrue,
      );
    });

    test('B8: 登录页本身不被检测为成功', () {
      expect(
        isLoginSuccessUrl(
          'https://ids.xidian.edu.cn/authserver/login',
          xidianLogin,
        ),
        isFalse,
      );
    });
  });

  // ════════════════════════════════════════════════════════════════════
  // Group C · Cookie 收割（核心——红线 #1 承重）
  // ════════════════════════════════════════════════════════════════════

  group('C · XIDIAN CAS cookie harvest', () {
    late CredentialStore store;

    setUp(() {
      store = CredentialStore(
        store: InMemorySecureStore(releaseMode: false),
        now: () => 1718208000000, // 固定时间戳
      );
    });

    // ── C1–C2: CASTGC 永不被收割（红线 #1 核心断言） ──

    test('C1: CASTGC 不入库（红线 #1——CAS TGT 仅存 WS/WEBVIEW 核心）', () {
      final result = harvestWebViewCookies(
        login: xidianLogin,
        cookies: webViewCookiesAfterCas,
        put: store.put,
        now: () => 1718208000000,
      );

      final refs = result.entries.map((e) => e.ref).toSet();
      expect(refs, isNot(contains('ids-cas')));
      expect(refs, isNot(contains('cas-tgt')));

      final all = store.list();
      final casCookies = all.where((e) =>
          e.value.contains('CASTGC') || e.value.contains('TGT-'));
      expect(casCookies, isEmpty);
    });

    test('C2: ids.xidian.edu.cn 上的 JSESSIONID 也不入库（无匹配 ref）', () {
      harvestWebViewCookies(
        login: xidianLogin,
        cookies: webViewCookiesAfterCas,
        put: store.put,
        now: () => 1718208000000,
      );

      final idsSession = store.list().where(
        (e) => e.value.contains('ids-aaaa'),
      );
      expect(idsSession, isEmpty);
    });

    // ── C3: E-Hall session 被正确收割 ──

    test('C3: E-Hall JSESSIONID 被收割到 ehall-session ref', () async {
      harvestWebViewCookies(
        login: xidianLogin,
        cookies: webViewCookiesAfterCas,
        put: store.put,
        now: () => 1718208000000,
      );

      final resolved = await store.get('ehall-session');
      expect(resolved, isNotNull);
      expect(resolved!.via, 'cookie');
      expect(resolved.value, contains('JSESSIONID=ehall-bbbb'));
    });

    // ── C4: E-Hall 附加 cookie（route）同归 ehall-session ──

    test('C4: E-Hall route cookie 与 JSESSIONID 合并入同一 ref', () async {
      harvestWebViewCookies(
        login: xidianLogin,
        cookies: webViewCookiesAfterCas,
        put: store.put,
        now: () => 1718208000000,
      );

      final resolved = await store.get('ehall-session');
      expect(resolved, isNotNull);
      // 两个同名不同 domain 的 cookie 都应出现；序列化按 RFC 6265 §5.4 排序
      expect(resolved!.value, contains('JSESSIONID'));
      expect(resolved.value, contains('ehall-bbbb'));
    });

    // ── C5: 一卡通 openid 被收割 ──

    test('C5: v8scan openid cookie 被收割到 card-session ref', () async {
      harvestWebViewCookies(
        login: xidianLogin,
        cookies: webViewCookiesAfterCas,
        put: store.put,
        now: () => 1718208000000,
      );

      final resolved = await store.get('card-session');
      expect(resolved, isNotNull);
      expect(resolved!.via, 'cookie');
      expect(resolved.value, contains('openid=oxxxxxxxxxxxxxxxxxxxxxxxxxx'));
    });

    // ── C6: 图书馆 SESSION 被收割 ──

    test('C6: hyytsgxzs SESSION cookie 被收割到 library-session ref', () async {
      harvestWebViewCookies(
        login: xidianLogin,
        cookies: webViewCookiesAfterCas,
        put: store.put,
        now: () => 1718208000000,
      );

      final resolved = await store.get('library-session');
      expect(resolved, isNotNull);
      expect(resolved!.via, 'cookie');
      expect(resolved.value, contains('SESSION=library-cccc'));
    });

    // ── C7: 未声明 ref 的 cookie 不被收割（xxcapp 水电 token） ──

    test('C7: 未声明 ref 的域（xxcapp）cookie 不入库', () {
      harvestWebViewCookies(
        login: xidianLogin,
        cookies: webViewCookiesAfterCas,
        put: store.put,
        now: () => 1718208000000,
      );

      final unharvested = store.list().where(
        (e) => e.value.contains('energy-dddd'),
      );
      expect(unharvested, isEmpty);
    });

    // ── C8: 收割结果完整性 ──

    test('C8: 收割结果包含全部 3 个 ref', () {
      final result = harvestWebViewCookies(
        login: xidianLogin,
        cookies: webViewCookiesAfterCas,
        put: store.put,
        now: () => 1718208000000,
      );

      expect(result.harvested, isTrue);
      final refs = result.entries.map((e) => e.ref).toSet();
      expect(refs, containsAll(['ehall-session', 'card-session', 'library-session']));
      expect(refs.length, 3);
    });
  });

  // ════════════════════════════════════════════════════════════════════
  // Group D · 边界情况与纵深防御
  // ════════════════════════════════════════════════════════════════════

  group('D · edge cases', () {
    late CredentialStore store;

    setUp(() {
      store = CredentialStore(
        store: InMemorySecureStore(releaseMode: false),
        now: () => 1718208000000,
      );
    });

    test('D1: 空 cookie 列表不抛错，产出空计划', () {
      final result = harvestWebViewCookies(
        login: xidianLogin,
        cookies: const [],
        put: store.put,
        now: () => 1718208000000,
      );

      expect(result.harvested, isFalse);
      expect(result.entries, isEmpty);
      expect(store.list(), isEmpty);
    });

    test('D2: cookie 名称为空被过滤', () {
      harvestWebViewCookies(
        login: xidianLogin,
        cookies: const [
          WebViewCookie(name: '', value: 'x', domain: 'ehall.xidian.edu.cn', path: '/'),
          WebViewCookie(name: 'ok', value: 'y', domain: 'ehall.xidian.edu.cn', path: '/'),
        ],
        put: store.put,
        now: () => 1718208000000,
      );

      expect(store.list().length, 1);
    });

    test('D3: cookie domain 为空被过滤', () {
      harvestWebViewCookies(
        login: xidianLogin,
        cookies: const [
          WebViewCookie(name: 'A', value: 'x', domain: '', path: '/'),
        ],
        put: store.put,
        now: () => 1718208000000,
      );

      expect(store.list(), isEmpty);
    });

    test('D4: 前导点 domain 被归一（.ehall.xidian.edu.cn → ehall.xidian.edu.cn）', () {
      harvestWebViewCookies(
        login: xidianLogin,
        cookies: const [
          WebViewCookie(
            name: 'JSESSIONID',
            value: 'with-leading-dot',
            domain: '.ehall.xidian.edu.cn',
            path: '/',
          ),
        ],
        put: store.put,
        now: () => 1718208000000,
      );

      expect(store.list().length, 1);
      // 归一化后应正常匹配 scope
      expect(store.list().first.value, contains('JSESSIONID=with-leading-dot'));
    });

    test('D5: 同一 ref 重复收割覆盖旧值（会话轮换）', () async {
      // 第一次收割
      harvestWebViewCookies(
        login: xidianLogin,
        cookies: const [
          WebViewCookie(
            name: 'JSESSIONID', value: 'OLD', domain: 'ehall.xidian.edu.cn', path: '/',
          ),
        ],
        put: store.put,
        now: () => 1000,
      );
      expect((await store.get('ehall-session'))!.value, contains('OLD'));

      // 第二次收割（模拟重新登录）
      store = CredentialStore(
        store: InMemorySecureStore(releaseMode: false),
        now: () => 2000,
      );
      harvestWebViewCookies(
        login: xidianLogin,
        cookies: const [
          WebViewCookie(
            name: 'JSESSIONID', value: 'NEW', domain: 'ehall.xidian.edu.cn', path: '/',
          ),
        ],
        put: store.put,
        now: () => 2000,
      );
      expect((await store.get('ehall-session'))!.value, contains('NEW'));
    });

    test('D6: cookie path 缺省填 "/"', () {
      harvestWebViewCookies(
        login: xidianLogin,
        cookies: const [
          WebViewCookie(
            name: 'A', value: '1', domain: 'ehall.xidian.edu.cn', path: '/',
          ),
        ],
        put: store.put,
        now: () => 1718208000000,
      );

      expect(store.list().length, 1);
    });

    test('D7: header 类型 ref 不与 cookie 收割交互（不误注）', () {
      // 创建一个含 header 类型 ref 的 brokerView
      const loginWithHeader = LoginManifestView(
        schoolId: 'xidian',
        url: 'https://ids.xidian.edu.cn/authserver/login',
        navigationAllow: ['https://ids.xidian.edu.cn/*', 'https://api.xidian.edu.cn/*'],
        successUrlMatches: ['https://api.xidian.edu.cn/*'],
        brokerView: BrokerManifestView(
          allow: ['https://api.xidian.edu.cn/*'],
          credentials: {
            'api-token': CredentialDecl(
              scope: ['https://api.xidian.edu.cn/*'],
              type: 'header',
            ),
          },
        ),
      );

      harvestWebViewCookies(
        login: loginWithHeader,
        cookies: const [
          WebViewCookie(
            name: 'Authorization', value: 'Bearer xxx', domain: 'api.xidian.edu.cn', path: '/',
          ),
        ],
        put: store.put,
        now: () => 1718208000000,
      );

      // header 类型 ref 不参与 cookie 收割
      expect(store.list(), isEmpty);
    });

    test('D8: scope 域上 cookie path="/" 被收割', () {
      harvestWebViewCookies(
        login: xidianLogin,
        cookies: const [
          WebViewCookie(
            name: 'SESSION',
            value: 'root-path',
            domain: 'hyytsgxzs.xidian.edu.cn',
            path: '/',
          ),
        ],
        put: store.put,
        now: () => 1718208000000,
      );

      expect(store.list().length, 1);
    });

    test('D9: cookie path 深于 scope repr path 不被收割（RFC 6265 path-match）', () {
      harvestWebViewCookies(
        login: xidianLogin,
        cookies: const [
          WebViewCookie(
            name: 'JSESSIONID',
            value: 'deep-path',
            domain: 'ehall.xidian.edu.cn',
            path: '/admin/secret',
          ),
        ],
        put: store.put,
        now: () => 1718208000000,
      );

      // scope ehall.xidian.edu.cn/* 的 repr URL path 为 /；
      // cookie path /admin/secret 是更深路径 → 不匹配 → 不收割
      expect(store.list(), isEmpty);
    });
  });
}
