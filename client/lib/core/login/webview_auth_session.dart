/// WebView 认证核心状态机（ADR-012 §2.2、ADR-017 §2.7、ADR-020 §2.3）。
///
/// 原始 callback URL、cookie 和 query 凭证只在本核心服务内流转；对 UI 只发布无 query、
/// 无 cookie、无原始异常的状态与结果。
///
/// 🔒 红线 #1：凭证收割承重路径。AI 起草，须人工 + 安全清单复核。
library;

import 'dart:async';

import '../broker/harvest.dart';
import '../credential/types.dart';
import 'webview_login.dart';

enum WebViewLoginStatus { success, cancelled, error }

class WebViewLoginResult {
  const WebViewLoginResult({required this.status, this.error});

  final WebViewLoginStatus status;
  final String? error;
}

enum WebViewAuthPhase { loading, harvesting, blocked, error, complete }

/// 可安全交给 UI 的状态。结构上不承载 raw URL、cookie、ticket 或异常原文。
class WebViewAuthUiState {
  const WebViewAuthUiState({required this.phase, this.location, this.message});

  final WebViewAuthPhase phase;
  final String? location;
  final String? message;
}

typedef WebViewCookieReader = Future<List<WebViewCookie>> Function(String url);

class WebViewAuthSession {
  WebViewAuthSession({
    required this.login,
    required this.readCookies,
    required this.putCredential,
    this.requiredRef,
    this.onState,
    Duration pollInterval = const Duration(milliseconds: 150),
    Duration pollDeadline = const Duration(seconds: 3),
    int Function()? now,
  }) : _pollInterval = pollInterval,
       _pollDeadline = pollDeadline,
       _now = now ?? _nowMs;

  final LoginManifestView login;
  final WebViewCookieReader readCookies;
  final void Function(CredentialEntry entry) putCredential;
  final String? requiredRef;
  final void Function(WebViewAuthUiState state)? onState;
  final Duration _pollInterval;
  final Duration _pollDeadline;
  final int Function() _now;

  final Completer<WebViewLoginResult> _completion =
      Completer<WebViewLoginResult>();
  Future<void>? _harvestInFlight;
  String? _successUrl;
  bool _disposed = false;

  Future<WebViewLoginResult> get completion => _completion.future;
  bool get isCompleted => _completion.isCompleted;

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  bool navigationAllowed(String? rawUrl) =>
      rawUrl != null &&
      rawUrl.isNotEmpty &&
      isLoginNavigationAllowed(rawUrl, login);

  String safeLocation(String? rawUrl) {
    final uri = rawUrl == null ? null : Uri.tryParse(rawUrl);
    if (uri == null || uri.host.isEmpty) return '未知地址';
    return '${uri.scheme}://${uri.host}${uri.path}';
  }

  /// 处理插件直接交来的 URL 事件。调用者不得先把 raw URL 送到 UI/log。
  Future<bool> handleNavigation(
    String? rawUrl, {
    required bool loadStopped,
  }) async {
    if (_disposed || isCompleted) return false;
    if (!navigationAllowed(rawUrl)) {
      onState?.call(
        WebViewAuthUiState(
          phase: WebViewAuthPhase.blocked,
          location: safeLocation(rawUrl),
          message: '导航不在学校登录白名单内',
        ),
      );
      return false;
    }

    final url = rawUrl!;
    onState?.call(
      WebViewAuthUiState(
        phase: WebViewAuthPhase.loading,
        location: safeLocation(url),
      ),
    );
    if (isLoginSuccessUrl(url, login)) {
      // callback query 可能只在短暂中间跳出现，核心立即保留，完成后清除。
      _successUrl = url;
      _harvestInFlight ??= _harvest(url);
      if (loadStopped) await _harvestInFlight;
    }
    return true;
  }

  Future<void> _harvest(String triggerUrl) async {
    onState?.call(
      WebViewAuthUiState(
        phase: WebViewAuthPhase.harvesting,
        location: safeLocation(triggerUrl),
      ),
    );
    final deadline = DateTime.now().add(_pollDeadline);
    List<HarvestEntry> finalPlan = const [];
    String? previousFingerprint;

    try {
      while (!_disposed && !isCompleted) {
        final cookies = await readCookies(triggerUrl);
        if (_disposed || isCompleted) return;
        final plan = planWebViewHarvest(
          login: login,
          cookies: cookies,
          currentUrl: _successUrl,
        );
        final fingerprint = plan
            .map((e) => '${e.ref}\u0000${e.value}')
            .join('\u0001');
        finalPlan = plan;
        if (plan.isNotEmpty && fingerprint == previousFingerprint) break;
        previousFingerprint = fingerprint;
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(_pollInterval);
      }

      if (_disposed || isCompleted) return;
      final required = requiredRef;
      if (finalPlan.isEmpty ||
          (required != null &&
              !finalPlan.any((entry) => entry.ref == required))) {
        _harvestInFlight = null;
        return;
      }

      harvestInto(
        finalPlan,
        login.brokerView,
        putCredential,
        schoolId: login.schoolId,
        now: _now,
      );
      _successUrl = null;
      onState?.call(const WebViewAuthUiState(phase: WebViewAuthPhase.complete));
      _complete(const WebViewLoginResult(status: WebViewLoginStatus.success));
    } catch (_) {
      _successUrl = null;
      onState?.call(
        const WebViewAuthUiState(
          phase: WebViewAuthPhase.error,
          message: '认证状态读取失败',
        ),
      );
      _complete(
        const WebViewLoginResult(
          status: WebViewLoginStatus.error,
          error: '认证状态读取失败',
        ),
      );
    }
  }

  void platformError() {
    if (_disposed || isCompleted) return;
    onState?.call(
      const WebViewAuthUiState(
        phase: WebViewAuthPhase.error,
        message: '登录页面加载失败',
      ),
    );
    _complete(
      const WebViewLoginResult(
        status: WebViewLoginStatus.error,
        error: '登录页面加载失败',
      ),
    );
  }

  void cancel() {
    if (_disposed || isCompleted) return;
    _successUrl = null;
    _complete(const WebViewLoginResult(status: WebViewLoginStatus.cancelled));
  }

  void _complete(WebViewLoginResult result) {
    if (!_completion.isCompleted) _completion.complete(result);
  }

  void dispose() {
    _disposed = true;
    _successUrl = null;
    if (!_completion.isCompleted) {
      _completion.complete(
        const WebViewLoginResult(status: WebViewLoginStatus.cancelled),
      );
    }
  }
}
