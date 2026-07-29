/// 🔒 WebView 认证核心状态机安全回归。AI 起草，须人工实质审阅（红线 #1）。
library;

import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/credential/types.dart';
import 'package:elecon/core/login/webview_auth_session.dart';
import 'package:elecon/core/login/webview_login.dart';
import 'package:flutter_test/flutter_test.dart';

const _login = LoginManifestView(
  schoolId: 'fixture-school',
  url: 'https://ids.example.edu/login',
  navigationAllow: ['https://ids.example.edu/*', 'https://app.example.edu/*'],
  successUrlMatches: ['https://app.example.edu/callback*'],
  brokerView: BrokerManifestView(
    allow: ['https://ids.example.edu/*', 'https://app.example.edu/*'],
    credentials: {
      'app-session': CredentialDecl(
        scope: ['https://app.example.edu/*'],
        type: 'query',
        queryParam: 'openid',
      ),
    },
  ),
);

void main() {
  test('UI 状态剥除 callback query，query 凭证仅写核心 store', () async {
    const secret = 'OPENID_SECRET_DO_NOT_LEAK';
    final states = <WebViewAuthUiState>[];
    final entries = <CredentialEntry>[];
    final session = WebViewAuthSession(
      login: _login,
      readCookies: (_) async => const [],
      putCredential: entries.add,
      requiredRef: 'app-session',
      pollInterval: Duration.zero,
      pollDeadline: const Duration(milliseconds: 1),
      onState: states.add,
      now: () => 1,
    );

    await session.handleNavigation(
      'https://app.example.edu/callback?openid=$secret',
      loadStopped: true,
    );
    final result = await session.completion;

    expect(result.status, WebViewLoginStatus.success);
    expect(entries.single.value, secret);
    final exposed = '$states $result';
    expect(exposed, isNot(contains(secret)));
    expect(
      states
          .where((s) => s.location != null)
          .every((s) => !s.location!.contains('?')),
      isTrue,
    );
  });

  test('越界导航 fail-closed，安全状态不含 query', () async {
    final states = <WebViewAuthUiState>[];
    final session = WebViewAuthSession(
      login: _login,
      readCookies: (_) async => const [],
      putCredential: (_) {},
      onState: states.add,
    );

    final allowed = await session.handleNavigation(
      'https://evil.example/path?ticket=ST-SECRET',
      loadStopped: false,
    );
    expect(allowed, isFalse);
    expect(states.single.phase, WebViewAuthPhase.blocked);
    expect(states.single.location, 'https://evil.example/path');
    session.dispose();
  });
}
