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
typedef QueryFormDeferredLoader =
    Future<QueryForm> Function(
      Map<String, dynamic> current,
      List<String> fields,
      ScriptRunCancellation cancellation,
    );

class QueryFormDialog extends StatefulWidget {
  const QueryFormDialog({
    super.key,
    required this.load,
    required this.current,
    required this.isActive,
    required this.session,
    this.loadDeferred,
  });
  final QueryFormLoader load;
  final QueryFormDeferredLoader? loadDeferred;
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
  final _baseFields = <String, QueryFormField>{};
  Timer? _debounce;
  int _revision = 0;
  int _deferredRevision = 0;
  ScriptRunCancellation? _deferredCancellation;
  bool _deferredFailed = false;
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
      _cancelDeferred();
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
    _cancelDeferred();
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
    _cancelDeferred();
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
          if (!field.deferred &&
              field.isChoice &&
              value != null &&
              !field.accepts(value)) {
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
        _baseFields
          ..clear()
          ..addEntries(next.fields.map((field) => MapEntry(field.id, field)));
        _loading = false;
      });
      unawaited(_resolveDeferred());
    } catch (_) {
      if (!mounted || !widget.isActive() || revision != _revision) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _cancelDeferred() {
    _deferredRevision++;
    _deferredCancellation?.cancel();
    _deferredCancellation = null;
    _deferredFailed = false;
  }

  Future<void> _resolveDeferred() async {
    final loader = widget.loadDeferred;
    final form = _form;
    if (loader == null || form == null || !widget.isActive()) return;
    final fields = form.fields
        .where(
          (field) =>
              field.deferred &&
              !field.disabled &&
              field.dependsOn.every((id) {
                final dependency = form.fields.firstWhere(
                  (entry) => entry.id == id,
                );
                return !dependency.disabled && dependency.accepts(_values[id]);
              }),
        )
        .toList();
    if (fields.isEmpty) return;
    _cancelDeferred();
    final revision = _deferredRevision;
    final cancellation = ScriptRunCancellation();
    _deferredCancellation = cancellation;
    final keys = {
      for (final field in fields) ...[field.id, ...field.dependsOn],
    };
    final current = Map<String, dynamic>.from(
      jsonDecode(
        jsonEncode({
          for (final entry in _metadataDraft().entries)
            if (keys.contains(entry.key)) entry.key: entry.value,
        }),
      ),
    );
    setState(() => _deferredFailed = false);
    try {
      final result = await loader(
        current,
        fields.map((field) => field.id).toList(),
        cancellation,
      );
      if (!mounted || !widget.isActive() || revision != _deferredRevision) {
        return;
      }
      final resolved = <String, QueryFormField>{};
      for (final field in fields) {
        final next = result.fields
            .where((candidate) => candidate.id == field.id)
            .firstOrNull;
        if (next == null ||
            next.kind != field.kind ||
            next.deferred ||
            next.required ||
            next.initialValue != null ||
            next.dependsOn.length != field.dependsOn.length ||
            !next.dependsOn.toSet().containsAll(field.dependsOn)) {
          throw const FormatException('invalid_deferred_query_field');
        }
        // A resolved but unavailable optional field stays hidden. Keep an old
        // selection pending until it can be validated or explicitly cleared.
        resolved[field.id] = next.disabled ? field : next;
      }
      setState(() {
        _form = QueryForm(
          target: form.target,
          title: form.title,
          submitLabel: form.submitLabel,
          fields: [
            for (final field in _form!.fields) resolved[field.id] ?? field,
          ],
        );
        for (final field in resolved.values) {
          if (!field.deferred && !field.accepts(_values[field.id])) {
            _validate = true;
          }
        }
        _deferredFailed = resolved.values.any(
          (field) => field.deferred && _values.containsKey(field.id),
        );
      });
    } catch (_) {
      if (!mounted || !widget.isActive() || revision != _deferredRevision) {
        return;
      }
      setState(() => _deferredFailed = true);
    } finally {
      if (identical(_deferredCancellation, cancellation)) {
        _deferredCancellation = null;
      }
      cancellation.dispose();
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
    if (reload) _cancelDeferred();
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
      if (reload) {
        final form = _form!;
        _form = QueryForm(
          target: form.target,
          title: form.title,
          submitLabel: form.submitLabel,
          fields: [
            for (final field in form.fields)
              if (descendants.contains(field.id))
                _baseFields[field.id] ?? field
              else
                field,
          ],
        );
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
    if (!mounted) return;
    if (!widget.isActive()) {
      _checkIdentity();
      return;
    }
    if (picked == null) return;
    final text =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    _editor(field.id, text, sync: true);
    _change(field, text);
  }

  Future<void> _pickTime(QueryFormField field, String edge) async {
    final range = _values[field.id];
    final value = range is Map ? range[edge] : null;
    final parts = value is String && queryTime(value) ? value.split(':') : null;
    final picked = await showTimePicker(
      context: context,
      initialTime: parts == null
          ? TimeOfDay.now()
          : TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (!mounted) return;
    if (!widget.isActive()) {
      _checkIdentity();
      return;
    }
    if (picked == null) return;
    final text =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    _editor('range:${field.id}:$edge', text, sync: true);
    _change(field, {
      if (range is Map) ...Map<String, dynamic>.from(range),
      edge: text,
    });
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
    InputDecoration decoration({String? label, bool showHelp = true}) =>
        InputDecoration(
          labelText: '${label ?? field.label}${field.required ? ' *' : ''}',
          helperText: !showHelp || help.isEmpty ? null : help,
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
              for (final value in selected)
                if (!field.options.any((option) => option.value == value))
                  InputChip(
                    label: Text(value),
                    deleteIcon: const Icon(Icons.close, size: 18),
                    onDeleted: enabled
                        ? () => _change(
                            field,
                            selected.where((item) => item != value).toList(),
                          )
                        : null,
                  ),
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
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${field.label}${field.required ? ' *' : ''}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Row(
              children: [
                for (final edge in ['start', 'end'])
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(left: edge == 'end' ? 8 : 0),
                      child: TextField(
                        key: ValueKey('query-control-${field.id}-$edge'),
                        controller: _editor('range:${field.id}:$edge', ''),
                        enabled: enabled,
                        readOnly: true,
                        onTap: enabled ? () => _pickTime(field, edge) : null,
                        decoration:
                            decoration(
                              showHelp: false,
                              label: edge == 'start'
                                  ? l10n.classroomStartTime('')
                                  : l10n.classroomEndTime(''),
                            ).copyWith(
                              suffixIcon: const Icon(Icons.schedule, size: 20),
                            ),
                      ),
                    ),
                  ),
              ],
            ),
            if (help.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(help, style: Theme.of(context).textTheme.bodySmall),
              ),
            if (!field.required && _values.containsKey(field.id))
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  key: ValueKey('query-control-${field.id}-clear'),
                  onPressed: enabled
                      ? () {
                          _editor('range:${field.id}:start', '', sync: true);
                          _editor('range:${field.id}:end', '', sync: true);
                          _change(field, null);
                        }
                      : null,
                  child: Text(l10n.queryClearCondition),
                ),
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
                if (!field.deferred)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: _field(field),
                  ),
              for (final field in _form?.fields ?? const <QueryFormField>[])
                if (field.deferred && _values.containsKey(field.id))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(field.label),
                    subtitle: Text(
                      l10n.queryPendingSelection(_values[field.id].toString()),
                    ),
                    trailing: IconButton(
                      tooltip: l10n.queryClearCondition,
                      onPressed: () => _change(field, null),
                      icon: const Icon(Icons.clear),
                    ),
                  ),
              if (_deferredFailed)
                TextButton.icon(
                  onPressed: _resolveDeferred,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(l10n.queryOptionalRetry),
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
                  _cancelDeferred();
                  Navigator.pop(context, values);
                },
          child: Text(_form?.submitLabel ?? l10n.queryFilters),
        ),
      ],
    );
  }
}
