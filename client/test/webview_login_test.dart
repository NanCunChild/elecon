import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/login/webview_login.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const login = LoginManifestView(
    schoolId: 'xidian',
    url: 'https://ids.xidian.edu.cn/authserver/login',
    navigationAllow: [
      'https://ids.xidian.edu.cn/*',
      'https://ehall.xidian.edu.cn/*',
    ],
    successUrlMatches: ['https://ehall.xidian.edu.cn/new/index.html*'],
    brokerView: BrokerManifestView(
      allow: ['https://ehall.xidian.edu.cn/*'],
      credentials: {
        'ehall-session': CredentialDecl(
          scope: ['https://ehall.xidian.edu.cn/*'],
          type: 'cookie',
        ),
      },
    ),
  );

  test('WebView login navigation is fail-closed by manifest allowlist', () {
    expect(
      isLoginNavigationAllowed(
        'https://ids.xidian.edu.cn/authserver/login',
        login,
      ),
      isTrue,
    );
    expect(
      isLoginNavigationAllowed('https://evil.example/login', login),
      isFalse,
    );
  });

  test('WebView login success URL follows manifest success matcher', () {
    expect(
      isLoginSuccessUrl(
        'https://ehall.xidian.edu.cn/new/index.html?ticket=masked',
        login,
      ),
      isTrue,
    );
    expect(
      isLoginSuccessUrl('https://ehall.xidian.edu.cn/portal', login),
      isFalse,
    );
  });

  test('WebView cookies are harvested only through declared credential refs',
      () async {
    final store = CredentialStore(
      store: InMemorySecureStore(releaseMode: false),
      now: () => 1000,
    );

    final result = harvestWebViewCookies(
      login: login,
      cookies: const [
        WebViewCookie(
          name: 'JSESSIONID',
          value: 'ROTATED',
          domain: 'ehall.xidian.edu.cn',
          path: '/',
        ),
        WebViewCookie(
          name: 'CASTGC',
          value: 'NOT-HARVESTED',
          domain: 'ids.xidian.edu.cn',
          path: '/',
        ),
      ],
      put: store.put,
      now: () => 1000,
    );

    expect(result.entries.map((e) => e.ref), ['ehall-session']);
    final resolved = await store.get('ehall-session');
    expect(resolved?.value, 'JSESSIONID=ROTATED');
    expect(await store.get('ids-cas'), isNull);
  });

  test('planWebViewHarvest 干跑：只判定不写入（页面轮询依据）', () {
    // session cookie 未落定 → 计划为空（轮询继续等）。
    expect(
      planWebViewHarvest(login: login, cookies: const []),
      isEmpty,
    );
    // 落定后 → 计划出现声明 ref；干跑本身不接触任何 store。
    final plan = planWebViewHarvest(
      login: login,
      cookies: const [
        WebViewCookie(
          name: 'JSESSIONID',
          value: 'V',
          domain: 'ehall.xidian.edu.cn',
          path: '/',
        ),
      ],
    );
    expect(plan.map((e) => e.ref), ['ehall-session']);
  });
}
