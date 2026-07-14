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
/// 调试模式：debug build 设置 [debugLog] 为 true 可查看完整日志面板并复制到剪贴板；
/// release 默认关闭日志，即使外部强行开启也禁用复制。WebView 始终存活，日志面板展开/收起不重建 WebView。
///
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /// TLS 证书异常放行白名单（host 精确匹配）；仅 debug build 可用。
  final Set<String> tlsProceedHosts;

  /// 开启后页面底部可展开实时日志面板；release 默认关闭，且禁用复制。
  final bool debugLog;

  @override
  State<WebViewLoginPage> createState() => _WebViewLoginPageState();
}

class _LogEntry {
  _LogEntry(this.timestamp, this.message);
  final String timestamp;
  final String message;
}

/// 收割轮询节奏（审阅 P2-5）：成功 URL 命中后 session cookie 落定时机不定，
/// 此前用固定 600ms 延迟赌它落定（慢且有竞态）。改为按 [_harvestPollInterval]
/// 干跑收割计划，非空且连续两轮 ref 集不变即收割；[_harvestPollDeadline] 到时
/// 以最后一轮为准（可能为空 → 跳过并允许下次 LoadStop 重试，与旧语义一致）。
const Duration _harvestPollInterval = Duration(milliseconds: 150);
const Duration _harvestPollDeadline = Duration(seconds: 3);

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
    if (!widget.debugLog) return;
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    if (kDebugMode) debugPrint('[webview-login] $message');
    setState(() => _log.insert(0, _LogEntry(ts, message)));
  }

  String _maskCookie(dynamic value) {
    final s = _safeString(value);
    return '<${s.length}B>';
  }

  bool _urlAllowed(String url) => isLoginNavigationAllowed(url, widget.login);

  bool _isSuccessUrl(String url) => isLoginSuccessUrl(url, widget.login);

  static String _safeString(dynamic v) => v is String ? v : '';

  /// 汇集全部收割来源域的 cookie 并归一为核心输入形（过滤空名/域）。
  ///
  /// 跨声明域收割（ADR-017 母凭证）：成功 URL 的 host + brokerView 各 scope 域，
  /// 逐一 getCookies 再按 name|domain|path 去重合并——否则会漏掉 ids 子域的 CASTGC。
  Future<List<WebViewCookie>> _collectWebViewCookies(WebUri url) async {
    final cookieManager = CookieManager.instance();
    final origins = <WebUri>{
      url,
      ...harvestCookieOrigins(widget.login).map(WebUri.new),
    };
    final rawCookies = <Cookie>[];
    final seen = <String>{};
    for (final origin in origins) {
      final cs = await cookieManager.getCookies(url: origin);
      for (final c in cs) {
        final key = '${c.name}|${c.domain}|${c.path}';
        if (seen.add(key)) rawCookies.add(c);
      }
    }
    return rawCookies
        .where((c) => c.name.isNotEmpty && (c.domain?.isNotEmpty == true))
        .map((c) => WebViewCookie(
              name: c.name,
              value: _safeString(c.value),
              domain: c.domain!,
              path: c.path ?? '/',
            ))
        .toList();
  }

  Future<void> _harvestCookies(WebUri url) async {
    if (_hasHarvested) return;
    _hasHarvested = true;
    _addLog('── 收割开始 ──');
    _addLog('target: ${url.host}${url.path}');

    try {
      // 有界轮询替代固定 600ms 延迟（审阅 P2-5）：干跑收割计划（不写 store），
      // 非空且连续两轮 ref 集不变（落定）即收割；到时以最后一轮为准。
      final deadline = DateTime.now().add(_harvestPollDeadline);
      var webViewCookies = <WebViewCookie>[];
      Set<String>? prevRefs;
      var round = 0;
      while (true) {
        round += 1;
        webViewCookies = await _collectWebViewCookies(url);
        final refs = planWebViewHarvest(
          login: widget.login,
          cookies: webViewCookies,
        ).map((e) => e.ref).toSet();
        _addLog('轮询#$round：cookie=${webViewCookies.length} 条 | '
            '可收割 ref=[${(refs.toList()..sort()).join(", ")}]');
        if (refs.isNotEmpty && setEquals(refs, prevRefs)) break;
        prevRefs = refs;
        if (DateTime.now().isAfter(deadline)) {
          _addLog('轮询到时（${_harvestPollDeadline.inMilliseconds}ms），以最后一轮为准');
          break;
        }
        await Future<void>.delayed(_harvestPollInterval);
      }

      for (final c in webViewCookies) {
        _addLog(
            '  ${c.name} | domain=${c.domain} | path=${c.path} | value=${_maskCookie(c.value)}');
      }
      _addLog('有效 cookie（已过滤空名/域）：${webViewCookies.length} 条');

      if (webViewCookies.isEmpty) {
        _addLog('⚠ 无有效 cookie，收割跳过');
        _hasHarvested = false;
        return;
      }

      final result = harvestWebViewCookies(
        login: widget.login,
        cookies: webViewCookies,
        put: widget.store.put,
        now: () => DateTime.now().millisecondsSinceEpoch,
      );

      _addLog('收割完成：ref=[${result.entries.map((e) => e.ref).join(", ")}]');
      _addLog(
          'harvested=${result.harvested} | entries=${result.entries.length}');

      _pop(const WebViewLoginResult(status: WebViewLoginStatus.success));
    } catch (e, st) {
      _addLog('收割异常：$e');
      if (kDebugMode && widget.debugLog) debugPrintStack(stackTrace: st);
      _pop(WebViewLoginResult(
          status: WebViewLoginStatus.error, error: e.toString()));
    }
  }

  String _logAsText() {
    final buf = StringBuffer();
    for (final e in _log.reversed) {
      buf.writeln('${e.timestamp} ${e.message}');
    }
    return buf.toString();
  }

  Future<void> _copyLogs() async {
    if (!kDebugMode) return;
    await Clipboard.setData(ClipboardData(text: _logAsText()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('日志已复制到剪贴板'), duration: Duration(seconds: 1)),
      );
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
            onPressed: () => _pop(
                const WebViewLoginResult(status: WebViewLoginStatus.cancelled)),
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
            if (widget.debugLog) ...[
              IconButton(
                icon: Icon(
                    _showLog ? Icons.bug_report : Icons.bug_report_outlined),
                tooltip: '日志',
                onPressed: () => setState(() => _showLog = !_showLog),
              ),
            ],
          ],
        ),
        body: _errorMessage != null
            ? _ErrorView(error: _errorMessage!)
            : _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    return Column(
      children: [
        Expanded(child: _buildWebView()),
        if (widget.debugLog)
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            alignment: Alignment.bottomCenter,
            child: _showLog
                ? SizedBox(
                    height: MediaQuery.of(context).size.height * 0.4,
                    child: Column(
                      children: [
                        const Divider(height: 1),
                        Expanded(child: _buildLogPanel()),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
      ],
    );
  }

  Widget _buildWebView() {
    return InAppWebView(
      key: const ValueKey('webview_login'),
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
        final urlStr = url?.toString() ?? '';
        _addLog('LoadStart ← $urlStr');
        if (url != null && !_urlAllowed(urlStr)) {
          c.stopLoading();
          _addLog('拦截（不在 allowlist）');
          setState(() {
            _isLoading = false;
            _errorMessage = '导航被拦截：$urlStr 不在登录域白名单内。';
          });
        }
      },
      onLoadStop: (c, url) async {
        setState(() => _isLoading = false);
        final urlStr = url?.toString() ?? '';
        final isSuccess = url != null && _isSuccessUrl(urlStr);
        _addLog('LoadStop ← $urlStr${isSuccess ? " ★匹配" : ""}');
        if (isSuccess) {
          await _harvestCookies(url);
        }
      },
      shouldOverrideUrlLoading: (c, action) async {
        final requestedUrl = action.request.url?.toString() ?? '';
        final isMain = action.isForMainFrame;
        _addLog('NavIntent → $requestedUrl${isMain ? " (main)" : ""}');
        if (!_urlAllowed(requestedUrl)) {
          _addLog('拦截（allowlist）');
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
        final bool allowed =
            kDebugMode && widget.tlsProceedHosts.contains(host);
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
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 11)),
                const SizedBox(width: 4),
                IconButton(
                  icon: Icon(
                    Icons.copy,
                    color: kDebugMode ? Colors.white38 : Colors.white12,
                    size: 16,
                  ),
                  tooltip: kDebugMode ? '复制全部日志' : 'release 禁用复制日志',
                  onPressed: kDebugMode ? _copyLogs : null,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 24, minHeight: 24),
                ),
                const SizedBox(width: 2),
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
                child: SelectableText.rich(
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
