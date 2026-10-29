/// 🔒 Actual credential values for the authorized school (ADR-034 §3).
/// UI receives this facade only through host-owned runtime wiring.
library;

import 'dart:convert';

import '../credential/store.dart';
import '../credential/types.dart';

class ScriptCredentialException implements Exception {
  const ScriptCredentialException(this.code);
  final String code;
  @override
  String toString() => 'ScriptCredentialException($code)';
}

class ScriptCredentials {
  ScriptCredentials({
    required CredentialStore store,
    required this.schoolId,
    bool Function()? isActive,
    int Function()? now,
  }) : _store = store,
       _isActive = isActive ?? (() => true),
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final CredentialStore _store;
  final String schoolId;
  final bool Function() _isActive;
  final int Function() _now;

  String get _prefix => 'script:$schoolId:';

  void _check() {
    if (!_isActive()) {
      throw const ScriptCredentialException('identity_inactive');
    }
  }

  void _key(String key) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$').hasMatch(key)) {
      throw const ScriptCredentialException('invalid_credential_key');
    }
  }

  CredentialEntry? _entry(String key) {
    final entries = _store.list();
    for (final ref in ['$_prefix$key', key]) {
      for (final entry in entries) {
        if (entry.schoolId == schoolId && entry.ref == ref) return entry;
      }
    }
    return null;
  }

  Map<String, Object?>? get(String key) {
    _check();
    _key(key);
    final entry = _entry(key);
    if (entry == null || entry.status == CredentialStatus.revoked) return null;
    return _record(entry);
  }

  List<Map<String, Object?>> list() {
    _check();
    final result = <String, Map<String, Object?>>{};
    for (final entry in _store.list()) {
      if (entry.schoolId != schoolId ||
          entry.status == CredentialStatus.revoked) {
        continue;
      }
      final key = _logicalKey(entry.ref);
      if (key == null) continue;
      final record = _record(entry);
      if (!result.containsKey(key) || entry.ref.startsWith(_prefix)) {
        result[key] = record;
      }
    }
    return result.values.toList(growable: false);
  }

  void set(
    String key,
    String value, {
    String type = 'token',
    int? expiresAt,
    List<String> scope = const [],
  }) {
    _check();
    _key(key);
    if (utf8.encode(value).length > 64 * 1024 ||
        !const {
          'token',
          'cookie',
          'header',
          'query',
          'password',
        }.contains(type) ||
        scope.length > 64 ||
        scope.any((s) => s.length > 2048) ||
        (expiresAt != null && expiresAt < 0)) {
      throw const ScriptCredentialException('invalid_credential_value');
    }
    final existing = _entry(key);
    _store.put(
      CredentialEntry(
        ref: existing?.ref ?? '$_prefix$key',
        schoolId: schoolId,
        type: type,
        scope: List.unmodifiable(scope),
        value: value,
        acquiredAt: _now(),
        expiresAt: expiresAt,
        status: CredentialStatus.active,
        sensitivity: existing?.sensitivity ?? CredentialSensitivity.standard,
        protection: existing?.protection ?? CredentialProtection.memory,
      ),
    );
  }

  void delete(String key) {
    _check();
    _key(key);
    for (final entry in _store.list()) {
      if (entry.schoolId == schoolId &&
          (entry.ref == key || entry.ref == '$_prefix$key')) {
        _store.delete(entry.ref);
      }
    }
  }

  List<String> get secretValues => list()
      .map((entry) => entry['value'] as String)
      .where((value) => value.isNotEmpty)
      .toList(growable: false);

  String? _logicalKey(String ref) {
    final value = ref.startsWith(_prefix) ? ref.substring(_prefix.length) : ref;
    return RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$').hasMatch(value)
        ? value
        : null;
  }

  Map<String, Object?> _record(CredentialEntry entry) => {
    'key': _logicalKey(entry.ref),
    'value': entry.value,
    'type': entry.type,
    'scope': entry.scope.toList(growable: false),
    'expiresAt': entry.expiresAt,
    'expired':
        entry.status == CredentialStatus.expired ||
        (entry.expiresAt != null && _now() >= entry.expiresAt!),
  };
}
