/// ADR-071: fixed inputs bound to a source's declared read-only query.
library;

import 'package:elecon_contract/output_validator_registry.dart';
import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import 'capability_source.dart';
import 'query_section.dart';
import 'legacy_query_controls_model.dart';
import 'query_form_model.dart';
import 'query_form_dialog.dart';

bool _plain(String value) => !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
bool _date(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final parsed = DateTime.tryParse(value);
  return parsed != null &&
      parsed.year >= 1 &&
      parsed.year <= 9999 &&
      formatQueryDate(parsed) == value;
}

bool _time(String value) =>
    RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(value);

QueryControls? queryControlsFromDynamic(Object? raw, String target) {
  if (outputValidatorFor('elecon.query.controls', '1.0')?.call(raw) != true ||
      raw is! Map) {
    return null;
  }
  if (raw['target'] != target ||
      !_plain(raw['title']) ||
      !_plain(raw['submitLabel'])) {
    return null;
  }
  final controls = <QueryControlsControls>[];
  final ids = <String>{};
  final parameters = <String>{};
  for (final entry in raw['controls'] as List) {
    final item = entry as Map;
    final kind = item['kind'] as String;
    final parameter = item['parameter'] as String;
    final initial = item['initialValue'] as String?;
    final end = item['initialEnd'] as String?;
    if (!ids.add(item['id']) ||
        !parameters.add(parameter) ||
        !_plain(item['label']) ||
        (initial != null && !_plain(initial))) {
      return null;
    }
    final permitted = target == 'grades.list'
        ? parameter == 'term' && kind == 'select'
        : target == 'classroom.available' &&
              ((parameter == 'date' && kind == 'date') ||
                  (parameter == 'room' &&
                      (kind == 'text' || kind == 'select')) ||
                  (parameter == 'start' && kind == 'timeRange'));
    if (!permitted) return null;
    List<QueryControlsControlsOptions>? options;
    if (kind == 'select') {
      if (item['options'] is! List) return null;
      final values = <String>{};
      options = [];
      for (final option in item['options'] as List) {
        if (!values.add(option['value']) ||
            !_plain(option['label']) ||
            !_plain(option['value'])) {
          return null;
        }
        options.add(
          QueryControlsControlsOptions(
            value: option['value'],
            label: option['label'],
          ),
        );
      }
      if (initial != null && !values.contains(initial)) return null;
    } else if (item.containsKey('options')) {
      return null;
    }
    if (kind == 'date' && initial != null && !_date(initial)) return null;
    if (kind == 'timeRange') {
      if (!parameters.add('end') || (initial == null) != (end == null)) {
        return null;
      }
      if (initial != null &&
          (!_time(initial) || !_time(end!) || initial.compareTo(end) >= 0)) {
        return null;
      }
    } else if (end != null) {
      return null;
    }
    controls.add(
      QueryControlsControls(
        id: item['id'],
        kind: kind,
        label: item['label'],
        parameter: parameter,
        initialValue: initial,
        initialEnd: end,
        options: options,
      ),
    );
  }
  return QueryControls(
    target: target,
    title: raw['title'],
    submitLabel: raw['submitLabel'],
    controls: controls,
  );
}

/// Null rejects invalid selection. The result contains only controlled params;
/// absent optional values remove conditions, never become arbitrary JSON.
Map<String, dynamic>? queryControlValues(
  QueryControls controls,
  Map<String, String> values,
) {
  final result = <String, dynamic>{};
  for (final control in controls.controls) {
    final value = values[control.parameter] ?? '';
    if (value.length > 128 || !_plain(value)) return null;
    switch (control.kind) {
      case 'select':
        if (!control.options!.any((option) => option.value == value)) {
          return null;
        }
      case 'date':
        if (!_date(value)) return null;
      case 'timeRange':
        final end = values['end'] ?? '';
        if (value.isEmpty && end.isEmpty) continue;
        if (!_time(value) || !_time(end) || value.compareTo(end) >= 0) {
          return null;
        }
        result['end'] = end;
    }
    if (value.isNotEmpty) result[control.parameter] = value;
  }
  return result;
}

class ScriptQuerySelection {
  const ScriptQuerySelection({required this.supported, this.params});
  final bool supported;
  final Map<String, dynamic>? params;
}

/// Metadata belongs to the chosen business provider, never its own override.
Future<String?> scriptQueryControlsVersion(
  SessionController session,
  String target, {
  CapabilitySource? source,
}) async {
  final school = session.selectedSchool?.id;
  if (school == null) return null;
  final registry = await session.scriptRegistry;
  final installation = source == null ? null : registry.find(source.packageId);
  final package = source == null
      ? registry.provider(school, target)
      : installation?.package;
  if (package == null ||
      package.manifest.schoolId != school ||
      package.manifest.capability(target) == null ||
      package.requiresUpdate ||
      (source != null &&
          (installation?.enabled != true || package.digest != source.digest))) {
    return null;
  }
  return package.manifest.capability('query.controls')?.schemaVersion;
}

Future<ScriptQuerySelection> pickScriptQueryControls(
  BuildContext context,
  SessionController session,
  String target, {
  Map<String, dynamic>? current,
}) async {
  final generation = session.trustedScriptViewGeneration;
  final dataGeneration = session.trustedScriptDataGeneration;
  final locale = session.scriptLocale;
  final schoolId = session.selectedSchool?.id;
  final bound = CapabilitySourceScope.maybeOf(context)?.source;
  final registry = await session.scriptRegistry;
  bool active() =>
      context.mounted &&
      session.trustedScriptViewGeneration == generation &&
      session.trustedScriptDataGeneration == dataGeneration &&
      session.scriptLocale == locale &&
      session.selectedSchool?.id == schoolId &&
      CapabilitySourceScope.maybeOf(context)?.source == bound;
  if (!active() || schoolId == null) {
    return const ScriptQuerySelection(supported: true);
  }
  final install = bound == null ? null : registry.find(bound.packageId);
  final package = bound == null
      ? registry.provider(schoolId, target)
      : install?.package;
  if (package == null ||
      package.manifest.capability('query.controls') == null) {
    return const ScriptQuerySelection(supported: false);
  }
  if (package.requiresUpdate ||
      package.manifest.schoolId != schoolId ||
      package.manifest.capability(target) == null ||
      (bound != null &&
          (install?.enabled != true || package.digest != bound.digest))) {
    return const ScriptQuerySelection(supported: true);
  }
  if (package.manifest.capability('query.controls')!.schemaVersion == '2.0') {
    if (!context.mounted) return const ScriptQuerySelection(supported: true);
    bool currentSource() =>
        active() &&
        registry.find(package.manifest.id)?.enabled == true &&
        registry.find(package.manifest.id)?.package.digest == package.digest &&
        (bound != null ||
            registry.provider(schoolId, target)?.digest == package.digest);
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => QueryFormDialog(
        session: session,
        isActive: currentSource,
        current: current?['filters'] is Map
            ? Map<String, dynamic>.from(current!['filters'])
            : const {},
        load: (draft, changed) async {
          if (!currentSource()) throw const FormatException('script_cancelled');
          final result = await runOnceDecoded<QueryForm>(
            session,
            'query.controls',
            params: {
              'target': target,
              'current': draft,
              'changed': ?changed,
            },
            interactive: false,
            source: CapabilitySource(
              packageId: package.manifest.id,
              digest: package.digest,
            ),
            decode: (raw) => queryFormFromDynamic(raw, target),
          );
          if (!currentSource() || result.data == null) {
            throw const FormatException('query_controls_unavailable');
          }
          return result.data!;
        },
      ),
    );
    return ScriptQuerySelection(
      supported: true,
      params: currentSource() && selected != null
          ? {'filters': selected}
          : null,
    );
  }
  final result = await runOnceDecoded<QueryControls>(
    session,
    'query.controls',
    params: {'target': target},
    interactive: false,
    source: CapabilitySource(
      packageId: package.manifest.id,
      digest: package.digest,
    ),
    decode: (raw) => queryControlsFromDynamic(raw, target),
  );
  if (!context.mounted || !active()) {
    return const ScriptQuerySelection(supported: true);
  }
  final controls = result.data;
  if (controls == null) {
    throw FormatException(
      result.needLogin
          ? 'authentication_required'
          : 'query_controls_unavailable',
    );
  }
  final selected = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (context) =>
        _QueryControlsDialog(controls: controls, current: current ?? const {}),
  );
  if (!context.mounted || !active()) {
    return const ScriptQuerySelection(supported: true);
  }
  return ScriptQuerySelection(supported: true, params: selected);
}

class _QueryControlsDialog extends StatefulWidget {
  const _QueryControlsDialog({required this.controls, required this.current});
  final QueryControls controls;
  final Map<String, dynamic> current;
  @override
  State<_QueryControlsDialog> createState() => _QueryControlsDialogState();
}

class _QueryControlsDialogState extends State<_QueryControlsDialog> {
  final _values = <String, String>{};
  final _editors = <String, TextEditingController>{};
  bool _invalid = false;
  @override
  void initState() {
    super.initState();
    for (final control in widget.controls.controls) {
      var value =
          (widget.current[control.parameter] is String
              ? widget.current[control.parameter] as String
              : null) ??
          control.initialValue ??
          '';
      if (control.kind == 'select' &&
          !control.options!.any((o) => o.value == value)) {
        value = control.initialValue ?? '';
      }
      _values[control.parameter] = value;
      if (control.kind != 'select') {
        _editors[control.parameter] = TextEditingController(text: value);
      }
      if (control.kind == 'timeRange') {
        final end =
            (widget.current['end'] is String
                ? widget.current['end'] as String
                : null) ??
            control.initialEnd ??
            '';
        _values['end'] = end;
        _editors['end'] = TextEditingController(text: end);
      }
    }
  }

  @override
  void dispose() {
    for (final editor in _editors.values) {
      editor.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate(String parameter) async {
    final value = _values[parameter] ?? '';
    final current = _date(value) ? DateTime.parse(value) : DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
    );
    if (!mounted || picked == null) return;
    final selected = formatQueryDate(picked);
    _values[parameter] = selected;
    _editors[parameter]!.text = selected;
  }

  Future<void> _pickTime(String parameter) async {
    final value = _values[parameter] ?? '';
    final parts = _time(value)
        ? value.split(':').map(int.parse).toList()
        : null;
    final picked = await showTimePicker(
      context: context,
      initialTime: parts == null
          ? TimeOfDay.now()
          : TimeOfDay(hour: parts[0], minute: parts[1]),
    );
    if (!mounted || picked == null) return;
    final result =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    _values[parameter] = result;
    _editors[parameter]!.text = result;
  }

  Widget _input(
    String parameter,
    String label, {
    bool date = false,
    bool time = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        key: ValueKey('query-control-$parameter'),
        controller: _editors[parameter],
        maxLength: time
            ? 5
            : date
            ? 10
            : 128,
        keyboardType: date || time
            ? TextInputType.datetime
            : TextInputType.text,
        decoration: InputDecoration(
          labelText: label,
          counterText: '',
          suffixIcon: date || time
              ? IconButton(
                  onPressed: () =>
                      date ? _pickDate(parameter) : _pickTime(parameter),
                  icon: Icon(date ? Icons.calendar_today : Icons.schedule),
                  tooltip: label,
                )
              : null,
        ),
        onChanged: (value) => _values[parameter] = value,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.controls.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final control in widget.controls.controls)
                if (control.kind == 'select')
                  DropdownButtonFormField<String>(
                    key: ValueKey('query-control-${control.parameter}'),
                    initialValue: _values[control.parameter]!.isEmpty
                        ? null
                        : _values[control.parameter],
                    isExpanded: true,
                    decoration: InputDecoration(labelText: control.label),
                    items: [
                      for (final option in control.options!)
                        DropdownMenuItem(
                          value: option.value,
                          child: Text(
                            option.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) _values[control.parameter] = value;
                    },
                  )
                else if (control.kind == 'timeRange') ...[
                  _input(
                    'start',
                    '${control.label} · ${l10n.classroomStartTime('')}',
                    time: true,
                  ),
                  _input(
                    'end',
                    '${control.label} · ${l10n.classroomEndTime('')}',
                    time: true,
                  ),
                ] else
                  _input(
                    control.parameter,
                    control.label,
                    date: control.kind == 'date',
                  ),
              if (_invalid) Text(l10n.scriptsInputInvalid),
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
          onPressed: () {
            final params = queryControlValues(widget.controls, _values);
            if (params == null) {
              setState(() => _invalid = true);
              return;
            }
            Navigator.pop(context, params);
          },
          child: Text(widget.controls.submitLabel),
        ),
      ],
    );
  }
}
