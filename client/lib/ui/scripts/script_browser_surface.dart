/// ADR-068: host-owned embedded browser container, shared with visible login.
/// This widget grants no script API, background execution or hidden login.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../core/scripts/browser.dart';
import 'script_browser_platform_view.dart';

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

/// A bounded native page region with an origin/status strip and optional host
/// header. The caller supplies its height and owns surrounding native content.
/// Removing or replacing this surface closes the bridge and releases its lease
/// only after native cleanup. The default header never navigates the app.
class ScriptBrowserSurface extends StatefulWidget {
  const ScriptBrowserSurface({
    super.key,
    required this.bridge,
    required this.labels,
    this.showHeader = true,
    this.onClosed,
    this.platformViewBuilder,
  });
  final ScriptBrowserBridge bridge;
  final ScriptBrowserPageLabels labels;
  final bool showHeader;
  final VoidCallback? onClosed;
  @visibleForTesting
  final Widget Function(BuildContext, ScriptBrowserBridge)? platformViewBuilder;

  @override
  State<ScriptBrowserSurface> createState() => _ScriptBrowserSurfaceState();
}

class _ScriptBrowserSurfaceState extends State<ScriptBrowserSurface> {
  bool _prepared = false;
  bool _closing = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    // Plugin debug logs may include handler arguments, passwords and cookies.
    PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
    _prepare();
  }

  void _prepare() {
    try {
      widget.bridge.prepare();
      _prepared = true;
    } on ScriptBrowserException {
      _prepared = false;
    }
  }

  @override
  void didUpdateWidget(ScriptBrowserSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.bridge, widget.bridge)) return;
    final revision = ++_revision;
    _prepared = false;
    _closing = false;
    unawaited(() async {
      try {
        await oldWidget.bridge.close();
      } catch (_) {
        // The new driver repeats native cleanup before exposing its session.
      }
      if (!mounted || revision != _revision) return;
      setState(_prepare);
    }());
  }

  Future<void> _close() async {
    if (_closing) return;
    final bridge = widget.bridge;
    final revision = _revision;
    setState(() => _closing = true);
    try {
      await bridge.close();
    } catch (_) {
      // Closing still ends this surface. Future sessions initialize cleanly.
    }
    if (mounted && revision == _revision) widget.onClosed?.call();
  }

  @override
  void dispose() {
    _revision++;
    unawaited(widget.bridge.close().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (widget.showHeader)
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  widget.labels.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            IconButton(
              tooltip: widget.labels.close,
              icon: const Icon(Icons.close),
              onPressed: _closing ? null : _close,
            ),
          ],
        ),
      Expanded(
        child: !_prepared
            ? Center(child: Text(widget.labels.unavailable))
            : ValueListenableBuilder<ScriptBrowserState>(
                valueListenable: widget.bridge.state,
                builder: (context, state, _) {
                  if (state.phase == ScriptBrowserPhase.closed) {
                    return const SizedBox.shrink();
                  }
                  return Column(
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
                      Expanded(
                        // Loading/origin/error rows are conditional siblings.
                        // Keep the native view mounted when those rows change;
                        // replacing it would detach the bridge from its DOM.
                        key: const ValueKey('script-browser-native-region'),
                        child: ValueListenableBuilder<bool>(
                          valueListenable: widget.bridge.busy,
                          builder: (context, busy, child) =>
                              ScriptBrowserBusyOverlay(
                                busy: busy || _closing,
                                label: widget.labels.signingIn,
                                child: child!,
                              ),
                          child:
                              widget.platformViewBuilder?.call(
                                context,
                                widget.bridge,
                              ) ??
                              ScriptBrowserPlatformView(
                                key: ObjectKey(widget.bridge),
                                bridge: widget.bridge,
                              ),
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    ],
  );
}
