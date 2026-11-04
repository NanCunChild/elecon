/// Native view callbacks shared by every trusted browser surface.
library;

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../core/scripts/browser.dart';
import '../../core/scripts/inappwebview_browser_driver.dart';

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
  if (bridge.state.value.phase == ScriptBrowserPhase.closed) {
    return NavigationActionPolicy.CANCEL;
  }
  if (bridge.contentOnly) {
    // loadData is initiated by the host; any page-driven navigation (including
    // a permitted-looking virtual URL) must not become a native request.
    return NavigationActionPolicy.CANCEL;
  }
  if (isForMainFrame == false) {
    final target = url == null ? null : Uri.tryParse(url);
    if (target != null &&
        !bridge.contentOnly &&
        bridge.allowsNavigation(target)) {
      // A permitted child document must not change the top-level URL or
      // invalidate outstanding DOM replies from the owning document.
      return NavigationActionPolicy.ALLOW;
    }
    bridge.navigationStarted(url);
    return NavigationActionPolicy.CANCEL;
  }
  return bridge.navigationStarted(url)
      ? NavigationActionPolicy.ALLOW
      : NavigationActionPolicy.CANCEL;
}

/// Offline content has an independent native network gate, set before the
/// first document; it is never toggled by page code or a later browser call.
InAppWebViewSettings scriptBrowserSettings(ScriptBrowserBridge bridge) =>
    InAppWebViewSettings(
      incognito: false,
      javaScriptEnabled: true,
      domStorageEnabled: !bridge.contentOnly,
      isInspectable: false,
      useShouldOverrideUrlLoading: true,
      useShouldInterceptRequest: bridge.contentOnly,
      useOnDownloadStart: true,
      blockNetworkLoads: bridge.contentOnly,
      blockNetworkImage: bridge.contentOnly,
      cacheEnabled: !bridge.contentOnly,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
      javaScriptCanOpenWindowsAutomatically: false,
      supportMultipleWindows: true,
      allowFileAccess: false,
      allowContentAccess: false,
      allowFileAccessFromFileURLs: false,
      allowUniversalAccessFromFileURLs: false,
    );

WebResourceResponse scriptBrowserBlockedResource() => WebResourceResponse(
  data: Uint8List(0),
  statusCode: 403,
  reasonPhrase: 'Blocked',
  contentType: 'text/plain',
  contentEncoding: 'utf-8',
  headers: const {'Cache-Control': 'no-store'},
);

WebResourceResponse? scriptBrowserInterceptRequest(
  ScriptBrowserBridge bridge,
  WebResourceRequest request,
) {
  if (!bridge.contentOnly) return null;
  final document = request.isForMainFrame == true && request.method == 'GET'
      ? bridge.contentDocumentFor(Uri.parse(request.url.toString()))
      : null;
  if (document == null) return scriptBrowserBlockedResource();
  return WebResourceResponse(
    data: Uint8List.fromList(utf8.encode(document)),
    statusCode: 200,
    reasonPhrase: 'OK',
    contentType: 'text/html',
    contentEncoding: 'utf-8',
    headers: const {
      'Cache-Control': 'no-store',
      'Content-Security-Policy': scriptWebContentPolicy,
      'X-Content-Type-Options': 'nosniff',
    },
  );
}

class ScriptBrowserPlatformView extends StatefulWidget {
  const ScriptBrowserPlatformView({
    super.key,
    required this.bridge,
    this.onDiagnostic,
  });
  @visibleForTesting
  final void Function(String code)? onDiagnostic;
  final ScriptBrowserBridge bridge;
  @override
  State<ScriptBrowserPlatformView> createState() =>
      _ScriptBrowserPlatformViewState();
}

class _ScriptBrowserPlatformViewState extends State<ScriptBrowserPlatformView> {
  @override
  Widget build(BuildContext context) {
    // Capture the owner; callbacks from a removed native view must never be
    // redirected into a replacement identity's bridge.
    final bridge = widget.bridge;
    final diagnostic = widget.onDiagnostic;
    return InAppWebView(
      key: const ValueKey('trusted_script_browser'),
      initialSettings: scriptBrowserSettings(bridge),
      shouldInterceptRequest: (controller, request) async {
        final response = scriptBrowserInterceptRequest(bridge, request);
        diagnostic?.call(
          'resource-main-${request.isForMainFrame == true}-local-${bridge.allowsNavigation(Uri.parse(request.url.toString()))}-get-${request.method == 'GET'}-served-${response?.statusCode == 200}',
        );
        return response;
      },
      onDownloadStarting: (_, _) async => DownloadStartResponse(
        handled: true,
        action: DownloadStartResponseAction.CANCEL,
      ),
      onWebViewCreated: (controller) {
        diagnostic?.call('created');
        final driver = InAppScriptBrowserDriver(controller);
        if (!mounted || !identical(widget.bridge, bridge)) {
          driver.discard();
          return;
        }
        controller.addJavaScriptHandler(
          handlerName: ScriptBrowserBridge.resultHandler,
          callback: (arguments) {
            if (arguments.length == 1) {
              bridge.receiveResult(arguments.single);
            }
            return null;
          },
        );
        try {
          bridge.attach(driver);
        } on ScriptBrowserException catch (error) {
          diagnostic?.call('attach-${error.code}');
          // A late native creation can arrive after the bridge
          // released its lease. Only dispose this orphan view;
          // global cookie cleanup could affect a newer identity.
          driver.discard();
        }
      },
      shouldOverrideUrlLoading: (controller, action) async {
        return scriptBrowserNavigationPolicy(
          bridge,
          action.request.url?.toString(),
          isForMainFrame: action.isForMainFrame,
        );
      },
      onLoadStart: (controller, url) async {
        diagnostic?.call(
          'load-start-local-${url != null && bridge.allowsNavigation(Uri.parse(url.toString()))}-blank-${url?.toString() == 'about:blank'}',
        );
        if (url?.toString() == 'about:blank') return;
        if (!bridge.navigationStarted(url?.toString())) {
          await controller.stopLoading();
        }
      },
      onLoadStop: (_, url) {
        diagnostic?.call(
          'load-stop-local-${url != null && bridge.allowsNavigation(Uri.parse(url.toString()))}-blank-${url?.toString() == 'about:blank'}',
        );
        if (url?.toString() == 'about:blank') return;
        bridge.navigationFinished(url?.toString());
      },
      onUpdateVisitedHistory: (controller, url, _) async {
        if (url?.toString() == 'about:blank') return;
        if (!bridge.historyChanged(url?.toString())) {
          await controller.stopLoading();
        }
      },
      onReceivedError: (_, request, _) {
        if (request.isForMainFrame != false) {
          bridge.reportError();
        }
      },
      onReceivedServerTrustAuthRequest: (_, _) async {
        final response = scriptBrowserServerTrustResponse(
          defaultTargetPlatform,
        );
        if (response != null) bridge.reportError();
        return response;
      },
      onCreateWindow: (_, _) async => false,
      onPermissionRequest: (_, _) async =>
          PermissionResponse(action: PermissionResponseAction.DENY),
    );
  }
}
