/// 核心托管 WebView 的可见宿主（ADR-012 §2.2 / ADR-016）。
///
/// Widget 只挂载浏览器并展示核心提供的无秘密状态；原始 URL、cookie、callback ticket 与
/// 收割写入全部由 [InAppWebViewAuthBridge] 处理，UI 不接触凭证值（红线 #1）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/debug/perf_trace.dart';
import '../../core/login/webview_auth_ui.dart';
import '../../core/login/webview_auth_ui_bridge.dart';

export '../../core/login/webview_auth_ui.dart'
    show WebViewLoginResult, WebViewLoginStatus;

class WebViewLoginPage extends StatefulWidget {
  const WebViewLoginPage({
    super.key,
    required this.bridge,
    this.performanceTrace,
  });

  final WebViewAuthUiBridge bridge;
  final PerfTrace? performanceTrace;

  @override
  State<WebViewLoginPage> createState() => _WebViewLoginPageState();
}

class _WebViewLoginPageState extends State<WebViewLoginPage> {
  bool _returned = false;

  @override
  void initState() {
    super.initState();
    widget.bridge.state.addListener(_stateChanged);
    unawaited(_awaitCompletion());
  }

  Future<void> _awaitCompletion() async {
    final result = await widget.bridge.completion;
    if (!mounted || _returned) return;
    _returned = true;
    Navigator.of(context).pop(result);
  }

  void _stateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _cancel() async {
    if (_returned) return;
    await widget.bridge.stop();
  }

  @override
  void dispose() {
    widget.bridge.state.removeListener(_stateChanged);
    widget.bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = widget.bridge.state.value;
    final failed =
        authState.phase == WebViewAuthPhase.blocked ||
        authState.phase == WebViewAuthPhase.error;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_cancel());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: '取消登录',
            onPressed: _cancel,
          ),
          title: const Text('校园登录'),
          actions: [
            if (authState.phase == WebViewAuthPhase.loading ||
                authState.phase == WebViewAuthPhase.harvesting)
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
        body: failed
            ? _ErrorView(message: authState.message ?? '登录失败')
            : InAppWebView(
                key: const ValueKey('webview_login'),
                initialUrlRequest: URLRequest(
                  url: WebUri(widget.bridge.initialUrl),
                ),
                initialSettings: widget.bridge.settings,
                onWebViewCreated: (controller) {
                  widget.bridge.onWebViewCreated(controller);
                  widget.performanceTrace?.mark('webview_created');
                },
                onLoadStart: widget.bridge.onLoadStart,
                onLoadStop: (controller, url) async {
                  widget.performanceTrace?.mark('webview_load_stop');
                  await widget.bridge.onLoadStop(controller, url);
                },
                onUpdateVisitedHistory: widget.bridge.onUpdateVisitedHistory,
                shouldOverrideUrlLoading:
                    widget.bridge.shouldOverrideUrlLoading,
                onReceivedError: widget.bridge.onReceivedError,
                onReceivedServerTrustAuthRequest:
                    widget.bridge.onReceivedServerTrustAuthRequest,
              ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline,
            size: 48,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}
