/// ADR-062: native WebView cookies and Hermes session material stay in core.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../scripts/browser.dart' show ScriptBrowserLease;
import '../app_tunnel.dart';
import 'configuration.dart';
import 'native_binding.dart';

enum HermesLoginPhase {
  loading,
  ready,
  checking,
  blocked,
  failed,
  complete,
  closed,
}

class HermesLoginState {
  const HermesLoginState(this.phase, {this.origin, this.error});
  final HermesLoginPhase phase;
  final String? origin;
  final String? error;
}

/// This is the entire login surface passed to widgets. Cookies, tickets,
/// native session JSON and credential stores never appear in its state.
class HermesLoginBridge {
  HermesLoginBridge({
    required String gatewayUrl,
    required Set<String> allowedOrigins,
    required this.isActive,
    required Future<void> Function(HermesConfiguration configuration) save,
    String? nodeCertificateSha256,
    HermesNativeBinding? binding,
  }) : gateway = HermesConfiguration.validateGateway(gatewayUrl),
       _pin = HermesConfiguration.validatePin(nodeCertificateSha256),
       _binding = binding ?? HermesNativeBinding(),
       _save = save,
       _origins = Set.unmodifiable({
         HermesConfiguration.validateGateway(gatewayUrl).origin,
         ...allowedOrigins,
       }),
       _lease =
           ScriptBrowserLease.tryAcquire('hermes-login') ??
           (throw const AppTunnelException('browser_busy')) {
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_closed && !isActive()) dispose();
    });
  }

  final Uri gateway;
  final String? _pin;
  final HermesNativeBinding _binding;
  final Set<String> _origins;
  final bool Function() isActive;
  final Future<void> Function(HermesConfiguration configuration) _save;
  final ScriptBrowserLease _lease;
  final state = ValueNotifier(const HermesLoginState(HermesLoginPhase.loading));
  InAppWebViewController? _controller;
  HermesNativeRequest? _request;
  Timer? _timer;
  Future<void>? _closing;
  bool _closed = false;
  bool _checking = false;

  InAppWebViewSettings get settings => InAppWebViewSettings(
    javaScriptEnabled: true,
    incognito: false,
    isInspectable: kDebugMode,
    useShouldOverrideUrlLoading: true,
    supportMultipleWindows: false,
    javaScriptCanOpenWindowsAutomatically: false,
  );

  void _check() {
    if (_closed || !isActive()) {
      throw const AppTunnelException('hermes_cancelled');
    }
  }

  Future<void> attach(InAppWebViewController controller) async {
    if (_closed || !isActive()) {
      controller.dispose();
      return;
    }
    _controller = controller;
    try {
      await CookieManager.instance().deleteAllCookies();
      _check();
      await WebStorageManager.instance().deleteAllData();
      _check();
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri('${gateway.origin}/')),
      );
    } catch (_) {
      if (!_closed) {
        state.value = const HermesLoginState(
          HermesLoginPhase.failed,
          error: 'hermes_browser_failed',
        );
      }
    }
  }

  bool navigationAllowed(String? value) {
    if (_closed || !isActive()) return false;
    final uri = value == null ? null : Uri.tryParse(value);
    final allowed =
        uri != null &&
        uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        _origins.contains(uri.origin);
    if (!allowed) {
      state.value = const HermesLoginState(
        HermesLoginPhase.blocked,
        error: 'hermes_navigation_denied',
      );
    } else if (!_checking) {
      state.value = HermesLoginState(
        HermesLoginPhase.ready,
        origin: uri.origin,
      );
    }
    return allowed;
  }

  Future<NavigationActionPolicy?> navigation(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    if (action.isForMainFrame == false) return NavigationActionPolicy.ALLOW;
    return navigationAllowed(action.request.url?.toString())
        ? NavigationActionPolicy.ALLOW
        : NavigationActionPolicy.CANCEL;
  }

  Future<void> loadStarted(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    if (url?.toString() == 'about:blank') return;
    if (!navigationAllowed(url?.toString())) await controller.stopLoading();
  }

  /// Explicitly called after the user completes gateway CAS/MFA in the official
  /// page. The native onlineInfo check, rather than the button, proves login.
  Future<bool> finish() async {
    if (_checking) return false;
    _check();
    _checking = true;
    state.value = const HermesLoginState(HermesLoginPhase.checking);
    try {
      final controller = _controller;
      if (controller == null || !_binding.isAvailable) {
        throw const AppTunnelException('app_tunnel_unavailable');
      }
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri('${gateway.origin}/'),
        webViewController: controller,
      );
      _check();
      if (cookies.isEmpty || cookies.length > 256) {
        throw const AppTunnelException('hermes_authentication_required');
      }
      final values = <Map<String, Object?>>[];
      for (final cookie in cookies) {
        final domain = cookie.domain?.isNotEmpty == true
            ? cookie.domain!
            : gateway.host;
        final normalized = domain.startsWith('.')
            ? domain.substring(1)
            : domain;
        if (!(gateway.host == normalized ||
            gateway.host.endsWith('.$normalized'))) {
          continue;
        }
        values.add({
          'name': cookie.name,
          'value': cookie.value is String ? cookie.value : '',
          'domain': domain,
          'path': cookie.path?.isNotEmpty == true ? cookie.path : '/',
          'secure': cookie.isSecure ?? true,
          'http_only': cookie.isHttpOnly ?? false,
        });
      }
      if (utf8.encode(jsonEncode(values)).length > 256 * 1024) {
        throw const AppTunnelException('hermes_invalid_configuration');
      }
      final request = _binding.request({
        'op': 'authenticateCookies',
        'gatewayUrl': gateway.origin,
        'cookies': values,
      });
      _request = request;
      final response = await request.result;
      _check();
      final session = response['session'];
      if (session is! Map) {
        throw const AppTunnelException('hermes_authentication_required');
      }
      final configuration = HermesConfiguration(
        gatewayUrl: gateway.origin,
        session: Map<String, dynamic>.from(session),
        nodeCertificateSha256: _pin,
      );
      await _save(configuration);
      _check();
      state.value = const HermesLoginState(HermesLoginPhase.complete);
      return true;
    } catch (error) {
      if (!_closed) {
        state.value = HermesLoginState(
          HermesLoginPhase.failed,
          error: error is AppTunnelException
              ? error.code
              : 'hermes_authentication_required',
        );
      }
      return false;
    } finally {
      _checking = false;
      _request = null;
    }
  }

  void platformError() {
    if (!_closed) {
      state.value = const HermesLoginState(
        HermesLoginPhase.failed,
        error: 'hermes_browser_failed',
      );
    }
  }

  Future<void> stop() => _closing ??= _stop();
  Future<void> _stop() async {
    _closed = true;
    _timer?.cancel();
    _request?.cancel();
    final controller = _controller;
    try {
      if (controller != null) {
        await controller.setSettings(
          settings: InAppWebViewSettings(javaScriptEnabled: false),
        );
        await controller.stopLoading();
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri('about:blank')),
        );
        await CookieManager.instance().deleteAllCookies();
        await WebStorageManager.instance().deleteAllData();
      }
    } catch (_) {
      // Keep the lease through the stop attempt, including failed native views.
    } finally {
      controller?.dispose();
      _controller = null;
      _lease.release();
    }
  }

  void dispose() {
    if (!_closed) {
      state.value = const HermesLoginState(HermesLoginPhase.closed);
      unawaited(stop());
    }
  }
}
