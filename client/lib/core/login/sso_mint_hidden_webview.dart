/// 隐藏/离屏 WebView 静默换票执行器（ADR-017 §2.7）。
///
/// 与可见登录共用 [InAppWebViewAuthBridge]，因此导航闭锁、callback 捕获、cookie/query
/// 收割和凭证写入只有一个审计面。浏览器只作为可信核心执行后端，adapter/UI 不参与。
///
/// 🔒 红线 #1：母凭证注入与子凭证收割路径。AI 起草，须 Android/iOS 真机及人工安全审。
library;

import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../broker/ports.dart';
import '../credential/types.dart';
import 'inappwebview_auth_bridge.dart';
import 'sso_mint.dart';
import 'webview_auth_session.dart';
import 'webview_login.dart';

class HiddenWebViewSsoMinter implements SsoMinter {
  HiddenWebViewSsoMinter({
    required this.login,
    required this.resolver,
    required this.putCredential,
    this.timeout = const Duration(seconds: 20),
  });

  final LoginManifestView login;
  final CredentialResolver resolver;
  final void Function(CredentialEntry entry) putCredential;
  final Duration timeout;

  @override
  Future<MintOutcome> mint(String targetRef) async {
    final plan = buildMintPlan(login, targetRef);
    if (plan == null) {
      throw ArgumentError.value(targetRef, 'targetRef', '目标没有 ssoMint 声明');
    }
    if (plan.via != null) return MintOutcome.tgcExpired;

    final masters = login.brokerView.credentials.entries
        .where((entry) => entry.value.role == 'sso-master')
        .toList();
    if (masters.length != 1 || masters.single.value.type != 'cookie') {
      return MintOutcome.blockedOutsideNav;
    }
    final credential = await resolver.get(masters.single.key);
    if (credential == null || credential.via != 'cookie') {
      return MintOutcome.tgcExpired;
    }

    final mintLogin = LoginManifestView(
      schoolId: login.schoolId,
      url: plan.loadUrl,
      navigationAllow: plan.navigationAllow,
      successUrlMatches: plan.successMatches,
      brokerView: login.brokerView,
    );
    final bridge = InAppWebViewAuthBridge(
      login: mintLogin,
      putCredential: putCredential,
      requiredRef: targetRef,
    );
    final started = Completer<void>();
    late final HeadlessInAppWebView webView;
    webView = HeadlessInAppWebView(
      initialSettings: bridge.settings,
      onWebViewCreated: (controller) {
        bridge.onWebViewCreated(controller);
        unawaited(() async {
          try {
            final injected = await bridge.injectCookieHeader(
              credential.value,
              plan.loadUrl,
            );
            if (!injected) {
              bridge.reportPlatformError();
            } else {
              await controller.loadUrl(
                urlRequest: URLRequest(url: WebUri(plan.loadUrl)),
              );
            }
          } catch (_) {
            bridge.reportPlatformError();
          } finally {
            if (!started.isCompleted) started.complete();
          }
        }());
      },
      onLoadStart: bridge.onLoadStart,
      onLoadStop: bridge.onLoadStop,
      onUpdateVisitedHistory: bridge.onUpdateVisitedHistory,
      shouldOverrideUrlLoading: bridge.shouldOverrideUrlLoading,
      onReceivedError: bridge.onReceivedError,
      onReceivedServerTrustAuthRequest: bridge.onReceivedServerTrustAuthRequest,
    );

    try {
      await webView.run();
      await started.future.timeout(timeout);
      final result = await bridge.completion.timeout(timeout);
      return switch (result.status) {
        WebViewLoginStatus.success => MintOutcome.success,
        WebViewLoginStatus.cancelled => MintOutcome.tgcExpired,
        WebViewLoginStatus.error => MintOutcome.tgcExpired,
      };
    } on TimeoutException {
      return MintOutcome.tgcExpired;
    } catch (_) {
      return MintOutcome.blockedOutsideNav;
    } finally {
      bridge.dispose(disposeController: false);
      await webView.dispose();
    }
  }
}
