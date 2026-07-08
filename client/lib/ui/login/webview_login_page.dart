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
/// 调试模式：设置 [debugLog] 为 true 可在页面内查看带时间戳的日志面板，
/// 便于在真机上观察导航、拦截、收割全流程。cookie 值自动打码。
///
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
    this.debugLog = false,
  });

  final LoginManifestView login;
  final CredentialStore store;

  /// TLS 证书异常放行白名单（host 精确匹配）；仅校园站封闭环境使用。
  final Set<String> tlsProceedHosts;

  /// 开启后页面底部展示实时日志面板（cookie 值自动打码）。
  final bool debugLog;

  @override
  State<WebViewLoginPage> createState() => _WebViewLoginPageState();
}

class _LogEntry {
  _LogEntry(this.timestamp, this.message);
  final String timestamp;
  final String message;
}

class _WebViewLoginPageState extends State<WebViewLoginPage> {
  InAppWebViewController? _controller;
  bool _isLoading = true;
  bool _hasHarvested = false;
  String? _errorMessage;
  final List<_LogEntry> _log = <_LogEntry>[];
  bool _showLog = false;

  void _pop(WebViewLoginResult result) {
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  void _addLog(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    debugPrint('[webview-login] $message');
    if (widget.debugLog) {
      setState(() => _log.insert(0, _LogEntry(ts, message)));
    }
  }

  String _maskCookies(List<Cookie> cookies) {
    if (cookies.isEmpty) return '(空)';
    return cookies
        .map((c) => '${c.name}=<${(_safeString(c.value).length)}B>')
        .join('; ');
  }

  bool _urlAllowed(String url) =>
      isLoginNavigationAllowed(url, widget.login);

  bool _isSuccessUrl(String url) => isLoginSuccessUrl(url, widget.login);

  static String _safeString(dynamic v) => v is String ? v : '';

  Future<void> _harvestCookies(WebUri url) async {
    if (_hasHarvested) return;
    _hasHarvested = true;
    _addLog('收割开始 ← ${url.host}');

    try {
      final cookieManager = CookieManager.instance();
      final rawCookies = await cookieManager.getCookies(url: url);
      _addLog('getCookies → ${rawCookies.length} 条：${_maskCookies(rawCookies)}');

      final webViewCookies = rawCookies
          .where((c) => c.name.isNotEmpty && (c.domain?.isNotEmpty == true))
          .map((c) => WebViewCookie(
                name: c.name,
                value: _safeString(c.value),
                domain: c.domain!,
                path: c.path ?? '/',
              ))
          .toList();
      _addLog('有效 cookie：${webViewCookies.length} 条');

      final result = harvestWebViewCookies(
        login: widget.login,
        cookies: webViewCookies,
        put: widget.store.put,
        now: () => DateTime.now().millisecondsSinceEpoch,
      );

      final refs = result.entries.map((e) => e.ref).join(', ');
      _addLog('收割完成：ref=[$refs] | harvested=${result.harvested}');

      _pop(const WebViewLoginResult(status: WebViewLoginStatus.success));
    } catch (e) {
      _addLog('收割失败：$e');
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
            if (widget.debugLog)
              IconButton(
                icon: Icon(_showLog ? Icons.bug_report : Icons.bug_report_outlined),
                tooltip: '日志',
                onPressed: () => setState(() => _showLog = !_showLog),
              ),
          ],
        ),
        body: _errorMessage != null
            ? _ErrorView(error: _errorMessage!)
            : _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    final webView = _buildWebView();
    if (!widget.debugLog || !_showLog) return webView;

    return Column(
      children: [
        Expanded(flex: 3, child: webView),
        const Divider(height: 1),
        Expanded(flex: 2, child: _buildLogPanel()),
      ],
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
      onWebViewCreated: (c) {
        _controller = c;
        _addLog('WebView created | incognito=true');
      },
      onLoadStart: (c, url) {
        _addLog('LoadStart ← $url');
        if (url != null && !_urlAllowed(url.toString())) {
          c.stopLoading();
          _addLog('拦截（不在 allowlist）：$url');
          setState(() {
            _isLoading = false;
            _errorMessage = '导航被拦截：$url 不在登录域白名单内。';
          });
        }
      },
      onLoadStop: (c, url) async {
        setState(() => _isLoading = false);
        final urlStr = url?.toString() ?? '';
        final isSuccess = url != null && _isSuccessUrl(urlStr);
        _addLog('LoadStop ← $urlStr${isSuccess ? " ★成功匹配" : ""}');
        if (isSuccess) {
          await _harvestCookies(url);
        }
      },
      shouldOverrideUrlLoading: (c, action) async {
        final requestedUrl = action.request.url?.toString() ?? '';
        final isMain = action.isForMainFrame;
        _addLog('NavIntent → $requestedUrl${isMain ? " (main)" : " (sub)"}');
        if (!_urlAllowed(requestedUrl)) {
          _addLog('拦截（allowlist）：$requestedUrl');
          return NavigationActionPolicy.CANCEL;
        }
        return NavigationActionPolicy.ALLOW;
      },
      onReceivedError: (c, req, err) {
        _addLog('WebViewError | type=${err.type} | ${err.description}');
        setState(() {
          _isLoading = false;
          _errorMessage = err.description;
        });
      },
      onReceivedServerTrustAuthRequest: (c, challenge) async {
        final String host = challenge.protectionSpace.host;
        final bool allowed = widget.tlsProceedHosts.contains(host);
        _addLog('TLS ← $host → ${allowed ? "PROCEED" : "CANCEL"}');
        return ServerTrustAuthResponse(
          action: allowed
              ? ServerTrustAuthResponseAction.PROCEED
              : ServerTrustAuthResponseAction.CANCEL,
        );
      },
    );
  }

  Widget _buildLogPanel() {
    return Container(
      color: const Color(0xFF0E1116),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                const Text('日志（cookie 值已打码）',
                    style: TextStyle(color: Colors.white60, fontSize: 12)),
                const Spacer(),
                Text('${_log.length} 条',
                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => setState(_log.clear),
                  child: const Icon(Icons.delete_sweep,
                      color: Colors.white38, size: 16),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: _log.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${_log[i].timestamp} ',
                        style: const TextStyle(
                          color: Colors.white38,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                      TextSpan(
                        text: _log[i].message,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
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
