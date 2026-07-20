/// ensureCredential 闸门单测（mint 闭环 §4.2–4.3）：纯决策 + 阶梯编排。
///
/// 不触凭证值；夹具为假值（红线 #8）。
library;

import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/credential/types.dart';
import 'package:elecon/core/login/ensure_credential.dart';
import 'package:elecon/core/login/sso_mint.dart';
import 'package:elecon/core/login/webview_login.dart';
import 'package:flutter_test/flutter_test.dart';

const _fake = 'TEST-SESSION-not-a-real-credential';

const _login = LoginManifestView(
  schoolId: 'xidian',
  url: 'https://ids.xidian.edu.cn/authserver/login',
  navigationAllow: [
    'https://ids.xidian.edu.cn/*',
    'https://ehall.xidian.edu.cn/*',
  ],
  successUrlMatches: ['https://ehall.xidian.edu.cn/new/index.html*'],
  brokerView: BrokerManifestView(allow: [], credentials: {}),
  ssoMint: SsoMintDecl(
    authEndpoint: 'https://ids.xidian.edu.cn/authserver/login?service={service}',
    services: {
      'ehall-session': SsoMintServiceDecl(
        service: 'https://ehall.xidian.edu.cn/login',
        success: ['https://ehall.xidian.edu.cn/new/index.html*'],
      ),
    },
  ),
);

const _loginNoMint = LoginManifestView(
  schoolId: 'xidian',
  url: 'https://ids.xidian.edu.cn/authserver/login',
  navigationAllow: ['https://ids.xidian.edu.cn/*'],
  successUrlMatches: ['https://ehall.xidian.edu.cn/*'],
  brokerView: BrokerManifestView(allow: [], credentials: {}),
);

CredentialEntry _entry({
  required String ref,
  String schoolId = 'xidian',
  CredentialSensitivity sensitivity = CredentialSensitivity.standard,
  CredentialStatus status = CredentialStatus.active,
  int? expiresAt,
}) =>
    CredentialEntry(
      ref: ref,
      schoolId: schoolId,
      type: 'cookie',
      scope: const ['https://example.edu/*'],
      value: _fake,
      acquiredAt: 1000,
      expiresAt: expiresAt,
      status: status,
      sensitivity: sensitivity,
    );

class _FakeMinter implements SsoMinter {
  _FakeMinter(this.outcome, {this.onMint});
  MintOutcome outcome;
  final void Function(String ref)? onMint;
  final calls = <String>[];

  @override
  Future<MintOutcome> mint(String targetRef) async {
    calls.add(targetRef);
    onMint?.call(targetRef);
    return outcome;
  }
}

void main() {
  group('decideEnsureAction', () {
    test('已有目标 → alreadyReady', () {
      expect(
        decideEnsureAction(
          hasTarget: true,
          hasMintPlan: true,
          hasMaster: true,
        ),
        EnsureAction.alreadyReady,
      );
    });

    test('缺目标 + mint + 母票 → tryMint', () {
      expect(
        decideEnsureAction(
          hasTarget: false,
          hasMintPlan: true,
          hasMaster: true,
        ),
        EnsureAction.tryMint,
      );
    });

    test('缺目标 + 无 mint / 无母票 → visibleLogin', () {
      expect(
        decideEnsureAction(
          hasTarget: false,
          hasMintPlan: false,
          hasMaster: true,
        ),
        EnsureAction.visibleLogin,
      );
      expect(
        decideEnsureAction(
          hasTarget: false,
          hasMintPlan: true,
          hasMaster: false,
        ),
        EnsureAction.visibleLogin,
      );
    });
  });

  group('CredentialStore.hasActive / hasActiveSsoMaster', () {
    test('active 且同校 → true；他校 / 过期 / 吊销 → false', () {
      final store = CredentialStore(now: () => 10000);
      store.put(_entry(ref: 'ehall-session'));
      expect(
        store.hasActive(schoolId: 'xidian', ref: 'ehall-session'),
        isTrue,
      );
      expect(
        store.hasActive(schoolId: 'other', ref: 'ehall-session'),
        isFalse,
      );
      expect(store.hasActive(schoolId: 'xidian', ref: 'missing'), isFalse);

      store.put(_entry(ref: 'exp', expiresAt: 9000));
      expect(store.hasActive(schoolId: 'xidian', ref: 'exp'), isFalse);

      store.put(_entry(ref: 'rev', status: CredentialStatus.revoked));
      expect(store.hasActive(schoolId: 'xidian', ref: 'rev'), isFalse);
    });

    test('master 敏感度 → hasActiveSsoMaster', () {
      final store = CredentialStore(now: () => 10000);
      expect(store.hasActiveSsoMaster('xidian'), isFalse);
      store.put(_entry(ref: 'ehall-session'));
      expect(store.hasActiveSsoMaster('xidian'), isFalse);
      store.put(
        _entry(ref: 'ids-cas', sensitivity: CredentialSensitivity.master),
      );
      expect(store.hasActiveSsoMaster('xidian'), isTrue);
      expect(store.hasActiveSsoMaster('other'), isFalse);
    });
  });

  group('ensureCredential', () {
    late CredentialStore store;

    setUp(() {
      store = CredentialStore(now: () => 10000);
    });

    bool hasActive(String sid, String ref) =>
        store.hasActive(schoolId: sid, ref: ref);
    bool hasMaster(String sid) => store.hasActiveSsoMaster(sid);

    test('已有 active ref → ready，不调 mint/登录', () async {
      store.put(_entry(ref: 'ehall-session'));
      final minter = _FakeMinter(MintOutcome.success);
      var loginCalls = 0;
      final r = await ensureCredential(
        schoolId: 'xidian',
        ref: 'ehall-session',
        hasActive: hasActive,
        hasSsoMaster: hasMaster,
        login: _login,
        minter: minter,
        onVisibleLogin: (_) async {
          loginCalls++;
          return true;
        },
      );
      expect(r.isReady, isTrue);
      expect(minter.calls, isEmpty);
      expect(loginCalls, 0);
    });

    test('缺目标 + 母票 + mint success 并收割 → ready', () async {
      store.put(
        _entry(ref: 'ids-cas', sensitivity: CredentialSensitivity.master),
      );
      final minter = _FakeMinter(
        MintOutcome.success,
        onMint: (_) {
          store.put(_entry(ref: 'ehall-session'));
        },
      );
      final r = await ensureCredential(
        schoolId: 'xidian',
        ref: 'ehall-session',
        hasActive: hasActive,
        hasSsoMaster: hasMaster,
        login: _login,
        minter: minter,
      );
      expect(r.isReady, isTrue);
      expect(minter.calls, ['ehall-session']);
    });

    test('mint tgcExpired → 降级可见登录；无回调 → needVisibleLogin', () async {
      store.put(
        _entry(ref: 'ids-cas', sensitivity: CredentialSensitivity.master),
      );
      final minter = _FakeMinter(MintOutcome.tgcExpired);
      final r = await ensureCredential(
        schoolId: 'xidian',
        ref: 'ehall-session',
        hasActive: hasActive,
        hasSsoMaster: hasMaster,
        login: _login,
        minter: minter,
      );
      expect(r.status, EnsureCredentialStatus.needVisibleLogin);
      expect(r.targetRef, 'ehall-session');
      expect(r.reason, contains('母凭证'));
    });

    test('mint 失败 + 可见登录成功并收割 → ready', () async {
      store.put(
        _entry(ref: 'ids-cas', sensitivity: CredentialSensitivity.master),
      );
      final minter = _FakeMinter(MintOutcome.tgcExpired);
      final r = await ensureCredential(
        schoolId: 'xidian',
        ref: 'ehall-session',
        hasActive: hasActive,
        hasSsoMaster: hasMaster,
        login: _login,
        minter: minter,
        onVisibleLogin: (req) async {
          expect(req.serviceUrl, 'https://ehall.xidian.edu.cn/login');
          expect(req.targetRef, 'ehall-session');
          store.put(_entry(ref: 'ehall-session'));
          return true;
        },
      );
      expect(r.isReady, isTrue);
    });

    test('无母票 + 有 mint 计划 → 直接可见登录（不调 mint）', () async {
      final minter = _FakeMinter(MintOutcome.success);
      final r = await ensureCredential(
        schoolId: 'xidian',
        ref: 'ehall-session',
        hasActive: hasActive,
        hasSsoMaster: hasMaster,
        login: _login,
        minter: minter,
      );
      expect(minter.calls, isEmpty);
      expect(r.status, EnsureCredentialStatus.needVisibleLogin);
    });

    test('无 ssoMint 声明 → 直接可见登录', () async {
      final minter = _FakeMinter(MintOutcome.success);
      store.put(
        _entry(ref: 'ids-cas', sensitivity: CredentialSensitivity.master),
      );
      final r = await ensureCredential(
        schoolId: 'xidian',
        ref: 'ehall-session',
        hasActive: hasActive,
        hasSsoMaster: hasMaster,
        login: _loginNoMint,
        minter: minter,
      );
      expect(minter.calls, isEmpty);
      expect(r.status, EnsureCredentialStatus.needVisibleLogin);
    });

    test('可见登录用户取消 → failed', () async {
      final r = await ensureCredential(
        schoolId: 'xidian',
        ref: 'ehall-session',
        hasActive: hasActive,
        hasSsoMaster: hasMaster,
        login: _login,
        onVisibleLogin: (_) async => false,
      );
      expect(r.status, EnsureCredentialStatus.failed);
      expect(r.reason, contains('取消'));
    });

    test('可见登录成功但未收割目标 → needVisibleLogin', () async {
      final r = await ensureCredential(
        schoolId: 'xidian',
        ref: 'ehall-session',
        hasActive: hasActive,
        hasSsoMaster: hasMaster,
        login: _login,
        onVisibleLogin: (_) async => true,
      );
      expect(r.status, EnsureCredentialStatus.needVisibleLogin);
      expect(r.reason, contains('仍缺少'));
    });
  });

  group('ensureCredentials 串行', () {
    test('多 ref：首个失败短路', () async {
      final store = CredentialStore(now: () => 10000);
      final minter = _FakeMinter(MintOutcome.tgcExpired);
      store.put(
        _entry(ref: 'ids-cas', sensitivity: CredentialSensitivity.master),
      );
      final r = await ensureCredentials(
        schoolId: 'xidian',
        refs: ['ehall-session', 'card-session'],
        hasActive: (s, r) => store.hasActive(schoolId: s, ref: r),
        hasSsoMaster: store.hasActiveSsoMaster,
        login: _login,
        minter: minter,
      );
      expect(r.isReady, isFalse);
      expect(minter.calls, ['ehall-session']); // 未跑 card
    });

    test('多 ref：全部已有 → ready', () async {
      final store = CredentialStore(now: () => 10000);
      store.put(_entry(ref: 'ehall-session'));
      store.put(_entry(ref: 'card-session'));
      final r = await ensureCredentials(
        schoolId: 'xidian',
        refs: ['ehall-session', 'card-session'],
        hasActive: (s, r) => store.hasActive(schoolId: s, ref: r),
        hasSsoMaster: store.hasActiveSsoMaster,
        login: _login,
      );
      expect(r.isReady, isTrue);
    });
  });
}
