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
    authEndpoint:
        'https://ids.xidian.edu.cn/authserver/login?service={service}',
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
          plan: plan,
        ),
        MintOutcome.success,
      );
    });

    test('弹回登录页（navAllow 内、非成功页）→ tgcExpired', () {
      expect(
        classifyMintResult(
          finalUrl: 'https://ids.xidian.edu.cn/authserver/login',
          plan: plan,
        ),
        MintOutcome.tgcExpired,
      );
    });

    test('越出 navAllow → blockedOutsideNav', () {
      expect(
        classifyMintResult(finalUrl: 'https://evil.example.com/', plan: plan),
        MintOutcome.blockedOutsideNav,
      );
    });
  });

  group('ADR-017 §2.7 mint forms', () {
    test('缺省按 hidden-webview → headless，并与平台能力求交', () {
      final plan = buildMintPlan(_login, 'card-session')!;
      expect(plan.forms, defaultMintForms);
      expect(
        effectiveMintForms(
          plan,
          const MintPlatformCapabilities({SsoMintForm.headless}),
        ),
        [SsoMintForm.headless],
      );
    });

    test('组合执行器先 hidden，失败后 headless 成功', () async {
      final calls = <String>[];
      final minter = FallbackSsoMinter(
        login: _login,
        platform: const MintPlatformCapabilities({
          SsoMintForm.hiddenWebView,
          SsoMintForm.headless,
        }),
        executors: {
          SsoMintForm.hiddenWebView: _RecordingMinter(
            'hidden',
            MintOutcome.tgcExpired,
            calls,
          ),
          SsoMintForm.headless: _RecordingMinter(
            'headless',
            MintOutcome.success,
            calls,
          ),
        },
      );
      expect(await minter.mint('card-session'), MintOutcome.success);
      expect(calls, ['hidden', 'headless']);
    });
  });
}

class _RecordingMinter implements SsoMinter {
  _RecordingMinter(this.name, this.outcome, this.calls);

  final String name;
  final MintOutcome outcome;
  final List<String> calls;

  @override
  Future<MintOutcome> mint(String targetRef) async {
    calls.add(name);
    return outcome;
  }
}
