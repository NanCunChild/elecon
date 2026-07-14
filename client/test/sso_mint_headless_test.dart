/// CAS 静默换票 headless 执行体测试（ADR-017 §2.2 路线 b · PR-3，草案）。
///
/// 用 fake Transport 模拟 CAS 换票链（authserver/login?service → ?ticket=ST → 目标服务
/// Set-Cookie → 成功页），断言：
///   - 母凭证只注入 CAS 端点，**不**外泄到下游目标域（红线 #1 / §2.4）；
///   - 下游目标域换票期间 passthrough（不因目标 session 尚未印发而 fail-closed）；
///   - 印发成功 → 新 session 收割入库（判据 b），母凭证不被误收；
///   - 母票失效 / 母凭证缺失 / 越界 → 对应降级 outcome（调用方降级可见登录）。
///
/// 🔒 红线 #1 承重路径 + 协议模拟合规灰度：本测试与被测执行体均 AI 起草，须人工 + 安全清单复核。
///
///   运行：cd client && fvm flutter test test/sso_mint_headless_test.dart
library;

import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/broker/fetch_proxy.dart';
import 'package:elecon/core/broker/ports.dart';
import 'package:elecon/core/credential/types.dart';
import 'package:elecon/core/login/sso_mint.dart';
import 'package:elecon/core/login/sso_mint_headless.dart';
import 'package:elecon/core/login/webview_login.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

// —— 共享夹具：XIDIAN 风格 CAS，母凭证 ids-cas 换 v8scan 一卡通 session。——
const _idsAuth = 'https://ids.xidian.edu.cn/authserver/login';
const _cardService = 'https://v8scan.xidian.edu.cn/sso/login';
const _cardSuccess = 'https://v8scan.xidian.edu.cn/myaccount/home';

BrokerManifestView _brokerView() => const BrokerManifestView(
      allow: [
        'https://ids.xidian.edu.cn/*',
        'https://v8scan.xidian.edu.cn/*',
      ],
      credentials: {
        'ids-cas': CredentialDecl(
          scope: ['https://ids.xidian.edu.cn/*'],
          type: 'cookie',
          role: 'sso-master',
        ),
        'card-session': CredentialDecl(
          scope: ['https://v8scan.xidian.edu.cn/*'],
          type: 'cookie',
        ),
      },
    );

LoginManifestView _login() => LoginManifestView(
      schoolId: 'xidian',
      url: _idsAuth,
      navigationAllow: const [
        'https://ids.xidian.edu.cn/*',
        'https://v8scan.xidian.edu.cn/*',
      ],
      successUrlMatches: const ['https://ehall.xidian.edu.cn/*'],
      brokerView: _brokerView(),
      ssoMint: const SsoMintDecl(
        authEndpoint: '$_idsAuth?service={service}',
        services: {
          'card-session': SsoMintServiceDecl(
            service: _cardService,
            success: ['https://v8scan.xidian.edu.cn/myaccount/*'],
          ),
        },
      ),
    );

HeadlessSsoMinter _minter(
  FakeTransport transport, {
  required List<CredentialEntry> harvested,
  Map<String, ResolvedCredential>? creds,
}) =>
    HeadlessSsoMinter(
      login: _login(),
      brokerView: _brokerView(),
      resolver: FakeResolver(
        creds ??
            {'ids-cas': const ResolvedCredential(via: 'cookie', value: 'CASTGC=TGC-1')},
      ),
      transport: transport,
      putCredential: harvested.add,
      schoolId: 'xidian',
      now: () => 1000,
    );

void main() {
  group('HeadlessSsoMinter.mint（fake transport，ADR-017 §2.2 路线 b）', () {
    test('印发成功：母凭证只注入 CAS 端点、下游 passthrough、新 session 入库', () async {
      final transport = FakeTransport([
        // hop1：CAS 端点，注入母凭证 → 302 到 ?ticket=ST
        const TransportResponse(
          status: 302,
          location: 'https://v8scan.xidian.edu.cn/sso/login?ticket=ST-abc',
        ),
        // hop2：下游服务校验 ST → Set-Cookie 下游 session → 302 到成功页
        const TransportResponse(
          status: 302,
          location: _cardSuccess,
          setCookie: ['V8SESSION=sess-xyz; Path=/'],
        ),
        // hop3：成功页 200
        const TransportResponse(status: 200, body: 'ok'),
      ]);
      final harvested = <CredentialEntry>[];
      final outcome = await _minter(transport, harvested: harvested).mint('card-session');

      expect(outcome, MintOutcome.success);

      // ① 母凭证只注入 CAS 端点（hop1 带 CASTGC）。
      expect(transport.seen[0].url, startsWith(_idsAuth));
      expect(transport.seen[0].headers['Cookie'], 'CASTGC=TGC-1');
      // ② 红线 #1 / §2.4：母凭证**绝不**外泄到下游目标域（hop2/hop3 无 CASTGC）。
      expect(transport.seen[1].url, contains('v8scan.xidian.edu.cn'));
      expect(transport.seen[1].headers['Cookie'] ?? '', isNot(contains('CASTGC')));
      expect(transport.seen[2].headers['Cookie'] ?? '', isNot(contains('CASTGC')));

      // ③ 印发→存储：仅目标 session 入库，敏感度 standard；母凭证未被误收。
      expect(harvested, hasLength(1));
      expect(harvested.single.ref, 'card-session');
      expect(harvested.single.value, 'V8SESSION=sess-xyz');
      expect(harvested.single.sensitivity, CredentialSensitivity.standard);
      expect(harvested.single.schoolId, 'xidian');
    });

    test('母票失效：换票 302 弹回 CAS 登录页（未达成功页）→ tgcExpired，不入库', () async {
      final transport = FakeTransport([
        // TGC 过期：CAS 不签 ST，直接回登录页（仍在 navAllow 的 ids 域）
        const TransportResponse(
          status: 302,
          location: '$_idsAuth?service=$_cardService',
        ),
        const TransportResponse(status: 200, body: 'login form'),
      ]);
      final harvested = <CredentialEntry>[];
      final outcome = await _minter(transport, harvested: harvested).mint('card-session');

      expect(outcome, MintOutcome.tgcExpired);
      expect(harvested, isEmpty);
    });

    test('母凭证缺失（resolver 无值）→ fail-closed 映射为 tgcExpired，零下游出网', () async {
      final transport = FakeTransport([]); // 不应发出任何请求
      final harvested = <CredentialEntry>[];
      final outcome = await _minter(
        transport,
        harvested: harvested,
        creds: const {}, // 无 ids-cas
      ).mint('card-session');

      expect(outcome, MintOutcome.tgcExpired);
      expect(transport.seen, isEmpty);
      expect(harvested, isEmpty);
    });

    test('未声明的目标 ref → ArgumentError（调用方应先 buildMintPlan 判定）', () async {
      final transport = FakeTransport([]);
      await expectLater(
        _minter(transport, harvested: []).mint('unknown-ref'),
        throwsArgumentError,
      );
    });

    test('via（adapter mint 能力）尚未实现 → UnimplementedError', () async {
      final login = LoginManifestView(
        schoolId: 'xidian',
        url: _idsAuth,
        navigationAllow: const ['https://ids.xidian.edu.cn/*'],
        successUrlMatches: const [],
        brokerView: _brokerView(),
        ssoMint: const SsoMintDecl(
          authEndpoint: '$_idsAuth?service={service}',
          services: {
            'card-session': SsoMintServiceDecl(
              service: _cardService,
              success: ['https://v8scan.xidian.edu.cn/myaccount/*'],
              via: 'xidian-card-mint',
            ),
          },
        ),
      );
      final minter = HeadlessSsoMinter(
        login: login,
        brokerView: _brokerView(),
        resolver: FakeResolver(
          {'ids-cas': const ResolvedCredential(via: 'cookie', value: 'CASTGC=TGC-1')},
        ),
        transport: FakeTransport([]),
        putCredential: (_) {},
        schoolId: 'xidian',
      );
      await expectLater(minter.mint('card-session'), throwsUnimplementedError);
    });
  });
}
