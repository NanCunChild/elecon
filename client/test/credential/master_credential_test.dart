/// CAS 母凭证收割 + 能力注入边界测试（ADR-017 §2.1 / §2.4）。
///
/// - 收割：跨子域 cookie（CASTGC 在 ids 子域、下游 session 在 ehall 子域）按声明
///   ref 各归其位；母凭证登记 sensitivity=master。
/// - 能力边界：母凭证只对 CAS 认证域注入，**绝不**随下游数据请求外注（红线 #1）。
library;

import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/credential/types.dart';
import 'package:elecon/core/login/webview_login.dart';
import 'package:flutter_test/flutter_test.dart';

const _brokerView = BrokerManifestView(
  allow: [
    'https://ids.xidian.edu.cn/*',
    'https://ehall.xidian.edu.cn/*',
  ],
  credentials: {
    'ids-cas': CredentialDecl(
      scope: ['https://ids.xidian.edu.cn/*'],
      type: 'cookie',
      role: 'sso-master',
    ),
    'ehall-session': CredentialDecl(
      scope: ['https://ehall.xidian.edu.cn/*'],
      type: 'cookie',
    ),
  },
);

const _login = LoginManifestView(
  schoolId: 'xidian',
  url: 'https://ids.xidian.edu.cn/authserver/login',
  navigationAllow: [
    'https://ids.xidian.edu.cn/*',
    'https://ehall.xidian.edu.cn/*',
  ],
  successUrlMatches: ['https://ehall.xidian.edu.cn/new/index.html*'],
  brokerView: _brokerView,
);

void main() {
  test('跨子域收割：CASTGC 归 ids-cas（master），ehall session 归 ehall-session', () {
    final captured = <String, CredentialEntry>{};
    harvestWebViewCookies(
      login: _login,
      cookies: const [
        WebViewCookie(
          name: 'CASTGC',
          value: 'TGT-9001-abc',
          domain: 'ids.xidian.edu.cn',
          path: '/',
        ),
        WebViewCookie(
          name: 'MOD_AUTH_CAS',
          value: 'ST-7-xyz',
          domain: 'ehall.xidian.edu.cn',
          path: '/',
        ),
      ],
      put: (e) => captured[e.ref] = e,
      now: () => 1000,
    );

    expect(captured.keys.toSet(), {'ids-cas', 'ehall-session'});
    expect(captured['ids-cas']!.sensitivity, CredentialSensitivity.master);
    expect(captured['ids-cas']!.value, contains('TGT-9001-abc'));
    expect(
        captured['ehall-session']!.sensitivity, CredentialSensitivity.standard);
  });

  test('harvestCookieOrigins 枚举全部声明域（含 ids 母凭证域）', () {
    expect(harvestCookieOrigins(_login), {
      'https://ids.xidian.edu.cn/',
      'https://ehall.xidian.edu.cn/',
    });
  });

  test('能力边界：数据请求（ehall）注入下游 session，绝不注入母凭证', () {
    final d = decideInjection(
        'https://ehall.xidian.edu.cn/appShow?appId=1', _brokerView);
    expect(d, isA<InjectDecision>());
    expect((d as InjectDecision).ref, 'ehall-session');
    expect(d.ref, isNot('ids-cas'), reason: '母凭证不得随数据请求外注（ADR-017 §2.4）');
  });

  test('母凭证只对 CAS 认证域注入', () {
    final d = decideInjection(
        'https://ids.xidian.edu.cn/authserver/login?service=x', _brokerView);
    expect(d, isA<InjectDecision>());
    expect((d as InjectDecision).ref, 'ids-cas');
  });
}
