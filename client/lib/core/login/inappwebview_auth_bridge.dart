/// flutter_inappwebview 与认证核心状态机的可信桥（ADR-016 §2.1）。
///
/// 插件 cookie 与原始导航 URL 从这里直接进入 [WebViewAuthSession]，不经过 Widget 状态。
///
/// 🔒 红线 #1：本桥可见浏览器 cookie。AI 起草，须 Android/iOS 真机与人工安全复核。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../credential/types.dart';
import 'webview_auth_session.dart';
import 'webview_login.dart';

class InAppWebViewAuthBridge {
  InAppWebViewAuthBridge({
    required LoginManifestView login,
    required void Function(CredentialEntry entry) putCredential,
    String? initialUrl,
    String? requiredRef,
    Set<String> tlsProceedHosts = const {},
  }) : initialUrl = initialUrl ?? login.url,
       _login = login,
       _tlsProceedHosts = tlsProceedHosts {
    session = WebViewAuthSession(
      login: login,
      readCookies: _readCookies,
      putCredential: putCredential,
      requiredRef: requiredRef,
      onState: stateNotifier.call,
    );
  }

  final String initialUrl;
  final LoginManifestView _login;
  final Set<String> _tlsProceedHosts;
  final ValueNotifier<WebViewAuthUiState> state = ValueNotifier(
    const WebViewAuthUiState(phase: WebViewAuthPhase.loading),
  );
  late final WebViewAuthSession session;
  InAppWebViewController? _controller;

  void stateNotifier(WebViewAuthUiState next) => state.value = next;

  InAppWebViewSettings get settings => InAppWebViewSettings(
    incognito: true,
    javaScriptEnabled: true,
    isInspectable: kDebugMode,
    useShouldOverrideUrlLoading: true,
  );

  Future<List<WebViewCookie>> _readCookies(String currentUrl) async {
    final manager = CookieManager.instance();
    final current = WebUri(currentUrl);
    final origins = <WebUri>{
      current,
      ...harvestCookieOrigins(_login).map(WebUri.new),
    };
    final cookies = <WebViewCookie>[];
    final seen = <String>{};
    for (final origin in origins) {
      final raw = await manager.getCookies(
        url: origin,
        webViewController: _controller,
      );
      for (final cookie in raw) {
        if (cookie.name.isEmpty) continue;
        // 部分 Android WebView 不上报 domain/path；getCookies(origin) 已限定适用范围，
        // 以查询 host/path 作保守归属，避免把 cookie 扩到父域（ADR-012 §3.2）。
        final domain = cookie.domain?.isNotEmpty == true
            ? cookie.domain!
            : origin.host;
        final path = cookie.path?.isNotEmpty == true ? cookie.path! : '/';
        final key = '${cookie.name}|$domain|$path';
        if (!seen.add(key)) continue;
        cookies.add(
          WebViewCookie(
            name: cookie.name,
            value: cookie.value is String ? cookie.value as String : '',
            domain: domain,
            path: path,
            isHttpOnly: cookie.isHttpOnly,
            isSecure: cookie.isSecure,
          ),
        );
      }
    }
    return cookies;
  }

  void onWebViewCreated(InAppWebViewController controller) {
    _controller = controller;
  }

  /// 将核心库中的 cookie header 注入本认证 WebView。调用方和本桥均属于可信核心；
  /// header 不得传入 Widget、日志或 adapter（ADR-017 §2.4，红线 #1）。
  Future<bool> injectCookieHeader(String header, String targetUrl) async {
    final target = WebUri(targetUrl);
    var injected = false;
    for (final segment in header.split(';')) {
      final part = segment.trim();
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      final name = part.substring(0, separator).trim();
      final value = part.substring(separator + 1);
      if (name.isEmpty) continue;
      final ok = await CookieManager.instance().setCookie(
        url: target,
        name: name,
        value: value,
        path: '/',
        domain: target.host,
        isSecure: target.scheme == 'https',
        webViewController: _controller,
      );
      injected = injected || ok;
    }
    return injected;
  }

  Future<void> onLoadStart(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    final allowed = await session.handleNavigation(
      url?.toString(),
      loadStopped: false,
    );
    if (!allowed) await controller.stopLoading();
  }

  Future<void> onLoadStop(InAppWebViewController controller, WebUri? url) =>
      session.handleNavigation(url?.toString(), loadStopped: true);

  Future<void> onUpdateVisitedHistory(
    InAppWebViewController controller,
    WebUri? url,
    bool? isReload,
  ) => session.handleNavigation(url?.toString(), loadStopped: false);

  Future<NavigationActionPolicy?> shouldOverrideUrlLoading(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    if (action.isForMainFrame == false) return NavigationActionPolicy.ALLOW;
    final allowed = await session.handleNavigation(
      action.request.url?.toString(),
      loadStopped: false,
    );
    return allowed
        ? NavigationActionPolicy.ALLOW
        : NavigationActionPolicy.CANCEL;
  }

  void onReceivedError(
    InAppWebViewController controller,
    WebResourceRequest request,
    WebResourceError error,
  ) {
    if (request.isForMainFrame == false) return;
    session.platformError();
  }

  Future<ServerTrustAuthResponse?> onReceivedServerTrustAuthRequest(
    InAppWebViewController controller,
    URLAuthenticationChallenge challenge,
  ) async {
    final host = challenge.protectionSpace.host;
    final allowed = kDebugMode && _tlsProceedHosts.contains(host);
    return ServerTrustAuthResponse(
      action: allowed
          ? ServerTrustAuthResponseAction.PROCEED
          : ServerTrustAuthResponseAction.CANCEL,
    );
  }

  Future<WebViewLoginResult> get completion => session.completion;

  Future<void> stop() async {
    session.cancel();
    await _controller?.stopLoading();
  }

  void dispose({bool disposeController = true}) {
    session.dispose();
    if (disposeController) _controller?.dispose();
    _controller = null;
    state.dispose();
  }
}
