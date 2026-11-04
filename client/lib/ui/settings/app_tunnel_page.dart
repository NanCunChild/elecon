import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/transport/hermes/hermes.dart';
import '../../core/transport/app_tunnel.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';

class AppTunnelPage extends StatefulWidget {
  const AppTunnelPage({super.key, this.onAuthenticated});
  final VoidCallback? onAuthenticated;
  @override
  State<AppTunnelPage> createState() => _AppTunnelPageState();
}

class _AppTunnelPageState extends State<AppTunnelPage> {
  final _gateway = TextEditingController();
  final _pin = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _domain = TextEditingController();
  SessionController? _session;
  String? _school;
  String? _choice;
  HermesConfigurationInfo? _configuration;
  HermesAccountInfo? _account;
  bool _dirty = false;
  bool _accountLoginRunning = false;
  bool _interactionRequired = false;
  bool _busy = true;
  bool _failed = false;
  int _request = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.of(context);
    if (!identical(_session, session) ||
        _school != session.selectedSchool?.id) {
      if (_accountLoginRunning) _session?.cancelHermesAccountLogin();
      _session = session;
      _school = session.selectedSchool?.id;
      _choice = null;
      _configuration = null;
      _account = null;
      _accountLoginRunning = false;
      _dirty = false;
      _interactionRequired = false;
      _gateway.clear();
      _pin.clear();
      _username.clear();
      _password.clear();
      _domain.clear();
      _busy = true;
      _failed = false;
      _load();
    }
  }

  @override
  void dispose() {
    _request++;
    if (_accountLoginRunning) _session?.cancelHermesAccountLogin();
    _gateway.dispose();
    _pin.dispose();
    _username.dispose();
    _password.clear();
    _password.dispose();
    _domain.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    final session = _session!;
    final school = _school;
    if (school == null) {
      setState(() => _busy = false);
      return;
    }
    try {
      final choice = await session.appTunnelChoice();
      final configuration = session.hermesConfigurationInfo();
      final account = session.hermesAccountInfo();
      if (!mounted ||
          request != _request ||
          !identical(session, _session) ||
          session.selectedSchool?.id != school) {
        return;
      }
      setState(() {
        _choice = choice;
        _configuration = configuration;
        _account = account;
        _gateway.text = account?.gatewayUrl ?? configuration?.gatewayUrl ?? '';
        _pin.text =
            account?.nodeCertificateSha256 ??
            configuration?.nodeCertificateSha256 ??
            '';
        _username.text = account?.username ?? '';
        _domain.text = account?.loginDomain ?? '';
        _password.clear();
        _dirty = false;
        _interactionRequired = false;
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
          _account = null;
          _gateway.clear();
          _pin.clear();
          _username.clear();
          _password.clear();
          _domain.clear();
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
      final authenticated = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => HermesLoginPage(bridge: bridge!)),
      );
      if (mounted && request == _request) {
        if (authenticated == true) widget.onAuthenticated?.call();
        await _load();
      }
    } catch (_) {
      if (mounted && request == _request) setState(() => _failed = true);
    } finally {
      bridge?.dispose();
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  Future<void> _clear() =>
      _accountOperation(_session!.clearHermesConfiguration);

  void _edited(String _) => setState(() => _dirty = true);

  Future<void> _saveAccount() async {
    final session = _session!;
    final password = _password.text;
    _password.clear();
    await _accountOperation(
      () => session.saveHermesAccount(
        gatewayUrl: _gateway.text,
        username: _username.text,
        password: password,
        loginDomain: _domain.text,
        nodeCertificateSha256: _pin.text,
      ),
    );
  }

  Future<void> _loginAccount() async {
    setState(() => _accountLoginRunning = true);
    try {
      await _accountOperation(() async {
        await _session!.loginHermesAccount();
        if (mounted) widget.onAuthenticated?.call();
      });
    } finally {
      if (mounted) setState(() => _accountLoginRunning = false);
    }
  }

  Future<void> _accountOperation(Future<void> Function() operation) async {
    if (_busy) return;
    final request = ++_request;
    setState(() {
      _busy = true;
      _failed = false;
      _interactionRequired = false;
    });
    try {
      await operation();
      if (mounted && request == _request) await _load();
    } catch (error) {
      if (mounted && request == _request) {
        setState(() {
          _failed = true;
          _interactionRequired =
              error is AppTunnelException &&
              error.code == 'hermes_interaction_required';
        });
      }
    } finally {
      if (mounted && request == _request) setState(() => _busy = false);
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
                  onChanged: _edited,
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
                  onChanged: _edited,
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
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('tunnel-username'),
                  controller: _username,
                  enabled: !_busy,
                  onChanged: _edited,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 256,
                  decoration: InputDecoration(
                    labelText: l10n.appTunnelUsername,
                  ),
                ),
                TextField(
                  key: const ValueKey('tunnel-password'),
                  controller: _password,
                  enabled: !_busy,
                  onChanged: _edited,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 4096,
                  decoration: InputDecoration(
                    labelText: l10n.appTunnelPassword,
                    helperText: l10n.appTunnelPasswordHelp,
                    helperMaxLines: 4,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('tunnel-domain'),
                  controller: _domain,
                  enabled: !_busy,
                  onChanged: _edited,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 256,
                  decoration: InputDecoration(
                    labelText: l10n.appTunnelDomain,
                    helperText: l10n.appTunnelDomainHelp,
                    helperMaxLines: 5,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _account == null
                      ? l10n.appTunnelAccountMissing
                      : l10n.appTunnelAccountSaved,
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
                    FilledButton.tonal(
                      onPressed: _busy ? null : _saveAccount,
                      child: Text(l10n.appTunnelSaveAccount),
                    ),
                    FilledButton.tonal(
                      onPressed:
                          _busy ||
                              _dirty ||
                              _account == null ||
                              !hermes.isAvailable
                          ? null
                          : _loginAccount,
                      child: Text(l10n.appTunnelAccountLogin),
                    ),
                    FilledButton(
                      onPressed: _busy || !hermes.isAvailable ? null : _login,
                      child: Text(l10n.appTunnelLogin),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _clear,
                      child: Text(l10n.appTunnelClear),
                    ),
                    if (_accountLoginRunning)
                      TextButton(
                        onPressed: session.cancelHermesAccountLogin,
                        child: Text(l10n.commonCancel),
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
                  _interactionRequired
                      ? l10n.appTunnelInteractionRequired
                      : l10n.appTunnelFailed,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class HermesLoginPage extends StatefulWidget {
  const HermesLoginPage({super.key, required this.bridge});
  final HermesLoginBridge bridge;
  @override
  State<HermesLoginPage> createState() => _HermesLoginPageState();
}

class _HermesLoginPageState extends State<HermesLoginPage>
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
