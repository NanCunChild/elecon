/// Static boundary checks for red line #1. These complement runtime tests by
/// preventing UI/session APIs from regaining value-bearing credential types.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('UI does not import credential core or WebView auth session', () {
    final uiFiles = Directory('lib/ui')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));

    for (final file in uiFiles) {
      final source = file.readAsStringSync();
      expect(
        source,
        isNot(contains('/core/credential/')),
        reason: '${file.path} must use value-free session metadata',
      );
      expect(
        source,
        isNot(contains("core/login/webview_auth_session.dart")),
        reason: '${file.path} must not obtain the credential-bearing session',
      );
      expect(
        source,
        isNot(contains("core/login/inappwebview_auth_bridge.dart")),
        reason: '${file.path} must use the value-free WebView bridge interface',
      );
    }
  });

  test('session and WebView bridge do not expose credential containers', () {
    final controller = File(
      'lib/session/session_controller.dart',
    ).readAsStringSync();
    final bridge = File(
      'lib/core/login/inappwebview_auth_bridge.dart',
    ).readAsStringSync();

    expect(controller, isNot(contains('CredentialStore get store')));
    expect(controller, isNot(contains('CredentialStore? store')));
    expect(bridge, isNot(contains('WebViewAuthSession session')));
    expect(bridge, contains('WebViewAuthSession _session'));
  });
}
