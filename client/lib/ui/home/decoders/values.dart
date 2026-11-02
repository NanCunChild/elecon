/// Shared coercions for contract decoders. No widget dependencies.
library;

bool optionalIs<T>(Map<String, dynamic> map, String key) =>
    !map.containsKey(key) || map[key] is T;

int? optionalSchemaNonNegativeInt(Map<String, dynamic> map, String key) =>
    map.containsKey(key) ? asSchemaNonNegativeInt(map[key]) : null;

int? asSchemaNonNegativeInt(Object? raw) {
  if (raw is String) return null;
  final value = asInt(raw);
  return value != null && value >= 0 ? value : null;
}

String? optionalUtcDateTime(Map<String, dynamic> map, String key) =>
    map.containsKey(key) ? requiredUtcDateTime(map[key]) : null;

String? requiredUtcDateTime(Object? raw) {
  if (raw is! String) return null;
  final match = _utcDateTimePattern.firstMatch(raw);
  final parsed = DateTime.tryParse(raw);
  if (match == null || parsed == null) return null;
  final parts = [
    parsed.year,
    parsed.month,
    parsed.day,
    parsed.hour,
    parsed.minute,
    parsed.second,
  ];
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] != int.parse(match.group(i + 1)!)) return null;
  }
  return raw;
}

final RegExp _utcDateTimePattern = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$',
);
final RegExp currencyPattern = RegExp(r'^[A-Z]{3}$');
int? asNonNegativeInt(Object? raw) {
  final value = raw is int ? raw : (raw is String ? int.tryParse(raw) : null);
  return value != null && value >= 0 ? value : null;
}

int? asInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num && raw.isFinite && raw == raw.truncateToDouble()) {
    return raw.toInt();
  }
  if (raw is String) return int.tryParse(raw);
  return null;
}

List<String>? asStringList(Object? raw) {
  if (raw is! List) return null;
  final out = <String>[];
  for (final entry in raw) {
    final s = entry?.toString();
    if (s != null && s.isNotEmpty) out.add(s);
  }
  return out.isEmpty ? null : out;
}

Map<String, dynamic>? asStringKeyedMap(Object? raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) {
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }
  return null;
}
