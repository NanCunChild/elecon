/// 🔒 ADR-037 §1–§2; redlines #1/#5/#7: bounded, transient input for one run.
/// No credentials are read or persisted here; errors never echo script/user data.
library;

import 'dart:convert';

class ScriptInputException implements Exception {
  const ScriptInputException(this.code);
  final String code;
  @override
  String toString() => 'ScriptInputException($code)';
}

typedef ScriptInputCall = Future<Object?> Function(ScriptInputRequest request);

enum ScriptInputType { text, password, select }

class ScriptInputOption {
  const ScriptInputOption({required this.label, required this.value});
  final String label;
  final String value;
}

class ScriptInputField {
  const ScriptInputField({
    required this.id,
    required this.label,
    required this.type,
    required this.isRequired,
    required this.maxLength,
    this.initialValue,
    this.options = const [],
  });
  final String id;
  final String label;
  final ScriptInputType type;
  final bool isRequired;
  final int maxLength;
  final String? initialValue;
  final List<ScriptInputOption> options;

  bool accepts(String value) =>
      value.length <= maxLength &&
      !value.codeUnits.any((unit) => unit < 32 || unit == 127) &&
      (!isRequired ||
          (type == ScriptInputType.password
              ? value.isNotEmpty
              : value.trim().isNotEmpty)) &&
      (type != ScriptInputType.select ||
          (!isRequired && value.isEmpty) ||
          options.any((option) => option.value == value));
}

class ScriptInputRequest {
  ScriptInputRequest._(this.title, this.message, this.fields);
  final String title;
  final String? message;
  final List<ScriptInputField> fields;
  static const maxBytes = 32 * 1024;

  factory ScriptInputRequest.decode(String encoded) {
    if (encoded.length > maxBytes || utf8.encode(encoded).length > maxBytes) {
      throw const ScriptInputException('input_invalid_request');
    }
    try {
      return ScriptInputRequest.fromJson(jsonDecode(encoded));
    } on ScriptInputException {
      rethrow;
    } catch (_) {
      throw const ScriptInputException('input_invalid_request');
    }
  }

  factory ScriptInputRequest.fromJson(Object? value) {
    try {
      if (utf8.encode(jsonEncode(value)).length > maxBytes) _invalid();
    } on ScriptInputException {
      rethrow;
    } catch (_) {
      _invalid();
    }
    final request = _map(value, {'title', 'message', 'fields'});
    final title = _text(request['title'], 120);
    final message = request.containsKey('message')
        ? _text(request['message'], 1000, empty: true, multiline: true)
        : null;
    final rawFields = request['fields'];
    if (rawFields is! List || rawFields.isEmpty || rawFields.length > 8) {
      _invalid();
    }
    final ids = <String>{};
    final fields = <ScriptInputField>[];
    for (final raw in rawFields) {
      final field = _map(raw, {
        'id',
        'label',
        'type',
        'required',
        'maxLength',
        'initialValue',
        'options',
      });
      final id = _text(field['id'], 64);
      if (!RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$').hasMatch(id) ||
          !ids.add(id)) {
        _invalid();
      }
      final type = switch (field.containsKey('type') ? field['type'] : 'text') {
        'text' => ScriptInputType.text,
        'password' => ScriptInputType.password,
        'select' => ScriptInputType.select,
        _ => _invalid(),
      };
      final required = field.containsKey('required') ? field['required'] : true;
      final maxLength = field.containsKey('maxLength')
          ? field['maxLength']
          : 128;
      if (required is! bool ||
          maxLength is! int ||
          maxLength < 1 ||
          maxLength > 4096) {
        _invalid();
      }
      if (type == ScriptInputType.password &&
          field.containsKey('initialValue')) {
        _invalid();
      }
      final initial = field.containsKey('initialValue')
          ? _text(field['initialValue'], maxLength, empty: true)
          : null;
      final options = <ScriptInputOption>[];
      if (type == ScriptInputType.select) {
        final rawOptions = field['options'];
        if (rawOptions is! List ||
            rawOptions.isEmpty ||
            rawOptions.length > 20) {
          _invalid();
        }
        final values = <String>{};
        for (final rawOption in rawOptions) {
          final option = _map(rawOption, {'label', 'value'});
          final optionValue = _text(
            option['value'],
            maxLength < 512 ? maxLength : 512,
          );
          if (!values.add(optionValue)) _invalid();
          options.add(
            ScriptInputOption(
              label: _text(option['label'], 120),
              value: optionValue,
            ),
          );
        }
        if (initial != null && !values.contains(initial)) _invalid();
      } else if (field.containsKey('options')) {
        _invalid();
      }
      fields.add(
        ScriptInputField(
          id: id,
          label: _text(field['label'], 120),
          type: type,
          isRequired: required,
          maxLength: maxLength,
          initialValue: initial,
          options: List.unmodifiable(options),
        ),
      );
    }
    return ScriptInputRequest._(title, message, List.unmodifiable(fields));
  }

  Map<String, String>? validateResult(Object? result) {
    if (result == null) return null;
    if (result is! Map ||
        result.length != fields.length ||
        result.keys.any((key) => key is! String)) {
      throw const ScriptInputException('input_invalid_result');
    }
    final values = <String, String>{};
    for (final field in fields) {
      final value = result[field.id];
      if (value is! String || !field.accepts(value)) {
        throw const ScriptInputException('input_invalid_result');
      }
      values[field.id] = value;
    }
    return Map.unmodifiable(values);
  }
}

Never _invalid() => throw const ScriptInputException('input_invalid_request');
Map<String, Object?> _map(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.keys.any((key) => key is! String || !keys.contains(key))) {
    _invalid();
  }
  return Map<String, Object?>.from(value);
}

String _text(
  Object? value,
  int limit, {
  bool empty = false,
  bool multiline = false,
}) {
  if (value is! String ||
      value.length > limit ||
      (!empty && value.trim().isEmpty) ||
      value.codeUnits.any(
        (unit) =>
            unit == 0 ||
            unit == 127 ||
            (unit < 32 && !(multiline && unit == 10)),
      )) {
    _invalid();
  }
  return value;
}
