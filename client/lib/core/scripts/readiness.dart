/// ADR-059: configuration prerequisites belong to the current identity and
/// authorized source; they are not successful data or script credentials.
library;

import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../credential/store.dart';
import '../credential/types.dart';
import 'manifest.dart';

class ScriptReadinessStore {
  const ScriptReadinessStore(this.store);
  final CredentialStore store;
  static const type = 'script-readiness';
  static const _limit = 128;

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }

  String _prefix(ScriptPackage package, String capability) =>
      'script-readiness:${package.manifest.schoolId}:${package.manifest.id}:${package.digest}:$capability:';
  String _ref(
    ScriptPackage package,
    String capability,
    Map<String, dynamic> params,
  ) =>
      '${_prefix(package, capability)}${sha256.convert(utf8.encode(jsonEncode(_canonical(params))))}';

  bool needsConfiguration(
    ScriptPackage package,
    String capability,
    Map<String, dynamic> params,
  ) {
    final ref = _ref(package, capability, params);
    return store.list().any(
      (entry) =>
          entry.ref == ref &&
          entry.schoolId == package.manifest.schoolId &&
          entry.type == type &&
          entry.status == CredentialStatus.active &&
          entry.value == 'configuration_required',
    );
  }

  bool mark(
    ScriptPackage package,
    String capability,
    Map<String, dynamic> params,
  ) {
    if (needsConfiguration(package, capability, params)) return false;
    store.put(
      CredentialEntry(
        ref: _ref(package, capability, params),
        schoolId: package.manifest.schoolId,
        type: type,
        scope: const [],
        value: 'configuration_required',
        acquiredAt: DateTime.now().millisecondsSinceEpoch,
        expiresAt: null,
        status: CredentialStatus.active,
      ),
    );
    final entries = store.list().where((entry) => entry.type == type).toList()
      ..sort((a, b) => a.acquiredAt.compareTo(b.acquiredAt));
    for (final entry in entries.take(
      entries.length > _limit ? entries.length - _limit : 0,
    )) {
      store.delete(entry.ref);
    }
    return true;
  }

  List<CredentialEntry> entries(ScriptPackage package, String capability) =>
      store
          .list()
          .where(
            (entry) =>
                entry.type == type &&
                entry.ref.startsWith(_prefix(package, capability)),
          )
          .toList();

  bool clear(ScriptPackage package, String capability) {
    final entries = store
        .list()
        .where(
          (entry) =>
              entry.type == type &&
              entry.ref.startsWith(_prefix(package, capability)),
        )
        .toList();
    for (final entry in entries) {
      store.delete(entry.ref);
    }
    return entries.isNotEmpty;
  }
}
