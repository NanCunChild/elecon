/// ADR-091: host-only form metadata and edits, isolated from business results.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:elecon_contract/output_validator_registry.dart';

import '../credential/store.dart';
import '../credential/types.dart';
import 'manifest.dart';
import 'query_filters.dart';

/// Local editor text is never a query parameter. Only incomplete numeric text
/// and the two fixed time-range edges are retained, within their input limits.
bool isQueryFormRawEditors(Object? value) {
  if (value is! Map || value.length > 64) return false;
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! String) return false;
    final key = entry.key as String;
    final text = entry.value as String;
    if (isQueryFieldId(key)) {
      if (text.runes.length > 64) return false;
    } else {
      final parts = key.split(':');
      if (parts.length != 3 ||
          parts[0] != 'range' ||
          !isQueryFieldId(parts[1]) ||
          !const {'start', 'end'}.contains(parts[2]) ||
          text.length > 5) {
        return false;
      }
    }
  }
  return true;
}

class ScriptQueryFormCache {
  ScriptQueryFormCache(this.store, {this.locale = 'zh', int Function()? now})
    : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final CredentialStore store;
  final String locale;
  final int Function() now;
  static const type = 'script-query-form';
  static const maxBytes = 128 * 1024;
  static const maxSchoolBytes = 1024 * 1024;
  static const freshMs = 15 * 60 * 1000;
  static const retentionMs = 7 * 24 * 60 * 60 * 1000;

  static Object? canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: canonical(value[key])};
    }
    if (value is List) return value.map(canonical).toList();
    return value;
  }

  String _prefix(ScriptPackage package) =>
      'script-form:${package.manifest.schoolId}:${package.manifest.id}:${package.digest}:';

  String _ref(
    ScriptPackage package,
    String target,
    Map<String, dynamic> params,
    bool draft,
  ) =>
      '${_prefix(package)}${package.manifest.capability('query.controls')?.schemaVersion}:$locale:$target:${draft ? 'draft' : 'metadata'}:${sha256.convert(utf8.encode(jsonEncode(canonical(params))))}';

  bool _supported(ScriptPackage package, String target) =>
      const {'grades.list', 'classroom.available'}.contains(target) &&
      package.manifest.capability(target) != null &&
      const {
        '2.0',
        '2.1',
      }.contains(package.manifest.capability('query.controls')?.schemaVersion);

  bool _valid(ScriptPackage package, String target, Object? data, bool draft) {
    if (data is! Map<String, dynamic>) return false;
    if (draft) {
      final cleared = data['cleared'];
      return data.keys.every(
            (k) =>
                const {'applied', 'edits', 'cleared', 'rawEditors'}.contains(k),
          ) &&
          isQueryFilterMap(data['applied']) &&
          isQueryFilterMap(data['edits']) &&
          cleared is List &&
          cleared.length <= 32 &&
          cleared.toSet().length == cleared.length &&
          cleared.every(isQueryFieldId) &&
          (!data.containsKey('rawEditors') ||
              isQueryFormRawEditors(data['rawEditors']));
    }
    return data['target'] == target &&
        outputValidatorFor(
              'elecon.query.controls',
              package.manifest.capability('query.controls')!.schemaVersion,
            )?.call(data) ==
            true;
  }

  Map<String, dynamic>? read(
    ScriptPackage package,
    String target,
    Map<String, dynamic> params, {
    bool draft = false,
  }) {
    if (!_supported(package, target)) return null;
    try {
      final ref = _ref(package, target, params, draft);
      final entry = store.list().where((entry) => entry.ref == ref).firstOrNull;
      if (entry == null ||
          entry.type != type ||
          entry.schoolId != package.manifest.schoolId ||
          entry.status != CredentialStatus.active ||
          entry.acquiredAt > now() ||
          now() - entry.acquiredAt >= (draft ? retentionMs : freshMs) ||
          utf8.encode(entry.value).length > maxBytes) {
        return null;
      }
      final data = jsonDecode(entry.value);
      if (!_valid(package, target, data, draft)) return null;
      if (draft && !_matchesApplied(params, data)) return null;
      if (!draft && !params.containsKey('load')) {
        final current = params['current'];
        // A cached default cannot tell us the school's current calendar day.
        // User selections are independent, exact-keyed inputs and may persist.
        if ((data['controls'] as List).any(
          (field) =>
              const {'date', 'timeRange'}.contains(field['kind']) &&
              field.containsKey('initialValue') &&
              !(current is Map && current.containsKey(field['id'])),
        )) {
          return null;
        }
      }
      return Map<String, dynamic>.from(data);
    } on Object {
      return null;
    }
  }

  bool write(
    ScriptPackage package,
    String target,
    Map<String, dynamic> params,
    Map<String, dynamic>? data, {
    bool draft = false,
  }) {
    if (!_supported(package, target)) return false;
    final ref = _ref(package, target, params, draft);
    if (data == null) {
      store.delete(ref);
      return true;
    }
    if (!_valid(package, target, data, draft)) return false;
    if (draft && !_matchesApplied(params, data)) return false;
    final encoded = jsonEncode(data);
    if (utf8.encode(encoded).length > maxBytes) return false;
    final stamp = now();
    for (final entry in store.list()) {
      if (entry.type == type &&
          entry.schoolId == package.manifest.schoolId &&
          (stamp - entry.acquiredAt >= retentionMs ||
              (entry.ref.startsWith(
                    'script-form:${package.manifest.schoolId}:${package.manifest.id}:',
                  ) &&
                  !entry.ref.startsWith(_prefix(package))))) {
        store.delete(entry.ref);
      }
    }
    store.put(
      CredentialEntry(
        ref: ref,
        schoolId: package.manifest.schoolId,
        type: type,
        scope: const [],
        value: encoded,
        acquiredAt: stamp,
        expiresAt: null,
        status: CredentialStatus.active,
      ),
    );
    final entries =
        store
            .list()
            .where(
              (entry) =>
                  entry.type == type &&
                  entry.schoolId == package.manifest.schoolId,
            )
            .toList()
          ..sort((a, b) => a.acquiredAt.compareTo(b.acquiredAt));
    var size = entries.fold(
      0,
      (total, entry) => total + utf8.encode(entry.value).length,
    );
    while (entries.length > 64 || size > maxSchoolBytes) {
      final oldest = entries.removeAt(0);
      size -= utf8.encode(oldest.value).length;
      store.delete(oldest.ref);
    }
    return true;
  }

  Set<String> clearSchool(String schoolId) {
    final refs = {
      for (final entry in store.list())
        if (entry.type == type && entry.schoolId == schoolId) entry.ref,
    };
    for (final ref in refs) {
      store.delete(ref);
    }
    return refs;
  }

  bool _matchesApplied(Map<String, dynamic> params, Map data) =>
      jsonEncode(canonical(params['current'] ?? const {})) ==
      jsonEncode(canonical(data['applied']));
}
