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
    this.freshUntil,
  });
  final Object? data;
  final DateTime fetchedAt;
  final bool isStale;
  final Map<String, dynamic> params;
  final DateTime? freshUntil;
}

class ScriptDataCache {
  ScriptDataCache(this.store, {int Function()? now, String locale = 'zh'})
    : locale = normalizeScriptLocale(locale) ?? 'zh',
      now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  final CredentialStore store;
  final String locale;
  final int Function() now;
  static const type = 'script-data';
  static const maxBytes = 512 * 1024;
  static const maxSchoolBytes = 4 * 1024 * 1024;
  static const retentionMs = 7 * 24 * 60 * 60 * 1000;

  // An academic term stays useful offline long after its refresh TTL expires.
  int _retention(String capability) =>
      capability == 'schedule.week' ? 180 * 24 * 60 * 60 * 1000 : retentionMs;

  /// A same-school login can replace credentials shared by multiple packages.
  /// Discard every locale/parameter snapshot, never the school credentials.
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
  String _languagePrefix(ScriptPackage package) =>
      '${_prefix(package)}${package.manifest.sdkVersion >= 13 ? 'locale:$locale:' : ''}';
  String _ref(
    ScriptPackage package,
    String capability,
    Map<String, dynamic> params,
  ) =>
      '${_languagePrefix(package)}$capability:${sha256.convert(utf8.encode(jsonEncode(_canonical(params))))}';
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
    // ADR-054/089: only 1.2/1.3 define complete term weeks. Older open schemas may
    // contain an unrelated extension with this name and must not be projected.
    if (capability == 'schedule.week' &&
        const [
          '1.2',
          '1.3',
        ].contains(package.manifest.capability(capability)?.schemaVersion) &&
        params['week'] is int &&
        params.keys.every((key) => key == 'week' || key == 'term')) {
      for (final entry in _entries(package, capability)) {
        final cached = _decode(package, capability, entry);
        if (cached == null) continue;
        if (entry.ref == ref) return cached;
        final projected = _projectWeek(cached, params);
        if (projected != null) return projected;
      }
    }
    return _decode(
      package,
      capability,
      store.list().where((e) => e.ref == ref).firstOrNull,
    );
  }

  ScriptCachedData? latest(ScriptPackage package, String capability) {
    for (final entry in _entries(package, capability)) {
      final data = _decode(package, capability, entry);
      if (data != null) return data;
    }
    return null;
  }

  List<CredentialEntry> _entries(ScriptPackage package, String capability) =>
      store
          .list()
          .where(
            (e) => e.ref.startsWith('${_languagePrefix(package)}$capability:'),
          )
          .toList()
        ..sort((a, b) => b.acquiredAt.compareTo(a.acquiredAt));

  ScriptCachedData? _projectWeek(
    ScriptCachedData cached,
    Map<String, dynamic> params,
  ) {
    if (cached.params.keys.any((key) => key != 'week' && key != 'term')) {
      return null;
    }
    final data = cached.data;
    if (data is! Map<String, dynamic> ||
        (params['term'] != null && params['term'] != data['term'])) {
      return null;
    }
    final weeks = data['termWeeks'];
    if (weeks is! List) return null;
    final matches = weeks
        .whereType<Map>()
        .where((row) => row['week'] == params['week'])
        .toList();
    if (matches.length != 1) return null;
    final row = matches.single;
    final projected = Map<String, dynamic>.from(data)..remove('weekType');
    for (final key in [
      'week',
      'days',
      'teachingWeekStart',
      'teachingWeekEnd',
      'weekType',
    ]) {
      if (row.containsKey(key)) projected[key] = row[key];
    }
    return ScriptCachedData(
      data: projected,
      fetchedAt: cached.fetchedAt,
      isStale: cached.isStale,
      freshUntil: cached.freshUntil,
      params: Map.unmodifiable(params),
    );
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
        now() - entry.acquiredAt > _retention(capability) ||
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
        freshUntil: DateTime.fromMillisecondsSinceEpoch(
          entry.acquiredAt + policy.ttlSeconds * 1000,
          isUtc: true,
        ),
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
          (stamp - entry.acquiredAt >
                  _retention(
                    entry.ref.contains(':schedule.week:')
                        ? 'schedule.week'
                        : '',
                  ) ||
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
