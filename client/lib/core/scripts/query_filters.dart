/// ADR-082: bounded school-owned values, never host invocation options.
library;

import 'dart:convert';

bool isQueryFieldId(Object? value) =>
    value is String &&
    RegExp(r'^[a-z][a-zA-Z0-9._-]{0,63}$').hasMatch(value) &&
    !const {'constructor', 'prototype', '__proto__'}.contains(value);

bool isQueryFilterMap(Object? raw) {
  if (raw is! Map || raw.length > 32) return false;
  for (final entry in raw.entries) {
    if (!isQueryFieldId(entry.key) || !_value(entry.value)) return false;
  }
  try {
    return utf8.encode(jsonEncode(raw)).length <= 32 * 1024;
  } catch (_) {
    return false;
  }
}

bool _value(Object? value) {
  if (value is String) return value.runes.length <= 512;
  if (value is bool) return true;
  if (value is num) return value.isFinite;
  if (value is List) {
    return value.length <= 32 &&
        value.every((v) => v is String && v.runes.length <= 512) &&
        value.toSet().length == value.length;
  }
  if (value is Map) {
    final time = RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$');
    return value.length == 2 &&
        value['start'] is String &&
        value['end'] is String &&
        time.hasMatch(value['start']) &&
        time.hasMatch(value['end']) &&
        (value['start'] as String).compareTo(value['end']) < 0;
  }
  return false;
}
