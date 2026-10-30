/// Visible school page for ADR-034 §5. Only the core bridge sees raw URLs,
/// cookies and page results; presentation uses origin and stable state codes.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/scripts/browser.dart';

/// Apple calls its server-trust callback for valid certificates too. Returning
/// null preserves platform validation; PROCEED would install trust exceptions.
/// Android invokes this callback for certificate errors, which are cancelled.
/// ADR-034 §4–§5: no TLS validation bypass.
ServerTrustAuthResponse? scriptBrowserServerTrustResponse(
  TargetPlatform platform,
) => platform == TargetPlatform.android
    ? ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.CANCEL)
    : null;

// ADR-034 §5: a platform placeholder is never a school page or a browser
// execution target. Cancel it without a misleading school-policy failure.
NavigationActionPolicy scriptBrowserNavigationPolicy(
  ScriptBrowserBridge bridge,
  String? url, {
  bool? isForMainFrame,
}) {
  if (url == 'about:blank') return NavigationActionPolicy.CANCEL;
  if (isForMainFrame == false) return NavigationActionPolicy.ALLOW;
  return bridge.navigationStarted(url)
      ? NavigationActionPolicy.ALLOW
      : NavigationActionPolicy.CANCEL;
}

/// Provided by the parent flow from ARB-backed AppLocalizations.
class ScriptBrowserPageLabels {
  const ScriptBrowserPageLabels({
    required this.title,
    required this.close,
    required this.loading,
    required this.signingIn,
    required this.blocked,
    required this.failed,
    required this.unavailable,
  });
  final String title;
  final String close;
  final String loading;
  final String signingIn;
  final String blocked;
  final String failed;
  final String unavailable;
}

class ScriptBrowserPage extends StatefulWidget {
  const ScriptBrowserPage({
    super.key,
    required this.bridge,
    required this.labels,
  });
  final ScriptBrowserBridge bridge;
  final ScriptBrowserPageLabels labels;

  @override
  State<ScriptBrowserPage> createState() => _ScriptBrowserPageState();
}

/// ADR-039 §1: host-owned status; only the school page is blocked, so the
/// surrounding close button and system back action remain available.
class ScriptBrowserBusyOverlay extends StatelessWidget {
  const ScriptBrowserBusyOverlay({
    super.key,
    required this.busy,
    required this.label,
    required this.child,
  });

  final bool busy;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      ExcludeFocus(
        excluding: busy,
        child: ExcludeSemantics(
          excluding: busy,
          child: AbsorbPointer(absorbing: busy, child: child),
        ),
      ),
      if (busy)
        Positioned.fill(
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface.withValues(alpha: .92),
            child: Center(
              child: Semantics(
                liveRegion: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(semanticsLabel: label),
                    const SizedBox(height: 16),
                    Text(label, style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

class _ScriptBrowserPageState extends State<ScriptBrowserPage> {
  bool _prepared = false;
  bool _returning = false;

  @override
  void initState() {
    super.initState();
    // ADR-034 §6 / redline #1: the plugin otherwise logs JS handler arguments
    // in debug builds, including one-shot passwords, OTPs and cookie results.
    // Keep only the host's sanitized stage diagnostics, including after close.
    PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
    try {
      widget.bridge.prepare();
      _prepared = true;
    } on ScriptBrowserException {
      // Do not construct a native WebView when the platform, policy or shared
      // session lease cannot support it.
    }
  }

  Future<void> _close() async {
    if (_returning) return;
    _returning = true;
    try {
      await widget.bridge.close();
    } catch (_) {
      // Cancellation still closes the page. A later session must pass the
      // initialization cleanup barrier before it can access browser data.
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    unawaited(widget.bridge.close().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _returning,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_close());
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.labels.title),
        leading: IconButton(
          tooltip: widget.labels.close,
          icon: const Icon(Icons.close),
          onPressed: _close,
        ),
      ),
      body: !_prepared
          ? Center(child: Text(widget.labels.unavailable))
          : Column(
              children: [
                ValueListenableBuilder<ScriptBrowserState>(
                  valueListenable: widget.bridge.state,
                  builder: (context, state, _) => Column(
                    children: [
                      if (state.phase == ScriptBrowserPhase.loading ||
                          state.phase == ScriptBrowserPhase.waiting)
                        LinearProgressIndicator(
                          semanticsLabel: widget.labels.loading,
                        ),
                      if (state.origin != null)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            state.origin!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (state.phase == ScriptBrowserPhase.blocked ||
                          state.phase == ScriptBrowserPhase.failed)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            state.phase == ScriptBrowserPhase.blocked
                                ? widget.labels.blocked
                                : widget.labels.failed,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: widget.bridge.busy,
                    builder: (context, busy, child) => ScriptBrowserBusyOverlay(
                      busy: busy,
                      label: widget.labels.signingIn,
                      child: child!,
                    ),
                    child: InAppWebView(
                      key: const ValueKey('trusted_script_browser'),
                      initialSettings: InAppWebViewSettings(
                        // Native Apple CookieManager reads the default data
                        // store, not a nonPersistent WebView store. Use that
                        // same store under an exclusive lease and explicit
                        // pre/after cleanup so HttpOnly login cookies work.
                        incognito: false,
                        javaScriptEnabled: true,
                        domStorageEnabled: true,
                        isInspectable: false,
                        useShouldOverrideUrlLoading: true,
                        javaScriptCanOpenWindowsAutomatically: false,
                        supportMultipleWindows: true,
                        allowFileAccess: false,
                        allowContentAccess: false,
                        allowFileAccessFromFileURLs: false,
                        allowUniversalAccessFromFileURLs: false,
                      ),
                      onWebViewCreated: (controller) {
                        final driver = _InAppScriptBrowserDriver(controller);
                        if (!mounted) {
                          driver.discard();
                          return;
                        }
                        controller.addJavaScriptHandler(
                          handlerName: ScriptBrowserBridge.resultHandler,
                          callback: (arguments) {
                            if (arguments.length == 1) {
                              widget.bridge.receiveResult(arguments.single);
                            }
                            return null;
                          },
                        );
                        try {
                          widget.bridge.attach(driver);
                        } on ScriptBrowserException {
                          // A late native creation can arrive after the bridge
                          // released its lease. Only dispose this orphan view;
                          // global cookie cleanup could affect a newer identity.
                          driver.discard();
                        }
                      },
                      shouldOverrideUrlLoading: (controller, action) async {
                        return scriptBrowserNavigationPolicy(
                          widget.bridge,
                          action.request.url?.toString(),
                          isForMainFrame: action.isForMainFrame,
                        );
                      },
                      onLoadStart: (controller, url) async {
                        if (url?.toString() == 'about:blank') return;
                        if (!widget.bridge.navigationStarted(url?.toString())) {
                          await controller.stopLoading();
                        }
                      },
                      onLoadStop: (_, url) {
                        if (url?.toString() == 'about:blank') return;
                        widget.bridge.navigationFinished(url?.toString());
                      },
                      onUpdateVisitedHistory: (controller, url, _) async {
                        if (url?.toString() == 'about:blank') return;
                        if (!widget.bridge.historyChanged(url?.toString())) {
                          await controller.stopLoading();
                        }
                      },
                      onReceivedError: (_, request, _) {
                        if (request.isForMainFrame != false) {
                          widget.bridge.reportError();
                        }
                      },
                      onReceivedServerTrustAuthRequest: (_, _) async {
                        final response = scriptBrowserServerTrustResponse(
                          defaultTargetPlatform,
                        );
                        if (response != null) widget.bridge.reportError();
                        return response;
                      },
                      onCreateWindow: (_, _) async => false,
                      onPermissionRequest: (_, _) async => PermissionResponse(
                        action: PermissionResponseAction.DENY,
                      ),
                    ),
                  ),
                ),
              ],
            ),
    ),
  );
}

class _InAppScriptBrowserDriver implements ScriptBrowserDriver {
  _InAppScriptBrowserDriver(this._controller);
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
