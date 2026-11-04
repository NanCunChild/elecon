/// ADR-070: bounded, digest-covered script language resources.
library;

import 'dart:convert';

const maxScriptLocalizationBytes = 256 * 1024;
final _locale = RegExp(
  r'^[a-z]{2,3}(?:-[A-Z][a-z]{3})?(?:-[A-Z]{2}|-[0-9]{3})?$(?![\s\S])',
);
final _key = RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,127}$(?![\s\S])');
final _placeholder = RegExp(r'\{([A-Za-z][A-Za-z0-9_]{0,63})\}');
final _controls = RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]');

/// This is a BCP 47 language[-Script][-REGION] profile, not a registry lookup.
/// Installed declarations must already be canonical; only request preferences
/// may use underscores and ordinary casing differences.
String? normalizeScriptLocale(String? value) {
  if (value == null || value.length > 32) return null;
  if (RegExp(r'[^A-Za-z0-9_-]').hasMatch(value)) return null;
  final parts = value.replaceAll('_', '-').split('-');
  if (parts.isEmpty || !RegExp(r'^[A-Za-z]{2,3}$').hasMatch(parts.first)) {
    return null;
  }
  final normalized = [parts.first.toLowerCase()];
  var index = 1;
  if (index < parts.length && RegExp(r'^[A-Za-z]{4}$').hasMatch(parts[index])) {
    final script = parts[index++].toLowerCase();
    normalized.add('${script[0].toUpperCase()}${script.substring(1)}');
  }
  if (index < parts.length &&
      RegExp(r'^(?:[A-Za-z]{2}|[0-9]{3})$').hasMatch(parts[index])) {
    normalized.add(parts[index++].toUpperCase());
  }
  return index == parts.length ? normalized.join('-') : null;
}

class ScriptLocalization {
  ScriptLocalization._(this.defaultLocale, this.messages);

  factory ScriptLocalization.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 2 ||
        !value.containsKey('defaultLocale') ||
        !value.containsKey('messages') ||
        utf8.encode(jsonEncode(value)).length > maxScriptLocalizationBytes) {
      throw const FormatException('invalid script localization');
    }
    final defaultLocale = value['defaultLocale'];
    final raw = value['messages'];
    if (defaultLocale is! String ||
        !_locale.hasMatch(defaultLocale) ||
        raw is! Map<String, dynamic> ||
        raw.isEmpty ||
        raw.length > 32 ||
        !raw.containsKey(defaultLocale)) {
      throw const FormatException('invalid script localization languages');
    }
    final messages = <String, Map<String, String>>{};
    final placeholders = <String, Map<String, Set<String>>>{};
    for (final language in raw.entries) {
      final dictionary = language.value;
      if (!_locale.hasMatch(language.key) ||
          dictionary is! Map<String, dynamic> ||
          dictionary.isEmpty ||
          dictionary.length > 1024) {
        throw const FormatException('invalid script language dictionary');
      }
      final strings = <String, String>{};
      final names = <String, Set<String>>{};
      for (final entry in dictionary.entries) {
        final message = entry.value;
        if (!_key.hasMatch(entry.key) ||
            message is! String ||
            message.runes.length > 4096 ||
            !_wellFormed(message) ||
            _controls.hasMatch(message) ||
            message.replaceAll(_placeholder, '').contains(RegExp(r'[{}]'))) {
          throw const FormatException('invalid script message');
        }
        strings[entry.key] = message;
        names[entry.key] = _placeholder
            .allMatches(message)
            .map((m) => m[1]!)
            .toSet();
      }
      messages[language.key] = Map.unmodifiable(strings);
      placeholders[language.key] = names;
    }
    final defaults = placeholders[defaultLocale]!;
    for (final language in placeholders.values) {
      for (final entry in language.entries) {
        final expected = defaults[entry.key];
        if (expected == null ||
            expected.length != entry.value.length ||
            !expected.containsAll(entry.value)) {
          throw const FormatException(
            'script translation keys or placeholders differ',
          );
        }
      }
    }
    return ScriptLocalization._(defaultLocale, Map.unmodifiable(messages));
  }

  final String defaultLocale;
  final Map<String, Map<String, String>> messages;
  List<String> get supportedLocales =>
      List.unmodifiable(messages.keys.toList()..sort());

  String resolveLocale(String requested) {
    final normalized = normalizeScriptLocale(requested);
    if (normalized == null) return defaultLocale;
    if (messages.containsKey(normalized)) return normalized;
    final parts = normalized.split('-');
    if (parts.length > 1 && parts[1].length == 4) {
      final script = '${parts[0]}-${parts[1]}';
      if (messages.containsKey(script)) return script;
    }
    return messages.containsKey(parts[0]) ? parts[0] : defaultLocale;
  }
}

bool _wellFormed(String value) {
  final units = value.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
        return false;
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}
