/// ADR-034: inspect and explicitly trust local source packages before execution.
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/scripts/manifest.dart';
import '../../core/scripts/registry.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import '../security/no_hardware_warning_dialog.dart';
import 'script_presenter.dart';

class ScriptWorkbenchPage extends StatefulWidget {
  const ScriptWorkbenchPage({super.key});
  @override
  State<ScriptWorkbenchPage> createState() => _ScriptWorkbenchPageState();
}

class _ScriptWorkbenchPageState extends State<ScriptWorkbenchPage> {
  final _source = TextEditingController();
  final _params = TextEditingController(text: '{}');
  final Map<String, String> _capabilities = {};
  List<ScriptInstallation> _installed = [];
  SessionController? _session;
  bool _busy = false;
  String? _result;
  final List<String> _logs = [];
  int? _viewGeneration;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.of(context);
    if (_viewGeneration != session.trustedScriptViewGeneration) {
      _viewGeneration = session.trustedScriptViewGeneration;
      _result = null;
      _logs.clear();
    }
    if (!identical(_session, session)) {
      _session = session;
      _refresh();
    }
  }

  Future<void> _refresh() async {
    try {
      final registry = await _session!.scriptRegistry;
      if (mounted) setState(() => _installed = registry.installations);
    } catch (_) {
      if (mounted) _error('script_registry_unavailable');
    }
  }

  void _error(String code) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final message = switch (code) {
      'script_downgrade' ||
      'script_version_reused' ||
      'script_school_changed' => l10n.scriptsVersionRejected,
      'script_school_not_selected' => l10n.scriptsSchoolRequired,
      'script_browser_unavailable' ||
      'browser_unavailable' ||
      'browser_ip_policy_unsupported' => l10n.scriptsBrowserUnavailable,
      _ => l10n.scriptsFailed(code),
    };
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _guard(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
      await _refresh();
    } catch (error) {
      final code = error is StateError
          ? error.message.toString()
          : 'script_operation_failed';
      _error(code);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick() => _guard(() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (file == null) return;
    if ((file.lengthSync() ?? 0) > maxScriptPackageBytes) {
      throw StateError('package_too_large');
    }
    final bytes = <int>[];
    await for (final chunk in file.readAsByteStream()) {
      bytes.addAll(chunk);
      if (bytes.length > maxScriptPackageBytes) {
        throw StateError('package_too_large');
      }
    }
    _source.text = utf8.decode(bytes);
  });

  Future<void> _install() => _guard(() async {
    final package = ScriptPackage.parse(_source.text);
    final m = package.manifest;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.scriptsTrustTitle),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${m.name} · ${m.version}\n${m.id} · ${m.schoolId}'),
              const SizedBox(height: 16),
              Text(l10n.scriptsTrustBody),
              const SizedBox(height: 16),
              Text(l10n.scriptsNetwork),
              for (final origin in m.network.origins) Text(origin.toString()),
              const SizedBox(height: 12),
              Text(l10n.scriptsIp),
              Text(m.network.ipAllow?.join('\n') ?? l10n.scriptsIpNone),
              if (m.browser) ...[
                const SizedBox(height: 12),
                Text(l10n.scriptsBrowserPermission),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.scriptsApprove),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _session!.installTrustedScript(
      package,
      approvedDigest: package.digest,
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.scriptsInstalled)));
    }
  });

  Future<void> _run(ScriptInstallation installation) => _guard(() async {
    final session = _session!;
    final package = installation.package;
    if (session.selectedSchool?.id != package.manifest.schoolId) {
      throw StateError('script_school_not_selected');
    }
    final raw = jsonDecode(_params.text);
    if (raw is! Map<String, dynamic>) throw StateError('invalid_params');
    await session.ensurePersistentStore(
      confirmSoftwareFallback: () async {
        if (!mounted) return false;
        final choice = await showNoHardwareWarningDialog(context);
        return choice == SoftwareStorageChoice.continueWithSoftware;
      },
    );
    final capability =
        _capabilities[package.manifest.id] ??
        package.manifest.capabilities.first.id;
    // Browser presentation is installed locally too: the workbench is usable
    // from onboarding before MainShell exists.
    final previous = session.scriptBrowserPresenter;
    Future<Object?> temporary(
      ScriptPackage package,
      Future<Object?> Function(ScriptBrowserCall) execute,
    ) => presentScriptBrowser(
      context,
      package,
      execute,
      onCancel: session.cancelTrustedScriptRuns,
    );
    session.scriptBrowserPresenter = temporary;
    setState(() {
      _result = null;
      _logs.clear();
    });
    try {
      final run = await session.runTrustedScript(
        package.manifest.id,
        capability,
        params: raw,
        onLog: (level, message) {
          if (mounted &&
              _viewGeneration == session.trustedScriptViewGeneration) {
            setState(() {
              if (_logs.length == 100) _logs.removeAt(0);
              _logs.add('[$level] $message');
            });
          }
        },
      );
      if (!run.ok) throw StateError(run.reason ?? 'script_failed');
      if (mounted) {
        setState(
          () => _result = const JsonEncoder.withIndent('  ').convert(run.data),
        );
      }
    } finally {
      if (identical(session.scriptBrowserPresenter, temporary)) {
        session.scriptBrowserPresenter = previous;
      }
    }
  });

  Future<void> _remove(String id) => _guard(() async {
    final l10n = AppLocalizations.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.scriptsDelete),
        content: Text(l10n.scriptsDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.scriptsDelete),
          ),
        ],
      ),
    );
    if (yes == true) await _session!.removeTrustedScript(id);
  });

  @override
  void dispose() {
    if (_busy) _session?.cancelTrustedScriptRuns();
    _source.dispose();
    _params.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.scriptsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l10n.scriptsDescription),
          if (_session?.scriptRegistryRecovered ?? false)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(l10n.scriptsRegistryRecovered),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.file_open),
                label: Text(l10n.scriptsImportFile),
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _guard(() async {
                        _source.text =
                            (await Clipboard.getData(
                              Clipboard.kTextPlain,
                            ))?.text ??
                            '';
                      }),
                child: Text(l10n.scriptsPaste),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _guard(() async {
                        _source.text = await rootBundle.loadString(
                          'assets/trusted-script-example.elecon.json',
                        );
                      }),
                child: Text(l10n.scriptsExample),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _source,
            enabled: !_busy,
            minLines: 5,
            maxLines: 12,
            maxLength: maxScriptPackageBytes,
            decoration: InputDecoration(
              labelText: l10n.scriptsPackageLabel,
              border: const OutlineInputBorder(),
            ),
          ),
          FilledButton(
            onPressed: _busy ? null : _install,
            child: Text(l10n.scriptsInstall),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _params,
            enabled: !_busy,
            minLines: 1,
            maxLines: 4,
            maxLength: 65536,
            decoration: InputDecoration(labelText: l10n.scriptsParams),
          ),
          if (_busy) ...[
            const LinearProgressIndicator(),
            TextButton(
              onPressed: () => _session!.cancelTrustedScriptRuns(),
              child: Text(l10n.scriptsCancel),
            ),
          ],
          if (_installed.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(l10n.scriptsEmpty),
            ),
          for (final installation in _installed)
            _installation(installation, l10n),
          if (_logs.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(l10n.scriptsLogs),
            SelectableText(
              _logs.join('\n'),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
          if (_result != null) ...[
            const SizedBox(height: 16),
            Text(l10n.scriptsResult),
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: _result!)),
              child: Text(l10n.scriptsCopyResult),
            ),
            if (_result!.length > 65536) Text(l10n.scriptsResultPreview),
            SelectableText(
              _result!.length > 65536 ? _result!.substring(0, 65536) : _result!,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _installation(ScriptInstallation installation, AppLocalizations l10n) {
    final m = installation.package.manifest;
    final selected = _capabilities[m.id];
    final capability = m.capabilities.any((c) => c.id == selected)
        ? selected!
        : m.capabilities.first.id;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${m.name} · ${m.version}'),
              subtitle: Text('${m.id} · ${m.schoolId}'),
              value: installation.enabled,
              onChanged: _busy
                  ? null
                  : (enabled) => _guard(
                      () => _session!.enableTrustedScript(m.id, enabled),
                    ),
            ),
            DropdownButtonFormField<String>(
              initialValue: capability,
              key: ValueKey('${m.id}:${m.version}:$capability'),
              decoration: InputDecoration(
                labelText: l10n.scriptsSelectCapability,
              ),
              items: [
                for (final c in m.capabilities)
                  DropdownMenuItem(value: c.id, child: Text(c.id)),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      if (value != null) _capabilities[m.id] = value;
                    }),
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _busy || !installation.enabled
                      ? null
                      : () => _guard(
                          () => _session!.selectTrustedScriptSchool(m.id),
                        ),
                  child: Text(l10n.scriptsUseSchool),
                ),
                FilledButton(
                  onPressed: _busy || !installation.enabled
                      ? null
                      : () => _run(installation),
                  child: Text(_busy ? l10n.scriptsRunning : l10n.scriptsRun),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _remove(m.id),
                  child: Text(l10n.scriptsDelete),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
