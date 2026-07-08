/// 核心托管 WebView 登录页面（ADR-012 §2.2 / ADR-016）。
///
/// 加载学校真实登录页，从 cookie jar 收割 session 写入 CredentialStore。
/// 凭证值只在核心收割路径流转，绝不接触 UI/adapter（红线 #1）。
///
/// 使用方式：
/// ```dart
/// final result = await Navigator.of(context).push<WebViewLoginResult>(
///   MaterialPageRoute(builder: (_) => WebViewLoginPage(login: view, store: store)),
/// );
/// ```
///
/// 🔒 红线 #1 承重路径（WebView cookie → 核心收割 → CredentialStore）：
/// AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/login/webview_login.dart';
import '../../core/credential/store.dart';

enum WebViewLoginStatus { success, cancelled, error }

class WebViewLoginResult {
  const WebViewLoginResult({required this.status, this.error});

  final WebViewLoginStatus status;
  final String? error;
}

class WebViewLoginPage extends StatefulWidget {
  const WebViewLoginPage({
    super.key,
    required this.login,
    required this.store,
    this.tlsProceedHosts = const {},
  });

  final LoginManifestView login;
  final CredentialStore store;

  /// TLS 证书异常放行白名单（host 精确匹配）；仅校园站封闭环境使用。
  final Set<String> tlsProceedHosts;

  @override
  State<WebViewLoginPage> createState() => _WebViewLoginPageState();
}

class _WebViewLoginPageState extends State<WebViewLoginPage> {
  InAppWebViewController? _controller;
  bool _isLoading = true;
  bool _hasHarvested = false;
  String? _errorMessage;

  void _pop(WebViewLoginResult result) {
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  bool _urlAllowed(String url) =>
      isLoginNavigationAllowed(url, widget.login);

  bool _isSuccessUrl(String url) =>
      isLoginSuccessUrl(url, widget.login);

  static String _safeString(dynamic v) => v is String ? v : '';

  Future<void> _harvestCookies(WebUri url) async {
    if (_hasHarvested) return;
    _hasHarvested = true;

    try {
      final cookieManager = CookieManager.instance();
      final rawCookies = await cookieManager.getCookies(url: url);

      final webViewCookies = rawCookies
          .where((c) => c.name.isNotEmpty && (c.domain?.isNotEmpty == true))
          .map((c) => WebViewCookie(
                name: c.name,
                value: _safeString(c.value),
                domain: c.domain!,
                path: c.path ?? '/',
              ))
          .toList();

      final result = harvestWebViewCookies(
        login: widget.login,
        cookies: webViewCookies,
        put: widget.store.put,
        now: () => DateTime.now().millisecondsSinceEpoch,
      );

      debugPrint(
          '[webview-login] harvest done: ${result.entries.map((e) => e.ref).join(", ")}');

      _pop(const WebViewLoginResult(status: WebViewLoginStatus.success));
    } catch (e) {
      debugPrint('[webview-login] harvest error: $e');
      _pop(WebViewLoginResult(
          status: WebViewLoginStatus.error, error: e.toString()));
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _pop(const WebViewLoginResult(status: WebViewLoginStatus.cancelled));
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: '取消登录',
            onPressed: () =>
                _pop(const WebViewLoginResult(status: WebViewLoginStatus.cancelled)),
          ),
          title: const Text('校园登录'),
          actions: [
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
        body: _errorMessage != null ? _ErrorView(error: _errorMessage!) : _buildWebView(),
      ),
    );
  }

  Widget _buildWebView() {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.login.url)),
      initialSettings: InAppWebViewSettings(
        incognito: true,
        javaScriptEnabled: true,
        isInspectable: kDebugMode,
      ),
      onWebViewCreated: (c) => _controller = c,
      onLoadStart: (c, url) {
        if (url != null && !_urlAllowed(url.toString())) {
          c.stopLoading();
          setState(() {
            _isLoading = false;
            _errorMessage = '导航被拦截：$url 不在登录域白名单内。';
          });
        }
      },
      onLoadStop: (c, url) async {
        setState(() => _isLoading = false);
        if (url != null && _isSuccessUrl(url.toString())) {
          await _harvestCookies(url);
        }
      },
      shouldOverrideUrlLoading: (c, action) async {
        final requestedUrl = action.request.url?.toString() ?? '';
        if (!_urlAllowed(requestedUrl)) {
          debugPrint('[webview-login] blocked: $requestedUrl');
          return NavigationActionPolicy.CANCEL;
        }
        return NavigationActionPolicy.ALLOW;
      },
      onReceivedError: (c, req, err) {
        debugPrint('[webview-login] error: ${err.type} ${err.description}');
        setState(() {
          _isLoading = false;
          _errorMessage = err.description;
        });
      },
      onReceivedServerTrustAuthRequest: (c, challenge) async {
        final String host = challenge.protectionSpace.host;
        final bool allowed = widget.tlsProceedHosts.contains(host);
        debugPrint(
            '[webview-login] serverTrustAuth ← $host（${allowed ? "PROCEED" : "CANCEL"}）');
        return ServerTrustAuthResponse(
          action: allowed
              ? ServerTrustAuthResponseAction.PROCEED
              : ServerTrustAuthResponseAction.CANCEL,
        );
      },
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 40, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            const Text('登录页面加载失败'),
            const SizedBox(height: 8),
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                const WebViewLoginResult(status: WebViewLoginStatus.cancelled),
              ),
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }
}
