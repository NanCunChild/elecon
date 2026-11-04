/// ADR-082: native query field instances; business meanings belong to scripts.
library;

import 'dart:convert';
import '../../core/scripts/query_filters.dart';
import 'package:elecon_contract/output_validator_registry.dart';

bool queryPlainText(String value) =>
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
bool queryDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final parsed = DateTime.tryParse(value);
  return parsed != null &&
      parsed.year > 0 &&
      '${parsed.year.toString().padLeft(4, '0')}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}' ==
          value;
}

bool queryTime(String value) =>
    RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(value);

class QueryFormOption {
  const QueryFormOption(this.value, this.label);
  final String value, label;
}

class QueryFormField {
  QueryFormField(Map<String, dynamic> raw)
    : id = raw['id'],
      kind = raw['kind'],
      label = raw['label'],
      description = raw['description'],
      required = raw['required'] == true,
      disabled = raw['disabled'] == true,
      disabledReason = raw['disabledReason'],
      initialValue = raw['initialValue'],
      minimum = raw['minimum'],
      maximum = raw['maximum'],
      integer = raw['integer'] == true,
      maxLength = raw['maxLength'] ?? 512,
      timeZone = raw['timeZone'],
      dependsOn = List<String>.from(raw['dependsOn'] ?? const []),
      options = [
        for (final option in raw['options'] ?? const [])
          QueryFormOption(option['value'], option['label']),
      ];
  final String id, kind, label;
  final String? description, disabledReason, timeZone;
  final bool required, disabled, integer;
  final num? minimum, maximum;
  final int maxLength;
  final Object? initialValue;
  final List<String> dependsOn;
  final List<QueryFormOption> options;

  bool get isChoice => kind == 'select' || kind == 'multiSelect';
  bool accepts(Object? value) {
    if (value == null || value == '' || (value is List && value.isEmpty)) {
      return !required;
    }
    switch (kind) {
      case 'text':
        return value is String &&
            value.runes.length <= maxLength &&
            queryPlainText(value);
      case 'number':
        return value is num &&
            value.isFinite &&
            (!integer || value == value.truncateToDouble()) &&
            (minimum == null || value >= minimum!) &&
            (maximum == null || value <= maximum!);
      case 'boolean':
        return value is bool;
      case 'select':
        return value is String && options.any((o) => o.value == value);
      case 'multiSelect':
        return value is List &&
            value.length <= 32 &&
            value.toSet().length == value.length &&
            value.every((v) => v is String && options.any((o) => o.value == v));
      case 'date':
        return value is String && queryDate(value);
      case 'timeRange':
        return value is Map &&
            value.length == 2 &&
            value['start'] is String &&
            value['end'] is String &&
            queryTime(value['start']) &&
            queryTime(value['end']) &&
            (value['start'] as String).compareTo(value['end']) < 0;
      default:
        return false;
    }
  }
}

class QueryForm {
  const QueryForm({
    required this.target,
    required this.title,
    required this.submitLabel,
    required this.fields,
  });
  final String target, title, submitLabel;
  final List<QueryFormField> fields;

  Set<String> descendants(String id) {
    final result = <String>{};
    final pending = <String>[id];
    while (pending.isNotEmpty) {
      final parent = pending.removeLast();
      for (final field in fields) {
        if (field.dependsOn.contains(parent) && result.add(field.id)) {
          pending.add(field.id);
        }
      }
    }
    return result;
  }

  Map<String, dynamic>? values(Map<String, dynamic> draft) {
    final result = <String, dynamic>{};
    for (final field in fields) {
      if (field.disabled) continue;
      final value = draft[field.id];
      if (!field.accepts(value)) return null;
      if (value != null && value != '' && !(value is List && value.isEmpty)) {
        result[field.id] = value;
      }
    }
    if (!isQueryFilterMap(result)) return null;
    return result;
  }
}

/// Schema-independent semantic checks also protect direct native consumers.
QueryForm? queryFormFromDynamic(Object? raw, String target) {
  try {
    if (outputValidatorFor('elecon.query.controls', '2.0')?.call(raw) != true) {
      return null;
    }
    if (utf8.encode(jsonEncode(raw)).length > 131072 ||
        raw is! Map ||
        raw['target'] != target ||
        !const ['grades.list', 'classroom.available'].contains(target)) {
      return null;
    }
    bool text(Object? v, int max, {bool empty = false}) =>
        v is String &&
        (empty || v.isNotEmpty) &&
        v.runes.length <= max &&
        queryPlainText(v);
    if (!text(raw['title'], 160) ||
        !text(raw['submitLabel'], 80) ||
        raw['controls'] is! List ||
        (raw['controls'] as List).length > 32) {
      return null;
    }
    final fields = <QueryFormField>[];
    final ids = <String>{};
    for (final value in raw['controls']) {
      if (value is! Map) return null;
      final item = Map<String, dynamic>.from(value);
      final id = item['id'];
      final kind = item['kind'];
      if (id is! String ||
          !RegExp(r'^[a-z][a-zA-Z0-9._-]{0,63}$').hasMatch(id) ||
          const ['prototype', 'constructor', '__proto__'].contains(id) ||
          !ids.add(id) ||
          !const [
            'text',
            'number',
            'boolean',
            'select',
            'multiSelect',
            'date',
            'timeRange',
          ].contains(kind) ||
          !text(item['label'], 160)) {
        return null;
      }
      for (final key in ['description', 'disabledReason']) {
        if (item.containsKey(key) &&
            !text(item[key], 512, empty: key == 'description')) {
          return null;
        }
      }
      for (final key in ['required', 'disabled', 'integer']) {
        if (item.containsKey(key) && item[key] is! bool) return null;
      }
      if (item['disabled'] == true && !text(item['disabledReason'], 512)) {
        return null;
      }
      if (item.containsKey('timeZone') && !text(item['timeZone'], 128)) {
        return null;
      }
      if (kind == 'timeRange' && !text(item['timeZone'], 128)) return null;
      if (item.containsKey('maxLength') &&
          (kind != 'text' ||
              item['maxLength'] is! int ||
              item['maxLength'] < 1 ||
              item['maxLength'] > 512)) {
        return null;
      }
      for (final key in ['minimum', 'maximum']) {
        if (item.containsKey(key) &&
            (kind != 'number' ||
                item[key] is! num ||
                !(item[key] as num).isFinite)) {
          return null;
        }
      }
      if (item.containsKey('integer') && kind != 'number') return null;
      if (item['minimum'] != null &&
          item['maximum'] != null &&
          item['minimum'] > item['maximum']) {
        return null;
      }
      if (item.containsKey('dependsOn') &&
          (item['dependsOn'] is! List ||
              (item['dependsOn'] as List).length > 31 ||
              (item['dependsOn'] as List).any((v) => v is! String))) {
        return null;
      }
      final dependencies = List<String>.from(item['dependsOn'] ?? const []);
      if (dependencies.toSet().length != dependencies.length ||
          dependencies.contains(id)) {
        return null;
      }
      if (kind == 'select' || kind == 'multiSelect') {
        if (item['options'] is! List ||
            (item['options'] as List).length > 200) {
          return null;
        }
        final values = <String>{};
        for (final option in item['options']) {
          if (option is! Map ||
              !text(option['value'], 512) ||
              !text(option['label'], 160) ||
              !values.add(option['value'])) {
            return null;
          }
        }
      } else if (item.containsKey('options')) {
        return null;
      }
      final field = QueryFormField(item);
      if (item.containsKey('initialValue') &&
          (item['initialValue'] == null ||
              !field.accepts(item['initialValue']))) {
        return null;
      }
      fields.add(field);
    }
    final form = QueryForm(
      target: target,
      title: raw['title'],
      submitLabel: raw['submitLabel'],
      fields: fields,
    );
    for (final field in fields) {
      if (field.dependsOn.any((id) => !ids.contains(id)) ||
          form.descendants(field.id).contains(field.id)) {
        return null;
      }
    }
    return form;
  } catch (_) {
    return null;
  }
}
