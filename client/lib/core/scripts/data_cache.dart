/// 🔒 ADR-038 §2: validated business data shares the selected H/S/M backend.
/// Reserved addresses cannot be read through ScriptCredentials (red lines #1/#3).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:elecon_contract/output_validator_registry.dart';

import '../credential/store.dart';
import '../credential/types.dart';
import 'manifest.dart';

class ScriptCachedData {
  const ScriptCachedData({
    required this.data,
    required this.fetchedAt,
    required this.isStale,
    required this.params,
  });
  final Object? data;
  final DateTime fetchedAt;
  final bool isStale;
  final Map<String, dynamic> params;
}

class ScriptDataCache {
  ScriptDataCache(this.store, {int Function()? now})
    : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  final CredentialStore store;
  final int Function() now;
  static const type = 'script-data';
  static const maxBytes = 512 * 1024;
  static const maxSchoolBytes = 4 * 1024 * 1024;
  static const retentionMs = 7 * 24 * 60 * 60 * 1000;

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final k in keys) k: _canonical(value[k])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }

  String _prefix(ScriptPackage package) =>
      'script-cache:${package.manifest.schoolId}:${package.manifest.id}:${package.digest}:';
  String _ref(
    ScriptPackage package,
    String capability,
    Map<String, dynamic> params,
  ) =>
      '${_prefix(package)}$capability:${sha256.convert(utf8.encode(jsonEncode(_canonical(params))))}';
  ScriptHomeEntry? _policy(ScriptPackage package, String capability) => package
      .manifest
      .home
      .where((e) => e.capability == capability)
      .firstOrNull;

  ScriptCachedData? read(
    ScriptPackage package,
    String capability, {
    Map<String, dynamic> params = const {},
  }) {
    final ref = _ref(package, capability, params);
    return _decode(
      package,
      capability,
      store.list().where((e) => e.ref == ref).firstOrNull,
    );
  }

  ScriptCachedData? latest(ScriptPackage package, String capability) {
    final entries =
        store
            .list()
            .where((e) => e.ref.startsWith('${_prefix(package)}$capability:'))
            .toList()
          ..sort((a, b) => b.acquiredAt.compareTo(a.acquiredAt));
    for (final entry in entries) {
      final data = _decode(package, capability, entry);
      if (data != null) return data;
    }
    return null;
  }

  ScriptCachedData? _decode(
    ScriptPackage package,
    String capability,
    CredentialEntry? entry,
  ) {
    final policy = _policy(package, capability);
    final cap = package.manifest.capability(capability);
    if (policy == null ||
        cap == null ||
        entry == null ||
        entry.type != type ||
        entry.schoolId != package.manifest.schoolId ||
        entry.status == CredentialStatus.revoked ||
        entry.acquiredAt > now() ||
        now() - entry.acquiredAt > retentionMs ||
        utf8.encode(entry.value).length > maxBytes) {
      return null;
    }
    try {
      final record = jsonDecode(entry.value) as Map<String, dynamic>;
      final params = record['params'] as Map<String, dynamic>;
      if (_ref(package, capability, params) != entry.ref ||
          outputValidatorFor(
                cap.schema,
                cap.schemaVersion,
              )?.call(record['data']) !=
              true) {
        return null;
      }
      return ScriptCachedData(
        data: record['data'],
        params: params,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(
          entry.acquiredAt,
          isUtc: true,
        ),
        isStale: now() - entry.acquiredAt >= policy.ttlSeconds * 1000,
      );
    } on Object {
      return null;
    }
  }

  bool write(
    ScriptPackage package,
    String capability,
    Map<String, dynamic> params,
    Object? data,
  ) {
    final cap = package.manifest.capability(capability);
    if (_policy(package, capability) == null ||
        cap == null ||
        outputValidatorFor(cap.schema, cap.schemaVersion)?.call(data) != true) {
      return false;
    }
    final encoded = jsonEncode({'params': _canonical(params), 'data': data});
    if (utf8.encode(encoded).length > maxBytes) return false;
    final stamp = now();
    final ref = _ref(package, capability, params);
    // Superseded digests and expired records are unusable and can be removed.
    for (final entry in store.list()) {
      if (entry.type == type &&
          entry.schoolId == package.manifest.schoolId &&
          (stamp - entry.acquiredAt > retentionMs ||
              (entry.ref.startsWith(
                    'script-cache:${package.manifest.schoolId}:${package.manifest.id}:',
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
              (e) => e.type == type && e.schoolId == package.manifest.schoolId,
            )
            .toList()
          ..sort((a, b) => a.acquiredAt.compareTo(b.acquiredAt));
    var size = entries.fold<int>(0, (n, e) => n + utf8.encode(e.value).length);
    while (entries.length > 32 || size > maxSchoolBytes) {
      final oldest = entries.removeAt(0);
      size -= utf8.encode(oldest.value).length;
      store.delete(oldest.ref);
    }
    return true;
  }
}
