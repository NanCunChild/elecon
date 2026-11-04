/// ADR-034 §5/§6: run the selected source provider's existing login entry.
/// URLs, DOM checks and credential capture stay inside the trusted script.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../catalog/schools.dart';
import '../../core/adapter_service.dart';
import '../../core/scripts/runtime.dart';
import '../../core/scripts/manifest.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../scripts/script_presenter.dart';
import '../settings/app_tunnel_page.dart';
import '../../session/session_scope.dart';
import '../scripts/script_input_presenter.dart';
import '../scripts/script_password_dialog.dart';
import '../security/no_hardware_warning_dialog.dart';
import 'webview_login_page.dart';

class ScriptLoginPage extends StatefulWidget {
  const ScriptLoginPage({
    super.key,
    required this.session,
    required this.school,
    this.requiredRef,
    this.package,
    this.accountId,
  });
  final SessionController session;
  final SchoolDescriptor school;
  final String? requiredRef;
  final ScriptPackage? package;
  final String? accountId;

  @override
  State<ScriptLoginPage> createState() => _ScriptLoginPageState();
}

class _ScriptLoginPageState extends State<ScriptLoginPage> {
  bool _finished = false;
  final _cancellation = ScriptRunCancellation();
  late final int _generation;
  Future<void>? _tunnelPage;
  bool _tunnelAuthenticated = false;

  @override
  void initState() {
    super.initState();
    _generation = widget.session.trustedScriptViewGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) => _login());
  }

  void _finish(WebViewLoginResult result) {
    if (!mounted || _finished) return;
    setState(() => _finished = true);
    // Let PopScope rebuild before popping the completed operation.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      final route = ModalRoute.of(context);
      if (route?.isCurrent == true) {
        navigator.pop(result);
      } else if (route?.isActive == true) {
        // A timed-out input may still be on top until its cancellation tick.
        // Complete this login route, never pop a differently typed dialog.
        navigator.removeRoute(route!, result);
      }
    });
  }

  void _cancel() {
    _cancellation.cancel();
    _finish(const WebViewLoginResult(status: WebViewLoginStatus.cancelled));
  }

  Future<void> _login() async {
    final session = widget.session;
    session.onCredentialsChanged(identityChanged: true);
    final generation = _generation;
    final l10n = AppLocalizations.of(context);
    try {
      final registry = await session.scriptRegistry;
      if (!mounted || _finished) return;
      if (generation != session.trustedScriptViewGeneration) {
        _cancel();
        return;
      }
      // The unified source packages expose manual authentication through their
      // existing generic.section entry (ADR-034). Never run an unrelated
      // provider or infer a login URL from the first allowed network origin.
      final id =
          widget.package?.manifest.id ??
          widget.school.adapterId.substring('script:'.length);
      final installation = registry.find(id);
      final package = installation?.package;
      final requestedAccountId =
          widget.accountId ??
          (widget.requiredRef == null &&
                  (package?.manifest.sdkVersion ?? 0) >= 14
              ? package?.manifest.accounts
                    .where((a) => a.authentication != null)
                    .firstOrNull
                    ?.id
              : null);
      var account = package?.manifest.accounts
          .where((a) => a.id == requestedAccountId)
          .firstOrNull;
      if (account?.appTunnelAccountId case final dependency?) {
        final target = package!.manifest.accounts.firstWhere(
          (a) => a.id == dependency,
        );
        if (!session.hasDeclaredTunnelConfiguration(target.appTunnel!)) {
          account = target;
        }
      }
      final capability = requestedAccountId == null
          ? 'generic.section'
          : account?.loginCapability;
      if (session.selectedSchool?.id != widget.school.id ||
          installation?.enabled != true ||
          package == null ||
          (widget.package != null &&
              widget.package!.digest != package.digest) ||
          capability == null ||
          (!package.manifest.browser && package.manifest.sdkVersion < 3) ||
          package.manifest.schoolId != widget.school.id ||
          package.manifest.capability(capability) == null) {
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
      if (generation != session.trustedScriptViewGeneration) {
        _cancel();
        return;
      }
      final result = await presentScriptInput(
        context,
        package,
        (input) => presentScriptBrowser(
          context,
          package,
          (call) => session.runTrustedScript(
            id,
            capability,
            expectedDigest: package.digest,
            cancellation: _cancellation,
            browserCall: call,
            inputCall: input,
            passwordCall: (request) => presentScriptPassword(
              context,
              request,
              () =>
                  mounted &&
                  !_finished &&
                  !_cancellation.isCancelled &&
                  generation == session.trustedScriptViewGeneration,
            ),
            appTunnelLogin: () async {
              if (!mounted || _finished || _cancellation.isCancelled) {
                throw const ScriptRunException('invocation_cancelled');
              }
              if (account?.appTunnel case final tunnel?) {
                final bridge = await session.createHermesLoginBridge(
                  gatewayUrl: tunnel.gatewayUrl,
                  nodeCertificateSha256: tunnel.nodeCertificateSha256,
                  package: package,
                  isAuthorized: () =>
                      mounted && !_finished && !_cancellation.isCancelled,
                );
                if (!mounted || _finished || _cancellation.isCancelled) {
                  bridge.dispose();
                  throw const ScriptRunException('invocation_cancelled');
                }
                final page = Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => HermesLoginPage(bridge: bridge),
                  ),
                );
                _tunnelPage = page.then<void>((authenticated) {
                  _tunnelAuthenticated = authenticated == true;
                });
                try {
                  await _tunnelPage;
                } finally {
                  bridge.dispose();
                }
                if (!_tunnelAuthenticated) {
                  throw const ScriptRunException('invocation_cancelled');
                }
                return;
              }
              final page = Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => SessionScope(
                    controller: session,
                    child: AppTunnelPage(
                      onAuthenticated: () => _tunnelAuthenticated = true,
                    ),
                  ),
                ),
              );
              _tunnelPage = page;
              await page;
              if (!_tunnelAuthenticated) {
                throw const ScriptRunException('invocation_cancelled');
              }
            },
            params:
                account?.loginParams ??
                {
                  if (widget.requiredRef != null)
                    'requiredRef': widget.requiredRef,
                },
          ),
          onCancel: _cancellation.cancel,
        ),
        onCancel: _cancellation.cancel,
      );
      if (!mounted || _finished) return;
      await _tunnelPage;
      if (!mounted || _finished) return;
      if (_tunnelPage != null && !_tunnelAuthenticated) {
        _finish(const WebViewLoginResult(status: WebViewLoginStatus.cancelled));
        return;
      }
      var run = result as CapabilityRun;
      if (_tunnelPage != null &&
          account?.statusCapability != null &&
          !_cancellation.isCancelled &&
          session.selectedSchool?.id == widget.school.id) {
        run = await session.runTrustedScript(
          id,
          account!.statusCapability!,
          expectedDigest: package.digest,
          params: account.statusParams,
          cancellation: _cancellation,
        );
      }
      if (!mounted || _finished) return;
      final verified =
          run.ok &&
          (capability != 'account.session' ||
              run.data is Map &&
                  (run.data as Map)['status'] == 'authenticated');
      if (run.ok && widget.accountId == null) {
        unawaited(session.refreshHomeData());
      }
      _finish(
        WebViewLoginResult(
          status: verified
              ? WebViewLoginStatus.success
              : const {
                  'invocation_cancelled',
                  'script_cancelled',
                  'input_cancelled',
                }.contains(run.reason)
              ? WebViewLoginStatus.cancelled
              : WebViewLoginStatus.error,
          error: verified
              ? null
              : run.ok
              ? l10n.scriptAccountUnknown
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
    _cancellation.cancel();
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
              Text(
                widget.accountId == null
                    ? l10n.scriptsLoginRunning
                    : l10n.scriptAccountsSigningIn(
                        widget.package!.manifest.accounts
                            .firstWhere((a) => a.id == widget.accountId)
                            .name,
                      ),
              ),
              const SizedBox(height: 16),
              TextButton(onPressed: _cancel, child: Text(l10n.commonCancel)),
            ],
          ),
        ),
      ),
    );
  }
}
