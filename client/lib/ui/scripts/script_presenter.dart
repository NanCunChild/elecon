/// Visible browser lifecycle shared by home capabilities and the workbench.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/scripts/browser.dart';
import '../../core/scripts/manifest.dart';
import '../../core/scripts/runtime.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import 'script_browser_page.dart';

Future<Object?> presentScriptBrowser(
  BuildContext context,
  ScriptPackage package,
  Future<Object?> Function(ScriptBrowserCall) execute, {
  void Function()? onCancel,
}) async {
  final bridge = ScriptBrowserBridge(policy: package.manifest.network);
  bridge.prepare();
  if (!context.mounted) {
    await bridge.close();
    throw const ScriptRunException('invocation_cancelled');
  }
  final l10n = AppLocalizations.of(context);
  final navigator = Navigator.of(context);
  final route = MaterialPageRoute<void>(
    builder: (_) => ScriptBrowserPage(
      bridge: bridge,
      labels: ScriptBrowserPageLabels(
        title: l10n.scriptsBrowserTitle,
        close: l10n.scriptsBrowserClose,
        loading: l10n.scriptsBrowserLoading,
        blocked: l10n.scriptsBrowserBlocked,
        failed: l10n.scriptsBrowserFailed,
        unavailable: l10n.scriptsBrowserUnavailable,
      ),
    ),
  );
  final closed = Completer<Object?>();
  var completed = false;
  void observeClose() {
    if (!completed && bridge.state.value.phase == ScriptBrowserPhase.closed) {
      // Invalidate credential/HTTP callbacks immediately, before native cleanup
      // or a caught page exception can return a seemingly successful result.
      onCancel?.call();
    }
  }

  bridge.state.addListener(observeClose);
  unawaited(
    navigator.push(route).then((_) async {
      try {
        await bridge.close();
      } catch (_) {
        // Native cleanup errors must not escape this unobserved route future.
      } finally {
        if (!closed.isCompleted) {
          closed.completeError(
            const ScriptRunException('invocation_cancelled'),
          );
        }
      }
    }),
  );
  // Future.any attaches an error handler to the route-cancellation future.
  try {
    return await Future.any([execute(bridge.call), closed.future]);
  } finally {
    completed = true;
    bridge.state.removeListener(observeClose);
    try {
      await bridge.close();
    } finally {
      if (route.isCurrent) {
        navigator.pop();
      } else if (route.isActive) {
        navigator.removeRoute(route);
      }
    }
  }
}
