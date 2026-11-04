/// Fixed native password input. Saved secrets never enter this widget.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/scripts/account_auth.dart';
import '../../l10n/gen/app_localizations.dart';

Future<ScriptPasswordInput?> presentScriptPassword(
  BuildContext context,
  ScriptPasswordPrompt request,
  bool Function() isActive,
) async {
  if (!context.mounted || !isActive() || !request.isActive()) {
    throw const ScriptAccountException('invocation_cancelled');
  }
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<ScriptPasswordInput>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ScriptPasswordDialog(request: request),
  );
  final monitor = Timer.periodic(const Duration(milliseconds: 50), (_) {
    if ((!context.mounted || !isActive() || !request.isActive()) &&
        route.isActive &&
        navigator.mounted) {
      navigator.removeRoute(route);
    }
  });
  try {
    final value = await navigator.push(route);
    if (!context.mounted || !isActive() || !request.isActive()) {
      throw const ScriptAccountException('invocation_cancelled');
    }
    return value;
  } finally {
    monitor.cancel();
  }
}

class ScriptPasswordDialog extends StatefulWidget {
  const ScriptPasswordDialog({super.key, required this.request});
  final ScriptPasswordPrompt request;
  @override
  State<ScriptPasswordDialog> createState() => _ScriptPasswordDialogState();
}

class _ScriptPasswordDialogState extends State<ScriptPasswordDialog> {
  late final _username = TextEditingController(text: widget.request.username);
  final _password = TextEditingController();
  bool _remember = true;
  bool _invalid = false;
  void _close(ScriptPasswordInput? input) {
    _username.clear();
    _password.clear();
    Navigator.of(context).pop(input);
  }

  @override
  void dispose() {
    _username.clear();
    _username.dispose();
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.accountPasswordTitle),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.request.accountName),
              if (widget.request.instructions case final instructions?)
                Text(instructions),
              if (widget.request.tunnel case final tunnel?) ...[
                Text(l10n.scriptTunnelManagedDescription),
                Text(tunnel.gatewayUrl),
                ExpansionTile(
                  title: Text(l10n.appTunnelTitle),
                  children: [
                    ListTile(
                      title: Text(l10n.appTunnelDomain),
                      subtitle: Text(
                        tunnel.loginDomain.isEmpty
                            ? l10n.scriptTunnelDefaultDomain
                            : tunnel.loginDomain,
                      ),
                    ),
                    ListTile(
                      title: Text(l10n.appTunnelCertificate),
                      subtitle: Text(
                        tunnel.nodeCertificateSha256 ??
                            l10n.scriptTunnelSystemCertificate,
                      ),
                    ),
                  ],
                ),
              ],
              if (widget.request.blocked)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(l10n.accountPasswordBlocked),
                ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('account-password-username'),
                controller: _username,
                enableSuggestions: false,
                autocorrect: false,
                enableIMEPersonalizedLearning: false,
                maxLength: 256,
                decoration: InputDecoration(
                  labelText: l10n.accountPasswordUsername,
                ),
              ),
              TextField(
                key: const ValueKey('account-password-secret'),
                controller: _password,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                enableIMEPersonalizedLearning: false,
                maxLength: 4096,
                decoration: InputDecoration(
                  labelText: l10n.accountPasswordPassword,
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.accountPasswordRemember),
                value: _remember,
                onChanged: (value) =>
                    setState(() => _remember = value ?? false),
              ),
              if (_invalid)
                Text(
                  l10n.accountPasswordInvalid,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (widget.request.hasSavedPassword)
                OutlinedButton(
                  key: const ValueKey('account-password-use-saved'),
                  onPressed: () => _close(const ScriptPasswordInput.saved()),
                  child: Text(l10n.accountPasswordUseSaved),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _close(null),
          child: Text(l10n.commonCancel),
        ),
        if (widget.request.allowWeb)
          TextButton(
            key: const ValueKey('account-password-web'),
            onPressed: () => _close(const ScriptPasswordInput.web()),
            child: Text(l10n.accountPasswordWeb),
          ),
        FilledButton(
          key: const ValueKey('account-password-submit'),
          onPressed: () {
            if (_username.text.trim().isEmpty ||
                _password.text.isEmpty ||
                _username.text.length > 256 ||
                _password.text.length > 4096 ||
                RegExp(
                  r'[\x00-\x1f\x7f]',
                ).hasMatch(_username.text + _password.text)) {
              setState(() => _invalid = true);
              return;
            }
            _close(
              ScriptPasswordInput(
                username: _username.text.trim(),
                password: _password.text,
                remember: _remember,
              ),
            );
          },
          child: Text(l10n.accountPasswordSubmit),
        ),
      ],
    );
  }
}
