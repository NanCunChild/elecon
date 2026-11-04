/// Visible browser lifecycle shared by home capabilities and the workbench.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/scripts/browser.dart';
import '../../core/debug/dev_log.dart';
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
  void Function(String)? onTrace,
}) async {
  ScriptBrowserBridge? bridge;
  Route<void>? route;
  NavigatorState? navigator;
  final closed = Completer<Object?>();
  var completed = false;
  String? lastTrace;
  void observeClose() {
    final state = bridge!.state.value;
    final trace =
        '[browser] ${state.phase.name}${state.origin == null ? "" : " ${state.origin}"}${state.errorCode == null ? "" : " ${state.errorCode}"}';
    if (trace != lastTrace) {
      lastTrace = trace;
      DevLog.instance.webview(trace);
      // A denied browser destination is a network-boundary failure. Keep its
      // origin (never path/query/cookies) available in release diagnostics.
      if (state.phase == ScriptBrowserPhase.blocked && state.origin != null) {
        DevLog.instance.network(
          method: 'NAVIGATE',
          url: state.origin!,
          ok: false,
          error: 'browser_navigation_blocked',
        );
      }
      onTrace?.call(trace);
    }
    if (!completed && state.phase == ScriptBrowserPhase.closed) {
      onCancel?.call();
    }
  }

  // ADR-034 §5: create a page/lease only when the script actually invokes a
  // browser method. Cached sessions and public HTTP never flash an empty page.
  Future<Object?> call(String method, Map<String, Object?> arguments) async {
    if (completed || !context.mounted) {
      throw const ScriptRunException('invocation_cancelled');
    }
    if (bridge == null) {
      final contentOnly = method == 'openContent';
      final pageId = contentOnly ? arguments['id'] : null;
      final pages = package.manifest.webContent;
      if (contentOnly && !pages.any((page) => page.id == pageId)) {
        throw const ScriptBrowserException('browser_content_undeclared');
      }
      final created = ScriptBrowserBridge(
        policy: package.manifest.network,
        contentOnly: contentOnly,
        contentPages: pages,
        contentDigest: package.digest,
      );
      bridge = created;
      created.prepare();
      final l10n = AppLocalizations.of(context);
      navigator = Navigator.of(context);
      created.state.addListener(observeClose);
      final page = MaterialPageRoute<void>(
        builder: (_) => ScriptBrowserPage(
          bridge: created,
          labels: ScriptBrowserPageLabels(
            title: contentOnly
                ? pages.firstWhere((page) => page.id == pageId).title
                : l10n.scriptsBrowserTitle,
            close: l10n.scriptsBrowserClose,
            loading: l10n.scriptsBrowserLoading,
            signingIn: l10n.scriptsBrowserSigningIn,
            blocked: l10n.scriptsBrowserBlocked,
            failed: l10n.scriptsBrowserFailed,
            unavailable: l10n.scriptsBrowserUnavailable,
          ),
        ),
      );
      route = page;
      unawaited(
        navigator!.push(page).then((_) async {
          try {
            await created.close();
          } catch (_) {
            // The next session still passes the native cleanup barrier.
          } finally {
            if (!closed.isCompleted) {
              closed.completeError(
                const ScriptRunException('invocation_cancelled'),
              );
            }
          }
        }),
      );
    }
    return bridge!.call(method, arguments);
  }

  try {
    return await Future.any([execute(call), closed.future]);
  } finally {
    completed = true;
    bridge?.state.removeListener(observeClose);
    try {
      await bridge?.close();
    } finally {
      final page = route;
      if (page != null && page.isCurrent) {
        navigator!.pop();
      } else if (page != null && page.isActive) {
        navigator!.removeRoute(page);
      }
    }
  }
}
