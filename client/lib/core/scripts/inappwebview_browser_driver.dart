/// Native WebView driver shared by trusted browser presentations.
/// No script receives the controller; the bridge owns its exclusive lease.
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'browser.dart';

class InAppScriptBrowserDriver
    implements ScriptBrowserDriver, ScriptBrowserContentDriver {
  InAppScriptBrowserDriver(this._controller);
  final InAppWebViewController _controller;
  bool _closed = false;
  Future<void>? _initializing;
  Future<void> _cookieWrites = Future.value();

  @override
  Future<void> initialize() => _initializing ??= _clearSession();

  Future<void> _clearSession() async {
    await CookieManager.instance().deleteAllCookies();
    await WebStorageManager.instance().deleteAllData();
  }

  @override
  Future<void> loadUrl(String url) =>
      _controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));

  @override
  Future<void> loadContent(String html, String baseUrl) =>
      // The platform view serves the bridge's current approved document from
      // memory. Android's native network gate remains enabled throughout;
      // there is no HTTP fallback if the interceptor is unavailable.
      _controller.loadUrl(urlRequest: URLRequest(url: WebUri(baseUrl)));

  @override
  Future<void> evaluate(String source) async {
    await _controller.evaluateJavascript(source: source);
  }

  @override
  Future<void> clearFocus() async {
    if (_closed) return;
    // ADR-039 §1: platform focus can outlive Flutter's FocusNode. Never read
    // input contents; blur the DOM and native responder, then dismiss the IME.
    await _controller.evaluateJavascript(
      source: 'document.activeElement?.blur?.();',
    );
    if (_closed) return;
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      await _controller.clearFocus();
    }
    if (!_closed) {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    }
  }

  @override
  Future<List<Map<String, Object?>>> cookies(Uri url) async {
    final cookies = await CookieManager.instance().getCookies(
      url: WebUri(url.toString()),
      webViewController: _controller,
    );
    return [
      for (final cookie in cookies)
        {
          'name': cookie.name,
          'value': cookie.value,
          if (cookie.domain != null) 'domain': cookie.domain,
          if (cookie.path != null) 'path': cookie.path,
          if (cookie.expiresDate != null) 'expiresDate': cookie.expiresDate,
          if (cookie.isHttpOnly != null) 'isHttpOnly': cookie.isHttpOnly,
          if (cookie.isSecure != null) 'isSecure': cookie.isSecure,
          if (cookie.sameSite != null) 'sameSite': cookie.sameSite!.toValue(),
        },
    ];
  }

  @override
  Future<void> setCookies(String url, List<Map<String, Object?>> cookies) {
    if (_closed) throw const ScriptBrowserException('browser_closed');
    final pending = _cookieWrites.then((_) async {
      for (final cookie in cookies) {
        if (_closed) throw const ScriptBrowserException('browser_closed');
        final stored = await CookieManager.instance().setCookie(
          url: WebUri(url),
          name: cookie['name'] as String,
          value: cookie['value'] as String,
          domain: cookie['domain'] as String?,
          path: cookie['path'] as String,
          expiresDate: cookie['expiresDate'] as int?,
          isSecure: cookie['isSecure'] as bool,
          isHttpOnly: cookie['isHttpOnly'] as bool,
          sameSite: HTTPCookieSameSitePolicy.fromValue(
            cookie['sameSite'] as String?,
          ),
          webViewController: _controller,
        );
        if (_closed) throw const ScriptBrowserException('browser_closed');
        if (!stored) {
          throw const ScriptBrowserException('browser_cookie_write_failed');
        }
      }
    });
    _cookieWrites = pending.then<void>((_) {}, onError: (Object _) {});
    return pending;
  }

  @override
  Future<void> stopLoading() => _controller.stopLoading();

  void discard() {
    if (_closed) return;
    _closed = true;
    _controller.removeJavaScriptHandler(
      handlerName: ScriptBrowserBridge.resultHandler,
    );
    unawaited(_controller.stopLoading().catchError((Object _) {}));
    _controller.dispose();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      try {
        await _initializing;
      } catch (_) {
        // Retry session cleanup below; initialization errors are already
        // reported through the bridge as a stable code.
      }
      await _cookieWrites;
      await _controller.stopLoading();
      _controller.removeJavaScriptHandler(
        handlerName: ScriptBrowserBridge.resultHandler,
      );
      // ADR-034 §5: the bridge retains its exclusive lease until cleanup ends.
      await CookieManager.instance().deleteAllCookies();
      await WebStorageManager.instance().deleteAllData();
    } finally {
      _controller.dispose();
    }
  }
}
