/// Narrow, value-free WebView host surface exposed to UI (red line #1).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'webview_auth_ui.dart';

abstract interface class WebViewAuthUiBridge {
  String get initialUrl;
  ValueListenable<WebViewAuthUiState> get state;
  InAppWebViewSettings get settings;
  Future<WebViewLoginResult> get completion;

  void onWebViewCreated(InAppWebViewController controller);
  Future<void> onLoadStart(InAppWebViewController controller, WebUri? url);
  Future<void> onLoadStop(InAppWebViewController controller, WebUri? url);
  Future<void> onUpdateVisitedHistory(
    InAppWebViewController controller,
    WebUri? url,
    bool? isReload,
  );
  Future<NavigationActionPolicy?> shouldOverrideUrlLoading(
    InAppWebViewController controller,
    NavigationAction action,
  );
  void onReceivedError(
    InAppWebViewController controller,
    WebResourceRequest request,
    WebResourceError error,
  );
  Future<ServerTrustAuthResponse?> onReceivedServerTrustAuthRequest(
    InAppWebViewController controller,
    URLAuthenticationChallenge challenge,
  );

  Future<void> stop();
  void dispose();
}
