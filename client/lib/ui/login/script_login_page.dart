/// ADR-034 §5/§6: run the selected source provider's existing login entry.
/// URLs, DOM checks and credential capture stay inside the trusted script.
library;

import 'package:flutter/material.dart';

import '../../catalog/schools.dart';
import '../../core/adapter_service.dart';
import '../../core/scripts/runtime.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../scripts/script_presenter.dart';
import '../scripts/script_input_presenter.dart';
import '../security/no_hardware_warning_dialog.dart';
import 'webview_login_page.dart';

class ScriptLoginPage extends StatefulWidget {
  const ScriptLoginPage({
    super.key,
    required this.session,
    required this.school,
    this.requiredRef,
  });
  final SessionController session;
  final SchoolDescriptor school;
  final String? requiredRef;

  @override
  State<ScriptLoginPage> createState() => _ScriptLoginPageState();
}

class _ScriptLoginPageState extends State<ScriptLoginPage> {
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _login());
  }

  void _finish(WebViewLoginResult result) {
    if (!mounted || _finished) return;
    setState(() => _finished = true);
    // Let PopScope rebuild before popping the completed operation.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  void _cancel() {
    widget.session.cancelTrustedScriptRuns();
    _finish(const WebViewLoginResult(status: WebViewLoginStatus.cancelled));
  }

  Future<void> _login() async {
    final session = widget.session;
    final l10n = AppLocalizations.of(context);
    try {
      final registry = await session.scriptRegistry;
      if (!mounted || _finished) return;
      // The unified source packages expose manual authentication through their
      // existing generic.section entry (ADR-034). Never run an unrelated
      // provider or infer a login URL from the first allowed network origin.
      final id = widget.school.adapterId.substring('script:'.length);
      final installation = registry.find(id);
      final package = installation?.package;
      if (session.selectedSchool?.id != widget.school.id ||
          installation?.enabled != true ||
          package == null ||
          (!package.manifest.browser && package.manifest.sdkVersion < 3) ||
          package.manifest.schoolId != widget.school.id ||
          package.manifest.capability('generic.section') == null) {
        _finish(
          WebViewLoginResult(
            status: WebViewLoginStatus.error,
            error: l10n.scriptsLoginUnavailable,
          ),
        );
        return;
      }
      await session.ensurePersistentStore(
        confirmSoftwareFallback: () async =>
            mounted &&
            !_finished &&
            await showNoHardwareWarningDialog(context) ==
                SoftwareStorageChoice.continueWithSoftware,
      );
      if (!mounted || _finished) return;
      final result = await presentScriptInput(
        context,
        package,
        (input) => presentScriptBrowser(
          context,
          package,
          (call) => session.runTrustedScript(
            id,
            'generic.section',
            browserCall: call,
            inputCall: input,
            params: {
              if (widget.requiredRef != null) 'requiredRef': widget.requiredRef,
            },
          ),
          onCancel: session.cancelTrustedScriptRuns,
        ),
        onCancel: session.cancelTrustedScriptRuns,
      );
      if (!mounted || _finished) return;
      final run = result as CapabilityRun;
      _finish(
        WebViewLoginResult(
          status: run.ok
              ? WebViewLoginStatus.success
              : const {
                  'invocation_cancelled',
                  'script_cancelled',
                  'input_cancelled',
                }.contains(run.reason)
              ? WebViewLoginStatus.cancelled
              : WebViewLoginStatus.error,
          error: run.ok
              ? null
              : l10n.scriptsFailed(run.reason ?? 'script_failed'),
        ),
      );
    } on ScriptRunException catch (error) {
      _finish(
        WebViewLoginResult(
          status:
              const {
                'invocation_cancelled',
                'script_cancelled',
                'input_cancelled',
              }.contains(error.code)
              ? WebViewLoginStatus.cancelled
              : WebViewLoginStatus.error,
          error: l10n.scriptsFailed(error.code),
        ),
      );
    } catch (_) {
      _finish(
        WebViewLoginResult(
          status: WebViewLoginStatus.error,
          error: l10n.scriptsLoginFailed,
        ),
      );
    }
  }

  @override
  void dispose() {
    if (!_finished) widget.session.cancelTrustedScriptRuns();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: _finished,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.settingsActionLogin)),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(l10n.scriptsLoginRunning),
              const SizedBox(height: 16),
              TextButton(onPressed: _cancel, child: Text(l10n.commonCancel)),
            ],
          ),
        ),
      ),
    );
  }
}
