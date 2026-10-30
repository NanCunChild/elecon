/// 🔒 Actual values in the current school; SDK 2 adds explicit addresses.
/// ADR-034 §3 / ADR-035 §2–§3: namespace is an address, not an access grant.
library;

import 'dart:convert';

import '../credential/store.dart';
import '../credential/types.dart';

/// Distinguishes omitted expiry from the explicit null that clears it.
const scriptCredentialUnspecified = Object();

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
    this.scriptId,
    this.sdkVersion = 1,
    bool Function()? isActive,
    int Function()? now,
  }) : _store = store,
       _isActive = isActive ?? (() => true),
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (!_identifier.hasMatch(schoolId) ||
        !const {1, 2, 3, 4}.contains(sdkVersion) ||
        (scriptId != null && !_identifier.hasMatch(scriptId!)) ||
        (sdkVersion >= 2 && scriptId == null)) {
      throw const ScriptCredentialException('invalid_credential_identity');
    }
  }

  static final _identifier = RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$');
  static final _keyPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$');
  final CredentialStore _store;
  final String schoolId;
  final String? scriptId;
  final int sdkVersion;
  final bool Function() _isActive;
  final int Function() _now;

  String get _previewPrefix => 'script:$schoolId:';

  void _check() {
    if (!_isActive()) {
      throw const ScriptCredentialException('identity_inactive');
    }
  }

  void _key(String key) {
    if (!_keyPattern.hasMatch(key)) {
      throw const ScriptCredentialException('invalid_credential_key');
    }
  }

  String _namespace(String? namespace) {
    final result = namespace ?? scriptId;
    if (result == null ||
        (result != '@legacy' &&
            result != '@preview1' &&
            (result.length > 128 || !_identifier.hasMatch(result)))) {
      throw const ScriptCredentialException('invalid_credential_namespace');
    }
    return result;
  }

  String _ref(String key, String namespace) => switch (namespace) {
    '@legacy' => key,
    '@preview1' => '$_previewPrefix$key',
    _ => 'script2:$schoolId:$namespace:$key',
  };

  CredentialEntry? _slot(String ref, {bool ignoreForeignLegacy = false}) {
    for (final entry in _store.list()) {
      if (entry.ref != ref) continue;
      if (entry.schoolId != schoolId) {
        if (ignoreForeignLegacy) return null;
        throw const ScriptCredentialException('credential_descriptor_conflict');
      }
      return entry;
    }
    return null;
  }

  /// SDK 1 keeps its original preview-first, legacy-fallback lookup only when
  /// no explicit namespace was provided. SDK 2 always uses a complete address.
  CredentialEntry? _entry(String key, String? namespace) {
    if (sdkVersion == 1 && namespace == null) {
      return _slot('$_previewPrefix$key') ??
          _slot(key, ignoreForeignLegacy: true);
    }
    return _slot(
      _ref(key, _namespace(namespace)),
      ignoreForeignLegacy: namespace == '@legacy',
    );
  }

  Map<String, Object?>? get(String key, {String? namespace}) {
    _check();
    _key(key);
    final entry = _entry(key, namespace);
    if (entry == null || entry.status == CredentialStatus.revoked) return null;
    return _record(entry);
  }

  List<Map<String, Object?>> list() {
    _check();
    final records = <Map<String, Object?>>[];
    final preview = <String, Map<String, Object?>>{};
    for (final entry in _store.list()) {
      if (entry.schoolId != schoolId ||
          entry.status == CredentialStatus.revoked) {
        continue;
      }
      final address = _address(entry);
      if (address == null) continue;
      final record = _record(entry);
      if (sdkVersion >= 2) {
        records.add(record);
      } else if (address.namespace == '@legacy' ||
          address.namespace == '@preview1') {
        // Compatibility: SDK 1 list used logical keys with preview precedence.
        if (!preview.containsKey(address.key) ||
            address.namespace == '@preview1') {
          preview[address.key] = record;
        }
      }
    }
    return sdkVersion >= 2 ? records : preview.values.toList(growable: false);
  }

  void set(
    String key,
    String value, {
    String? namespace,
    String? type,
    Object? expiresAt = scriptCredentialUnspecified,
    List<String>? scope,
  }) {
    _check();
    _key(key);
    final existing = _entry(key, namespace);
    final selectedType = type ?? existing?.type ?? 'token';
    final selectedScope = scope ?? existing?.scope ?? const <String>[];
    final selectedExpiry = identical(expiresAt, scriptCredentialUnspecified)
        ? existing?.expiresAt
        : expiresAt;
    if (utf8.encode(value).length > 64 * 1024 ||
        !const {
          'token',
          'cookie',
          'header',
          'query',
          'password',
        }.contains(selectedType) ||
        selectedScope.length > 64 ||
        selectedScope.any((s) => s.length > 2048) ||
        (selectedExpiry != null &&
            (selectedExpiry is! int || selectedExpiry < 0))) {
      throw const ScriptCredentialException('invalid_credential_value');
    }
    final ref = sdkVersion == 1 && namespace == null
        ? existing?.ref ?? '$_previewPrefix$key'
        : _ref(key, _namespace(namespace));
    // Check the physical slot independently: a foreign legacy entry was hidden
    // by reads above but can never be overwritten by an explicit legacy write.
    _slot(ref);
    _store.put(
      CredentialEntry(
        ref: ref,
        schoolId: schoolId,
        type: selectedType,
        scope: List.unmodifiable(selectedScope),
        value: value,
        acquiredAt: _now(),
        expiresAt: selectedExpiry as int?,
        status: CredentialStatus.active,
        sensitivity: existing?.sensitivity ?? CredentialSensitivity.standard,
        protection: existing?.protection ?? CredentialProtection.memory,
      ),
    );
  }

  void delete(String key, {String? namespace}) {
    _check();
    _key(key);
    if (sdkVersion == 1 && namespace == null) {
      final preview = _slot('$_previewPrefix$key');
      final legacy = _slot(key, ignoreForeignLegacy: true);
      if (preview != null) _store.delete(preview.ref);
      if (legacy != null) _store.delete(legacy.ref);
      return;
    }
    final ref = _ref(key, _namespace(namespace));
    final entry = _slot(ref, ignoreForeignLegacy: namespace == '@legacy');
    if (entry != null) _store.delete(entry.ref);
  }

  List<String> get secretValues {
    _check();
    return _store
        .list()
        .where((entry) => entry.schoolId == schoolId && entry.value.isNotEmpty)
        .map((entry) => entry.value)
        .toList(growable: false);
  }

  ({String namespace, String key})? _address(CredentialEntry entry) {
    final ref = entry.ref;
    if (ref.startsWith('script2:')) {
      final parts = ref.split(':');
      if (parts.length != 4 ||
          parts[1] != schoolId ||
          parts[2].length > 128 ||
          !_identifier.hasMatch(parts[2]) ||
          !_keyPattern.hasMatch(parts[3])) {
        throw const ScriptCredentialException('credential_descriptor_conflict');
      }
      return (namespace: parts[2], key: parts[3]);
    }
    if (ref.startsWith('script:')) {
      if (!ref.startsWith(_previewPrefix) ||
          !_keyPattern.hasMatch(ref.substring(_previewPrefix.length))) {
        throw const ScriptCredentialException('credential_descriptor_conflict');
      }
      return (
        namespace: '@preview1',
        key: ref.substring(_previewPrefix.length),
      );
    }
    if (_keyPattern.hasMatch(ref)) return (namespace: '@legacy', key: ref);
    return null;
  }

  Map<String, Object?> _record(CredentialEntry entry) {
    final address = _address(entry);
    return {
      'id': address?.namespace == '@legacy'
          ? 'legacy:$schoolId:${address!.key}'
          : entry.ref,
      'namespace': address?.namespace,
      'key': address?.key,
      'value': entry.value,
      'type': entry.type,
      'scope': entry.scope.toList(growable: false),
      'expiresAt': entry.expiresAt,
      'expired':
          entry.status == CredentialStatus.expired ||
          (entry.expiresAt != null && _now() >= entry.expiresAt!),
    };
  }
}
