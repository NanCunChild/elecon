/// 静默签票纯逻辑测试（ADR-017 PR-3 草案）：规划 + 结果判定。
///
/// 执行器（换票驱动）是人工主导 PR，不在此测；本测覆盖 buildMintPlan / classifyMintResult。
library;

import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/login/sso_mint.dart';
import 'package:elecon/core/login/webview_login.dart';
import 'package:flutter_test/flutter_test.dart';

const _login = LoginManifestView(
  schoolId: 'xidian',
  url: 'https://ids.xidian.edu.cn/authserver/login',
  navigationAllow: [
    'https://ids.xidian.edu.cn/*',
    'https://v8scan.xidian.edu.cn/*',
  ],
  successUrlMatches: ['https://ehall.xidian.edu.cn/new/index.html*'],
  brokerView: BrokerManifestView(allow: [], credentials: {}),
  ssoMint: SsoMintDecl(
    authEndpoint: 'https://ids.xidian.edu.cn/authserver/login?service={service}',
    services: {
      'card-session': SsoMintServiceDecl(
        service: 'https://v8scan.xidian.edu.cn/sso/login',
        success: ['https://v8scan.xidian.edu.cn/myaccount/*'],
      ),
    },
  ),
);

void main() {
  test('buildMintPlan：已声明服务 → 填入 service 并 URL 编码', () {
    final plan = buildMintPlan(_login, 'card-session')!;
    expect(plan.targetRef, 'card-session');
    expect(
      plan.loadUrl,
      'https://ids.xidian.edu.cn/authserver/login?service=${Uri.encodeComponent('https://v8scan.xidian.edu.cn/sso/login')}',
    );
    expect(plan.successMatches, ['https://v8scan.xidian.edu.cn/myaccount/*']);
    expect(plan.via, isNull);
  });

  test('buildMintPlan：未声明 ssoMint / 未知服务 → null（降级可见登录）', () {
    const noMint = LoginManifestView(
      schoolId: 'x',
      url: 'https://ids.x/login',
      navigationAllow: ['https://ids.x/*'],
      successUrlMatches: ['https://ehall.x/*'],
      brokerView: BrokerManifestView(allow: [], credentials: {}),
    );
    expect(buildMintPlan(noMint, 'card-session'), isNull);
    expect(buildMintPlan(_login, 'unknown-ref'), isNull);
  });

  group('classifyMintResult', () {
    final plan = buildMintPlan(_login, 'card-session')!;

    test('抵达成功页 → success', () {
      expect(
        classifyMintResult(
            finalUrl: 'https://v8scan.xidian.edu.cn/myaccount/openMyAccount',
            plan: plan),
        MintOutcome.success,
      );
    });

    test('弹回登录页（navAllow 内、非成功页）→ tgcExpired', () {
      expect(
        classifyMintResult(
            finalUrl: 'https://ids.xidian.edu.cn/authserver/login', plan: plan),
        MintOutcome.tgcExpired,
      );
    });

    test('越出 navAllow → blockedOutsideNav', () {
      expect(
        classifyMintResult(
            finalUrl: 'https://evil.example.com/', plan: plan),
        MintOutcome.blockedOutsideNav,
      );
    });
  });
}
