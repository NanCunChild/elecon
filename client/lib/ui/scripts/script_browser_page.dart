/// A route around the shared native browser surface (ADR-068).
library;

import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/scripts/browser.dart';
import 'script_browser_surface.dart';

export 'script_browser_surface.dart';
export 'script_browser_platform_view.dart'
    show scriptBrowserNavigationPolicy, scriptBrowserServerTrustResponse;

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

class _ScriptBrowserPageState extends State<ScriptBrowserPage> {
  bool _returning = false;
  Future<void> _close() async {
    if (_returning) return;
    _returning = true;
    try {
      await widget.bridge.close();
    } catch (_) {
      // A replacement still has to pass the native cleanup barrier.
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
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
      body: ScriptBrowserSurface(
        bridge: widget.bridge,
        labels: widget.labels,
        showHeader: false,
      ),
    ),
  );
}
