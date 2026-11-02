import 'package:flutter/material.dart';

import '../../core/adapter_service.dart';
import '../../core/scripts/manifest.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../scripts/script_input_presenter.dart';
import '../scripts/script_presenter.dart';
import 'section_card.dart';

/// Host-owned foreground command; never discovered from arbitrary script JSON.
class ForegroundRequestAction {
  const ForegroundRequestAction({
    required this.capability,
    required this.label,
    required this.icon,
    required this.params,
  });
  final String capability;
  final String label;
  final IconData icon;
  final Map<String, dynamic> Function() params;
}

/// ADR-056: a reusable, explicitly triggered request surface. It retains no
/// response across route, application or authorized identity changes.
class ForegroundRequestSection extends StatefulWidget {
  const ForegroundRequestSection({
    super.key,
    required this.session,
    required this.package,
    required this.title,
    required this.actions,
    required this.resultBuilder,
    this.inputsBuilder,
    this.onReset,
    this.footerBuilder,
  });
  final SessionController session;
  final ScriptPackage package;
  final String title;
  final List<ForegroundRequestAction> actions;
  final Widget Function(BuildContext, String, CapabilityRun) resultBuilder;
  final Widget Function(BuildContext, bool)? inputsBuilder;
  final VoidCallback? onReset;
  final Widget Function(BuildContext, bool)? footerBuilder;

  @override
  State<ForegroundRequestSection> createState() =>
      _ForegroundRequestSectionState();
}

class _ForegroundRequestSectionState extends State<ForegroundRequestSection>
    with WidgetsBindingObserver {
  ScriptRunCancellation? _cancellation;
  CapabilityRun? _result;
  String? _capability;
  ModalRoute<Object?>? _route;
  late int _generation;
  int _request = 0;
  int _reset = 0;
  bool _busy = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _generation = widget.session.trustedScriptViewGeneration;
    widget.session.addListener(_identityChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  void _clear() {
    _request++;
    _cancellation?.cancel();
    _result = null;
    _capability = null;
    _busy = false;
    _reset++;
    widget.onReset?.call();
  }

  void _identityChanged() {
    if (_generation == widget.session.trustedScriptViewGeneration) return;
    if (mounted) setState(_clear);
    // This view remains pinned to its initial authorized generation. Its owner
    // must recreate it after identity/provider changes.
    _closed = true;
  }

  @override
  void didUpdateWidget(ForegroundRequestSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session ||
        oldWidget.package.digest != widget.package.digest) {
      oldWidget.session.removeListener(_identityChanged);
      _clear();
      _generation = widget.session.trustedScriptViewGeneration;
      widget.session.addListener(_identityChanged);
      _closed = false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == _route) return;
    if (_route != null) _clear();
    _route = route;
    _closed = false;
    route?.popped.then((_) {
      if (!mounted || _route != route) return;
      setState(() {
        _clear();
        _closed = true;
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.session.scriptAppForeground = true;
    }
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      widget.session.scriptAppForeground = false;
    }
    if (widget.session.scriptSystemInputPending) return;
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      setState(_clear);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_identityChanged);
    WidgetsBinding.instance.removeObserver(this);
    _clear();
    super.dispose();
  }

  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  Future<void> _run(ForegroundRequestAction action) async {
    if (_busy || _closed || !_foreground) return;
    final session = widget.session;
    final package = widget.package;
    final request = ++_request;
    final cancellation = ScriptRunCancellation();
    _cancellation = cancellation;
    final params = Map<String, dynamic>.from(action.params());
    bool current() =>
        mounted &&
        request == _request &&
        !cancellation.isCancelled &&
        identical(session, widget.session) &&
        session.trustedScriptViewGeneration == _generation;
    setState(() {
      _busy = true;
      _result = null;
      _capability = action.capability;
    });
    try {
      final installed = (await session.scriptRegistry).find(
        package.manifest.id,
      );
      if (!mounted || !current()) return;
      if (installed?.enabled != true ||
          installed?.package.digest != package.digest ||
          session.selectedSchool?.id != package.manifest.schoolId) {
        setState(() {
          _clear();
          _closed = true;
        });
        return;
      }
      final result =
          await presentScriptInput(
                context,
                package,
                (input) => presentScriptBrowser(
                  context,
                  package,
                  (browser) => session.runTrustedScript(
                    package.manifest.id,
                    action.capability,
                    params: params,
                    inputCall: input,
                    browserCall: browser,
                    cancellation: cancellation,
                  ),
                  onCancel: cancellation.cancel,
                ),
                onCancel: cancellation.cancel,
              )
              as CapabilityRun;
      if (current()) setState(() => _result = result);
    } catch (_) {
      if (current()) {
        setState(
          () => _result = const CapabilityRun.failed(
            CapabilityFailureKind.run,
            'script_failed',
          ),
        );
      }
    } finally {
      if (identical(_cancellation, cancellation)) _cancellation = null;
      cancellation.dispose();
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SectionCard(
    title: widget.title,
    subtitle: widget.package.manifest.name,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.inputsBuilder != null)
          KeyedSubtree(
            key: ValueKey(_reset),
            child: widget.inputsBuilder!(context, !_busy && !_closed),
          ),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            for (final action in widget.actions)
              OutlinedButton.icon(
                onPressed: _busy || _closed ? null : () => _run(action),
                icon: Icon(action.icon),
                label: Text(action.label),
              ),
          ],
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: LinearProgressIndicator(),
          ),
        if (widget.footerBuilder != null)
          widget.footerBuilder!(context, !_busy && !_closed),
        if (_closed) Text(AppLocalizations.of(context).homeCardDataChanged),
        if (_result case final result?)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: widget.resultBuilder(context, _capability!, result),
          ),
      ],
    ),
  );
}
