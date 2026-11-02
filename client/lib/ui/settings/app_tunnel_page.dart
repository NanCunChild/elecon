import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/transport/hermes/hermes.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';

class AppTunnelPage extends StatefulWidget {
  const AppTunnelPage({super.key});
  @override
  State<AppTunnelPage> createState() => _AppTunnelPageState();
}

class _AppTunnelPageState extends State<AppTunnelPage> {
  final _gateway = TextEditingController();
  final _pin = TextEditingController();
  SessionController? _session;
  String? _school;
  String? _choice;
  HermesConfigurationInfo? _configuration;
  bool _busy = true;
  bool _failed = false;
  int _request = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.of(context);
    if (!identical(_session, session) ||
        _school != session.selectedSchool?.id) {
      _session = session;
      _school = session.selectedSchool?.id;
      _choice = null;
      _configuration = null;
      _gateway.clear();
      _pin.clear();
      _busy = true;
      _failed = false;
      _load();
    }
  }

  @override
  void dispose() {
    _request++;
    _gateway.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    final session = _session!;
    final school = _school;
    try {
      final choice = await session.appTunnelChoice();
      final configuration = session.hermesConfigurationInfo();
      if (!mounted ||
          request != _request ||
          !identical(session, _session) ||
          session.selectedSchool?.id != school) {
        return;
      }
      setState(() {
        _choice = choice;
        _configuration = configuration;
        _gateway.text = configuration?.gatewayUrl ?? '';
        _pin.text = configuration?.nodeCertificateSha256 ?? '';
        _busy = false;
        _failed = false;
      });
    } catch (_) {
      if (mounted &&
          request == _request &&
          identical(session, _session) &&
          session.selectedSchool?.id == school) {
        setState(() {
          _busy = false;
          _failed = true;
          _choice = 'invalid-configuration';
          _configuration = null;
          _gateway.clear();
          _pin.clear();
        });
      }
    }
  }

  Future<void> _select(String value) async {
    if (_busy) return;
    final request = ++_request;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await _session!.selectAppTunnel(value == 'direct' ? null : value);
      if (!mounted || request != _request) return;
      setState(() => _choice = value == 'direct' ? null : value);
    } catch (_) {
      if (mounted && request == _request) setState(() => _failed = true);
    } finally {
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  Future<void> _login() async {
    if (_busy) return;
    final request = ++_request;
    setState(() {
      _busy = true;
      _failed = false;
    });
    HermesLoginBridge? bridge;
    try {
      bridge = await _session!.createHermesLoginBridge(
        gatewayUrl: _gateway.text,
        nodeCertificateSha256: _pin.text,
      );
      if (!mounted || request != _request) {
        bridge.dispose();
        return;
      }
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => _HermesLoginPage(bridge: bridge!)),
      );
      if (mounted && request == _request) await _load();
    } catch (_) {
      if (mounted && request == _request) setState(() => _failed = true);
    } finally {
      bridge?.dispose();
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await _session!.clearHermesConfiguration();
      if (mounted) await _load();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = _session!;
    final providers = session.appTunnelProviders;
    final hermes = providers.where((p) => p.id == 'hermes-atrust').firstOrNull;
    final known = _choice == null || providers.any((p) => p.id == _choice);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTunnelTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(l10n.appTunnelDescription),
            const SizedBox(height: 16),
            if (_school == null)
              Text(l10n.appTunnelSelectSchool)
            else ...[
              DropdownButtonFormField<String>(
                key: ValueKey('${_school}_${_choice ?? 'direct'}'),
                initialValue: _choice ?? 'direct',
                isExpanded: true,
                decoration: InputDecoration(labelText: l10n.appTunnelChoice),
                items: [
                  DropdownMenuItem(
                    value: 'direct',
                    child: Text(l10n.appTunnelDirect),
                  ),
                  for (final provider in providers)
                    DropdownMenuItem(
                      value: provider.id,
                      child: Text(provider.name),
                    ),
                  if (!known)
                    DropdownMenuItem(
                      value: _choice,
                      child: Text(l10n.appTunnelUnavailable),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value != null) _select(value);
                      },
              ),
              if (_choice != null &&
                  (!known ||
                      providers
                              .where((p) => p.id == _choice)
                              .firstOrNull
                              ?.isAvailable !=
                          true))
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(l10n.appTunnelUnavailable),
                ),
              const SizedBox(height: 24),
              if (hermes != null) ...[
                Text(
                  'Hermes / aTrust',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _gateway,
                  enabled: !_busy,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: l10n.appTunnelGateway,
                    hintText: 'https://',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pin,
                  enabled: !_busy,
                  autocorrect: false,
                  maxLength: 64,
                  decoration: InputDecoration(
                    labelText: l10n.appTunnelCertificate,
                  ),
                ),
                Text(
                  l10n.appTunnelCertificateHelp,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Text(
                  _configuration == null
                      ? l10n.appTunnelSignedOut
                      : l10n.appTunnelSessionSaved,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed: _busy || !hermes.isAvailable ? null : _login,
                      child: Text(l10n.appTunnelLogin),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _clear,
                      child: Text(l10n.appTunnelClear),
                    ),
                  ],
                ),
              ],
            ],
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: LinearProgressIndicator(),
              ),
            if (_failed)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  l10n.appTunnelFailed,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HermesLoginPage extends StatefulWidget {
  const _HermesLoginPage({required this.bridge});
  final HermesLoginBridge bridge;
  @override
  State<_HermesLoginPage> createState() => _HermesLoginPageState();
}

class _HermesLoginPageState extends State<_HermesLoginPage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.bridge.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      widget.bridge.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final bridge = widget.bridge;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTunnelLogin)),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(l10n.appTunnelLoginHelp),
            ),
            Expanded(
              child: InAppWebView(
                initialSettings: bridge.settings,
                onWebViewCreated: bridge.attach,
                shouldOverrideUrlLoading: bridge.navigation,
                onLoadStart: bridge.loadStarted,
                onReceivedError: (_, request, _) {
                  if (request.isForMainFrame != false) bridge.platformError();
                },
                onReceivedServerTrustAuthRequest: (_, _) async =>
                    ServerTrustAuthResponse(
                      action: ServerTrustAuthResponseAction.CANCEL,
                    ),
              ),
            ),
            ValueListenableBuilder<HermesLoginState>(
              valueListenable: bridge.state,
              builder: (context, state, _) => Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (state.origin != null)
                      Text(
                        state.origin!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (state.phase == HermesLoginPhase.checking)
                      const LinearProgressIndicator(),
                    if (state.error != null)
                      Text(
                        l10n.appTunnelLoginFailed,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (state.phase == HermesLoginPhase.closed)
                      Text(l10n.appTunnelLoginCancelled),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed:
                          state.phase == HermesLoginPhase.checking ||
                              state.phase == HermesLoginPhase.closed
                          ? null
                          : () async {
                              final result = await bridge.finish();
                              if (result && context.mounted) {
                                Navigator.pop(context, true);
                              }
                            },
                      child: Text(l10n.appTunnelLoginComplete),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
