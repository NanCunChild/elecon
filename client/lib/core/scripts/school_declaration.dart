/// SDK16 display grouping is independent from the authorization schoolId.
library;

String _displayText(Object? value, int max) {
  if (value is! String ||
      value.trim().isEmpty ||
      value.runes.length > max ||
      RegExp(
        r'[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]',
      ).hasMatch(value)) {
    throw const FormatException('invalid school display text');
  }
  return value;
}

String _displayId(Object? value) {
  final result = _displayText(value, 128);
  if (!RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$').hasMatch(result)) {
    throw const FormatException('invalid school display id');
  }
  return result;
}

class ScriptSchoolType {
  const ScriptSchoolType({required this.id, required this.name});
  final String id, name;
  factory ScriptSchoolType.fromJson(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        raw.length != 2 ||
        !raw.containsKey('id') ||
        !raw.containsKey('name')) {
      throw const FormatException('invalid school type');
    }
    return ScriptSchoolType(
      id: _displayId(raw['id']),
      name: _displayText(raw['name'], 80),
    );
  }
}

class ScriptSchool {
  const ScriptSchool({
    required this.id,
    required this.name,
    required this.type,
  });
  final String id, name;
  final ScriptSchoolType type;
  factory ScriptSchool.fromJson(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        raw.length != 3 ||
        !raw.containsKey('id') ||
        !raw.containsKey('name') ||
        !raw.containsKey('type')) {
      throw const FormatException('invalid school display');
    }
    return ScriptSchool(
      id: _displayId(raw['id']),
      name: _displayText(raw['name'], 160),
      type: ScriptSchoolType.fromJson(raw['type']),
    );
  }
}
