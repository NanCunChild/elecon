/// 🔒 ADR-037 §1–§2: fixed transient forms, no storage or school field logic.
/// Redlines #1/#5/#7: only this run's request/response crosses the UI boundary.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/scripts/input.dart';
import '../../core/scripts/manifest.dart';
import '../../core/scripts/runtime.dart';
import '../../l10n/gen/app_localizations.dart';

Future<Object?> presentScriptInput(
  BuildContext context,
  ScriptPackage package,
  Future<Object?> Function(ScriptInputCall input) execute, {
  void Function()? onCancel,
}) async {
  DialogRoute<Map<String, String>>? route;
  NavigatorState? navigator;
  Timer? monitor;
  final closed = Completer<Object?>();
  var completed = false;
  Future<Object?> input(ScriptInputRequest request) async {
    if (completed || !context.mounted) {
      throw const ScriptRunException('invocation_cancelled');
    }
    if (route != null) throw const ScriptRunException('input_busy');
    navigator = Navigator.of(context, rootNavigator: true);
    final dialog = DialogRoute<Map<String, String>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ScriptInputDialog(package: package, request: request),
    );
    route = dialog;
    monitor ??= Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!context.mounted && !closed.isCompleted) {
        onCancel?.call();
        closed.completeError(const ScriptRunException('invocation_cancelled'));
      }
    });
    try {
      final result = await navigator!.push(dialog);
      if (completed || !context.mounted) {
        throw const ScriptRunException('invocation_cancelled');
      }
      return result;
    } finally {
      if (identical(route, dialog)) route = null;
    }
  }

  try {
    return await Future.any([execute(input), closed.future]);
  } finally {
    completed = true;
    monitor?.cancel();
    final dialog = route;
    if (dialog != null && dialog.isActive && navigator?.mounted == true) {
      navigator!.removeRoute(dialog);
    }
  }
}

class ScriptInputDialog extends StatefulWidget {
  const ScriptInputDialog({
    super.key,
    required this.package,
    required this.request,
  });
  final ScriptPackage package;
  final ScriptInputRequest request;
  @override
  State<ScriptInputDialog> createState() => _ScriptInputDialogState();
}

class _ScriptInputDialogState extends State<ScriptInputDialog> {
  final _form = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  final _choices = <String, String?>{};

  @override
  void initState() {
    super.initState();
    for (final field in widget.request.fields) {
      if (field.type == ScriptInputType.select) {
        _choices[field.id] = field.initialValue;
      } else {
        _controllers[field.id] = TextEditingController(
          text: field.initialValue ?? '',
        );
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (!mounted || _form.currentState?.validate() != true) return;
    final values = <String, String>{
      for (final field in widget.request.fields)
        field.id: field.type == ScriptInputType.select
            ? _choices[field.id] ?? ''
            : _controllers[field.id]!.text,
    };
    _close(values);
  }

  void _close([Map<String, String>? values]) {
    if (!mounted) return;
    for (final controller in _controllers.values) {
      controller.clear();
    }
    Navigator.of(context).pop(values);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.scriptsInputTitle),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${widget.package.manifest.name} · ${widget.package.manifest.schoolId}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Text(
                  widget.request.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (widget.request.message case final message?)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(message),
                  ),
                for (final field in widget.request.fields)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: field.type == ScriptInputType.select
                        ? DropdownButtonFormField<String>(
                            key: ValueKey('script-input-${field.id}'),
                            initialValue: _choices[field.id],
                            isExpanded: true,
                            decoration: InputDecoration(labelText: field.label),
                            items: [
                              if (!field.isRequired)
                                DropdownMenuItem(
                                  value: '',
                                  child: Text(l10n.scriptsInputNoSelection),
                                ),
                              for (final option in field.options)
                                DropdownMenuItem(
                                  value: option.value,
                                  child: Text(option.label),
                                ),
                            ],
                            onChanged: (value) => _choices[field.id] = value,
                            validator: (value) => field.accepts(value ?? '')
                                ? null
                                : l10n.scriptsInputInvalid,
                          )
                        : TextFormField(
                            key: ValueKey('script-input-${field.id}'),
                            controller: _controllers[field.id],
                            autofocus:
                                widget.request.fields.first.id == field.id,
                            obscureText: field.type == ScriptInputType.password,
                            enableSuggestions: false,
                            enableIMEPersonalizedLearning: false,
                            autocorrect: false,
                            maxLength: field.maxLength,
                            decoration: InputDecoration(labelText: field.label),
                            textInputAction: TextInputAction.next,
                            validator: (value) => field.accepts(value ?? '')
                                ? null
                                : l10n.scriptsInputInvalid,
                          ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _close, child: Text(l10n.commonCancel)),
        FilledButton(onPressed: _submit, child: Text(l10n.scriptsInputSubmit)),
      ],
    );
  }
}
