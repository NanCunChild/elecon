/// ADR-082: draft-only native inputs, explicit submission and source-bound metadata.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../core/scripts/query_filters.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import 'query_form_model.dart';

typedef QueryFormLoader =
    Future<QueryForm> Function(Map<String, dynamic> current, String? changed);

class QueryFormDialog extends StatefulWidget {
  const QueryFormDialog({
    super.key,
    required this.load,
    required this.current,
    required this.isActive,
    required this.session,
  });
  final QueryFormLoader load;
  final Map<String, dynamic> current;
  final bool Function() isActive;
  final SessionController session;
  @override
  State<QueryFormDialog> createState() => _QueryFormDialogState();
}

class _QueryFormDialogState extends State<QueryFormDialog> {
  QueryForm? _form;
  final _values = <String, dynamic>{};
  final _editors = <String, TextEditingController>{};
  final _invalidNumbers = <String>{};
  final _seenFields = <String>{};
  Timer? _debounce;
  int _revision = 0;
  bool _loading = true, _failed = false, _validate = false;
  String? _changed;

  @override
  void initState() {
    super.initState();
    if (isQueryFilterMap(widget.current)) {
      _values.addAll(
        jsonDecode(jsonEncode(widget.current)) as Map<String, dynamic>,
      );
    }
    widget.session.addListener(_checkIdentity);
    unawaited(_reload());
  }

  void _checkIdentity() {
    if (mounted && !widget.isActive()) {
      _revision++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.pop(context);
        }
      });
      setState(() => _loading = true);
    }
  }

  @override
  void dispose() {
    _revision++;
    _debounce?.cancel();
    widget.session.removeListener(_checkIdentity);
    for (final controller in _editors.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _metadataDraft() => {
    for (final entry in _values.entries)
      if (isQueryFilterMap({entry.key: entry.value})) entry.key: entry.value,
  };

  Future<void> _reload() async {
    _debounce?.cancel();
    final revision = ++_revision;
    if (!widget.isActive()) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final snapshot = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(_metadataDraft())),
      );
      final next = await widget.load(snapshot, _changed);
      if (!mounted || !widget.isActive() || revision != _revision) return;
      setState(() {
        final declared = next.fields.map((field) => field.id).toSet();
        _values.removeWhere((key, _) => !declared.contains(key));
        _invalidNumbers.removeWhere((key) => !declared.contains(key));
        for (final field in next.fields) {
          final firstAppearance = _seenFields.add(field.id);
          final oldField = _form?.fields
              .where((old) => old.id == field.id)
              .firstOrNull;
          if (oldField != null && oldField.kind != field.kind) {
            _values.remove(field.id);
            _invalidNumbers.remove(field.id);
          }
          final value = _values[field.id];
          final compatible =
              value == null ||
              switch (field.kind) {
                'text' || 'date' || 'select' => value is String,
                'number' => value is num,
                'boolean' => value is bool,
                'multiSelect' =>
                  value is List && value.every((item) => item is String),
                'timeRange' => value is Map,
                _ => false,
              };
          if (!compatible) _values.remove(field.id);
          if (field.isChoice && value != null && !field.accepts(value)) {
            _values.remove(field.id);
          }
          if (firstAppearance &&
              !_values.containsKey(field.id) &&
              !_invalidNumbers.contains(field.id) &&
              field.initialValue != null) {
            _values[field.id] = field.initialValue;
          }
          if (field.kind == 'timeRange') {
            final range = _values[field.id];
            for (final edge in ['start', 'end']) {
              _editor(
                'range:${field.id}:$edge',
                range is Map ? range[edge]?.toString() ?? '' : '',
                sync: true,
              );
            }
          } else if (const ['text', 'number', 'date'].contains(field.kind) &&
              !_invalidNumbers.contains(field.id)) {
            _editor(field.id, _values[field.id]?.toString() ?? '', sync: true);
          }
        }
        _form = next;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !widget.isActive() || revision != _revision) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  TextEditingController _editor(String id, String value, {bool sync = false}) {
    final controller = _editors.putIfAbsent(
      id,
      () => TextEditingController(text: value),
    );
    if (sync && controller.text != value) controller.text = value;
    return controller;
  }

  void _change(
    QueryFormField field,
    Object? value, {
    bool invalidNumber = false,
  }) {
    if (!widget.isActive()) return;
    final descendants = _form!.descendants(field.id);
    final reload = descendants.isNotEmpty || _loading || _failed;
    _revision++;
    setState(() {
      if (value == null || value == '') {
        _values.remove(field.id);
      } else {
        _values[field.id] = value;
      }
      if (invalidNumber) {
        _invalidNumbers.add(field.id);
      } else {
        _invalidNumbers.remove(field.id);
      }
      for (final id in descendants) {
        _values.remove(id);
        _invalidNumbers.remove(id);
        _editors[id]?.clear();
        _editors['range:$id:start']?.clear();
        _editors['range:$id:end']?.clear();
      }
      _changed = field.id;
      if (reload) _loading = true;
    });
    if (reload) {
      _debounce?.cancel();
      _debounce = Timer(
        const Duration(milliseconds: 200),
        () => unawaited(_reload()),
      );
    }
  }

  Future<void> _pickDate(QueryFormField field) async {
    final value = _values[field.id];
    final picked = await showDatePicker(
      context: context,
      initialDate: value is String && queryDate(value)
          ? DateTime.parse(value)
          : DateTime.now(),
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
    );
    if (!mounted || picked == null || !widget.isActive()) return;
    final text =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    _editor(field.id, text, sync: true);
    _change(field, text);
  }

  Widget _field(QueryFormField field) {
    final l10n = AppLocalizations.of(context);
    final enabled = !field.disabled && widget.isActive();
    final error =
        (_validate &&
            !field.disabled &&
            (!field.accepts(_values[field.id]) ||
                _invalidNumbers.contains(field.id)))
        ? l10n.scriptsInputInvalid
        : null;
    final help = [
      if (field.description != null) field.description!,
      if (field.timeZone != null) field.timeZone!,
      if (field.disabledReason != null) field.disabledReason!,
    ].join(' · ');
    InputDecoration decoration({String? label}) => InputDecoration(
      labelText: '${label ?? field.label}${field.required ? ' *' : ''}',
      helperText: help.isEmpty ? null : help,
      helperMaxLines: 4,
      errorText: error,
    );
    final key = ValueKey('query-control-${field.id}');
    switch (field.kind) {
      case 'boolean':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CheckboxListTile(
              key: key,
              contentPadding: EdgeInsets.zero,
              title: Text(field.label),
              subtitle: help.isEmpty ? null : Text(help),
              tristate: true,
              value: _values[field.id] as bool?,
              onChanged: enabled ? (value) => _change(field, value) : null,
            ),
            if (error != null) Text(error),
          ],
        );
      case 'select':
        final value = _values[field.id] as String?;
        return DropdownButtonFormField<String>(
          key: ValueKey(
            '${key.value}/${value ?? ''}/${field.options.map((o) => o.value).join('|')}',
          ),
          initialValue: field.options.any((o) => o.value == value) ? value : '',
          isExpanded: true,
          decoration: decoration(),
          items: [
            DropdownMenuItem(
              value: '',
              child: Text(l10n.scriptsInputNoSelection),
            ),
            for (final option in field.options)
              DropdownMenuItem(
                value: option.value,
                child: Text(
                  option.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: enabled ? (value) => _change(field, value) : null,
        );
      case 'multiSelect':
        final selected = List<String>.from(_values[field.id] ?? const []);
        return InputDecorator(
          decoration: decoration(),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final option in field.options)
                FilterChip(
                  label: Text(option.label),
                  selected: selected.contains(option.value),
                  onSelected: enabled
                      ? (chosen) {
                          final next = List<String>.of(selected);
                          if (chosen) {
                            if (next.length >= 32) return;
                            next.add(option.value);
                          } else {
                            next.remove(option.value);
                          }
                          _change(field, next);
                        }
                      : null,
                ),
            ],
          ),
        );
      case 'timeRange':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final edge in ['start', 'end'])
              TextField(
                key: ValueKey('query-control-${field.id}-$edge'),
                controller: _editor('range:${field.id}:$edge', ''),
                enabled: enabled,
                keyboardType: TextInputType.datetime,
                maxLength: 5,
                decoration: decoration(
                  label:
                      '${field.label} · ${edge == 'start' ? l10n.classroomStartTime('') : l10n.classroomEndTime('')}',
                ),
                onChanged: (text) {
                  final range = _values[field.id];
                  final next = {
                    if (range is Map) ...Map<String, dynamic>.from(range),
                    edge: text,
                  };
                  _change(
                    field,
                    (next['start'] ?? '') == '' && (next['end'] ?? '') == ''
                        ? null
                        : next,
                  );
                },
              ),
          ],
        );
      default:
        return TextField(
          key: key,
          controller: _editor(field.id, ''),
          enabled: enabled,
          keyboardType: field.kind == 'number'
              ? const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                )
              : field.kind == 'date'
              ? TextInputType.datetime
              : TextInputType.text,
          maxLength: field.kind == 'text'
              ? field.maxLength
              : field.kind == 'date'
              ? 10
              : 64,
          decoration: decoration().copyWith(
            counterText: '',
            suffixIcon: field.kind == 'date'
                ? IconButton(
                    onPressed: enabled ? () => _pickDate(field) : null,
                    icon: const Icon(Icons.calendar_today),
                    tooltip: field.label,
                  )
                : null,
          ),
          onChanged: (text) {
            if (field.kind == 'number') {
              final number = num.tryParse(text);
              _change(
                field,
                number,
                invalidNumber:
                    text.isNotEmpty && (number == null || !number.isFinite),
              );
            } else {
              _change(field, text);
            }
          },
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(_form?.title ?? l10n.queryFilters),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_loading)
                LinearProgressIndicator(semanticsLabel: l10n.homeCardLoading),
              for (final field in _form?.fields ?? const <QueryFormField>[])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: _field(field),
                ),
              if (_failed) ...[
                Text(l10n.scriptsSourceResponseInvalid),
                TextButton.icon(
                  onPressed: _loading ? null : _reload,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.commonRetry),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          key: const ValueKey('query-form-submit'),
          onPressed: _loading || _failed || _form == null || !widget.isActive()
              ? null
              : () {
                  if (!widget.isActive()) {
                    Navigator.pop(context);
                    return;
                  }
                  final values = _form!.values(_values);
                  if (values == null ||
                      _form!.fields.any(
                        (field) =>
                            !field.disabled &&
                            _invalidNumbers.contains(field.id),
                      )) {
                    setState(() => _validate = true);
                    return;
                  }
                  Navigator.pop(context, values);
                },
          child: Text(_form?.submitLabel ?? l10n.queryFilters),
        ),
      ],
    );
  }
}
