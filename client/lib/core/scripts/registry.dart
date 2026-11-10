/// 🔒 ADR-034 §2 / ADR-043 §1: approved installs and explicit stable providers.
library;

import 'dart:async';
import 'dart:convert';

import '../credential/blob_store.dart';
import '../debug/debug_tools_config.dart';
import 'manifest.dart';

const _registryBlob = 'trusted-scripts.json';
const _maxRegistryBytes = 32 * 1024 * 1024;
const _entityGroups = [
  ['notice.list', 'notice.detail'],
  ['classroom.buildings', 'classroom.available'],
  ['energy.meters', 'energy.usage'],
  ['climate.devices', 'climate.status', 'climate.command'],
];

String? _entitySource(String capability) {
  for (final group in _entityGroups) {
    if (group.skip(1).contains(capability)) return group.first;
  }
  return null;
}

class ScriptInstallation {
  const ScriptInstallation(this.package, {this.enabled = true});
  final ScriptPackage package;
  final bool enabled;
}

/// A host-owned route, never an executable package declaration or access grant.
class _ProviderBinding {
  const _ProviderBinding({
    required this.schoolId,
    required this.capability,
    required this.baseId,
    required this.schema,
    required this.schemaVersion,
    this.overrideId,
  });

  factory _ProviderBinding.forPackage(
    ScriptPackage package,
    ScriptCapability cap,
  ) => _ProviderBinding(
    schoolId: package.manifest.schoolId,
    capability: cap.id,
    baseId: package.manifest.id,
    schema: cap.schema,
    schemaVersion: cap.schemaVersion,
  );

  final String schoolId;
  final String capability;
  final String baseId;
  final String schema;
  final String schemaVersion;
  final String? overrideId;
  String get key => jsonEncode([schoolId, capability]);

  _ProviderBinding withOverride(String? id) => _ProviderBinding(
    schoolId: schoolId,
    capability: capability,
    baseId: baseId,
    schema: schema,
    schemaVersion: schemaVersion,
    overrideId: id,
  );

  _ProviderBinding withBaseContract(ScriptCapability cap) => _ProviderBinding(
    schoolId: schoolId,
    capability: capability,
    baseId: baseId,
    schema: schema,
    schemaVersion: cap.schemaVersion,
    overrideId: overrideId,
  );

  bool accepts(ScriptPackage package) {
    final cap = package.manifest.capability(capability);
    return package.manifest.schoolId == schoolId &&
        cap?.schema == schema &&
        cap?.schemaVersion == schemaVersion;
  }

  Map<String, Object?> toJson() => {
    'schoolId': schoolId,
    'capability': capability,
    'baseId': baseId,
    'schema': schema,
    'schemaVersion': schemaVersion,
    if (overrideId != null) 'overrideId': overrideId,
  };
}

class ScriptRegistry {
  ScriptRegistry._(this._blobs);
  factory ScriptRegistry.empty(BlobStore? blobs) => ScriptRegistry._(blobs);
  final BlobStore? _blobs;
  Map<String, ScriptInstallation> _entries = {};
  Map<String, _ProviderBinding> _bindings = {};
  Future<void> _writes = Future.value();
  int _epoch = 0;
  int get epoch => _epoch;
  List<ScriptInstallation> get installations =>
      List.unmodifiable(_entries.values.toList().reversed);

  static String _key(String schoolId, String capability) =>
      jsonEncode([schoolId, capability]);

  static Future<ScriptRegistry> open(BlobStore? blobs) async {
    final registry = ScriptRegistry._(blobs);
    final bytes = await blobs?.read(_registryBlob);
    if (bytes == null) return registry;
    if (bytes.length > _maxRegistryBytes) {
      throw const FormatException('script_registry_size');
    }
    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is! Map ||
        !const [1, 2, 3].contains(raw['version']) ||
        raw['entries'] is! List ||
        (raw['entries'] as List).length > 32) {
      throw const FormatException('script_registry_format');
    }
    for (final item in raw['entries'] as List) {
      if (item is! Map ||
          item['package'] is! String ||
          item['digest'] is! String ||
          item['enabled'] is! bool) {
        throw const FormatException('script_registry_entry');
      }
      final package = ScriptPackage.restore(item['package'] as String);
      if (package.digest != item['digest'] ||
          registry._entries.containsKey(package.manifest.id)) {
        throw const FormatException('script_registry_digest');
      }
      registry._entries[package.manifest.id] = ScriptInstallation(
        package,
        enabled: item['enabled'] as bool,
      );
    }
    if (raw['version'] == 1) {
      // Migration preserves the old effective source separately for each
      // capability. No single historical "main package" is inferred.
      for (final enabled in [true, false]) {
        for (final installation in registry.installations) {
          if (installation.enabled != enabled) continue;
          final package = installation.package;
          for (final cap in package.manifest.capabilities) {
            final binding = _ProviderBinding.forPackage(package, cap);
            registry._bindings.putIfAbsent(binding.key, () => binding);
          }
        }
      }
    } else {
      final bindings = raw['bindings'];
      if (bindings is! List || bindings.length > 2048) {
        throw const FormatException('script_registry_bindings');
      }
      for (final item in bindings) {
        if (item is! Map ||
            ![
              'schoolId',
              'capability',
              'baseId',
              'schema',
              'schemaVersion',
            ].every(
              (key) =>
                  item[key] is String &&
                  (item[key] as String).isNotEmpty &&
                  (item[key] as String).length <= 256,
            ) ||
            (item.containsKey('overrideId') &&
                (item['overrideId'] is! String ||
                    (item['overrideId'] as String).isEmpty ||
                    (item['overrideId'] as String).length > 256))) {
          throw const FormatException('script_registry_binding');
        }
        final binding = _ProviderBinding(
          schoolId: item['schoolId'] as String,
          capability: item['capability'] as String,
          baseId: item['baseId'] as String,
          schema: item['schema'] as String,
          schemaVersion: item['schemaVersion'] as String,
          overrideId: item['overrideId'] as String?,
        );
        if (registry._bindings.containsKey(binding.key)) {
          throw const FormatException('script_registry_binding_duplicate');
        }
        // References may become unavailable after an approved package update,
        // but can never point into another school.
        for (final id in [binding.baseId, binding.overrideId]) {
          final package = registry._entries[id]?.package;
          if (package != null &&
              package.manifest.schoolId != binding.schoolId) {
            throw const FormatException('script_registry_binding_identity');
          }
        }
        registry._bindings[binding.key] = binding;
      }
    }
    if (raw['version'] == 2) {
      // ADR-053: the already approved base package owns its declared version.
      // Repair the v2 upgrade omission without promoting a different source or
      // changing any package bytes, approval digest or override selection.
      for (final binding in registry._bindings.values.toList()) {
        final package = registry._entries[binding.baseId]?.package;
        final cap = package?.manifest.capability(binding.capability);
        if (package != null &&
            !package.requiresUpdate &&
            cap != null &&
            package.manifest.schoolId == binding.schoolId &&
            cap.schema == binding.schema) {
          registry._bindings[binding.key] = binding.withBaseContract(cap);
        }
      }
    }
    return registry;
  }

  ScriptInstallation? find(String id) => _entries[id];

  /// Header branding belongs to the school's own package or stable base route,
  /// never to an override or an unselected candidate.
  String? homeTitleForSchool(String schoolId, {String? packageId}) {
    if (packageId != null) {
      final installation = find(packageId);
      return installation?.enabled == true &&
              installation!.package.manifest.schoolId == schoolId
          ? installation.package.manifest.homeTitle
          : null;
    }
    for (final capability in const [
      'notice.list',
      'schedule.week',
      'grades.list',
      'card.balance',
      'exam.list',
      'library.loans',
      'energy.meters',
      'climate.devices',
      'classroom.buildings',
    ]) {
      final base = baseProvider(schoolId, capability);
      if (base != null) return base.manifest.homeTitle;
    }
    return null;
  }

  /// Stable base route for display defaults; overrides do not own layout.
  ScriptPackage? baseProvider(String schoolId, String capability) {
    final binding = _bindings[_key(schoolId, capability)];
    if (binding == null) return null;
    final base = _entries[binding.baseId];
    if (base?.enabled == true) {
      return !base!.package.requiresUpdate && binding.accepts(base.package)
          ? base.package
          : null;
    }
    // Do not promote an unselected candidate when the base disappears.
    return null;
  }

  ScriptPackage? _provider(String schoolId, String capability) {
    final binding = _bindings[_key(schoolId, capability)];
    if (binding == null) return null;
    final override = _entries[binding.overrideId];
    if (override?.enabled == true) {
      // An incompatible update cannot inherit a previous source selection.
      return !override!.package.requiresUpdate &&
              binding.accepts(override.package)
          ? override.package
          : null;
    }
    return baseProvider(schoolId, capability);
  }

  ScriptPackage? provider(String schoolId, String capability) {
    final result = _provider(schoolId, capability);
    // Bare entity identifiers cannot cross package sources. Legacy mixed routes
    // remain unavailable until their discovery and dependent handlers are chosen
    // together; this also covers an unavailable discovery route after updates.
    final source = _entitySource(capability);
    if (source != null && _bindings.containsKey(_key(schoolId, source))) {
      final discovery = _provider(schoolId, source);
      if (discovery == null || result?.digest != discovery.digest) return null;
    }
    return result;
  }

  /// A selected local source that became incompatible must not silently fall
  /// through to a V1 handler with different entity or query semantics.
  bool blocksLegacyFallback(String schoolId, String capability) {
    if (provider(schoolId, capability) != null) return false;
    final source = _entitySource(capability);
    if (source != null && _provider(schoolId, source) != null) {
      return true;
    }
    final binding = _bindings[_key(schoolId, capability)];
    return binding != null &&
        (_entries[binding.overrideId]?.enabled == true ||
            _entries[binding.baseId]?.enabled == true);
  }

  bool isProviderOverride(
    String schoolId,
    String capability,
    String packageId,
  ) => _bindings[_key(schoolId, capability)]?.overrideId == packageId;

  /// Entity discovery and dependent handlers share one selected source.
  /// Clearing an override restores the original stable base route.
  Future<void> setProviderOverride(
    String schoolId,
    String capability,
    String? packageId,
  ) => _change((entries, bindings) {
    final key = _key(schoolId, capability);
    final current = bindings[key];
    if (current == null) throw StateError('script_capability_unavailable');
    final declaredGroup = _entityGroups.where((g) => g.contains(capability));
    final group = (declaredGroup.isEmpty ? [capability] : declaredGroup.first)
        .where((c) => bindings.containsKey(_key(schoolId, c)))
        .toList();
    if (packageId == null) {
      for (final cap in group) {
        final groupKey = _key(schoolId, cap);
        bindings[groupKey] = bindings[groupKey]!.withOverride(null);
      }
      return;
    }
    final installation = entries[packageId];
    if (installation == null ||
        !installation.enabled ||
        installation.package.requiresUpdate ||
        installation.package.manifest.schoolId != schoolId) {
      throw StateError('script_not_authorized');
    }
    final package = installation.package;
    for (final cap in group) {
      if (package.manifest.capability(cap) == null) {
        throw StateError('script_provider_group_required');
      }
      final binding = bindings[_key(schoolId, cap)]!;
      if (!binding.accepts(package) && binding.baseId != packageId) {
        throw StateError('script_provider_incompatible');
      }
    }
    for (final cap in group) {
      final groupKey = _key(schoolId, cap);
      final binding = bindings[groupKey]!;
      bindings[groupKey] = binding.baseId == packageId
          ? _ProviderBinding.forPackage(
              package,
              package.manifest.capability(cap)!,
            )
          : binding.withOverride(packageId);
    }
  });

  /// Caller obtains approvedDigest from the package shown on the install page.
  Future<void> install(
    ScriptPackage package, {
    required String approvedDigest,
    bool debugReplace = false,
  }) => _change((entries, bindings) {
    if (package.requiresUpdate) {
      throw StateError('script_update_required');
    }
    if (approvedDigest != package.digest) {
      throw StateError('script_not_approved');
    }
    final id = package.manifest.id;
    final old = entries[id];
    if (old != null) {
      if (old.package.manifest.schoolId != package.manifest.schoolId) {
        throw StateError('script_school_changed');
      }
      final order = compareScriptVersions(
        package.manifest.version,
        old.package.manifest.version,
      );
      if (order < 0) throw StateError('script_downgrade');
      if (order == 0 &&
          old.package.digest != package.digest &&
          !(debugToolsEnabled && debugReplace)) {
        throw StateError('script_version_reused');
      }
    } else if (entries.length >= 32) {
      throw StateError('script_install_limit');
    }
    // Assignment preserves the existing insertion position on updates.
    entries[id] = ScriptInstallation(package, enabled: old?.enabled ?? true);
    for (final cap in package.manifest.capabilities) {
      final binding = _ProviderBinding.forPackage(package, cap);
      final current = bindings[binding.key];
      if (current == null) {
        bindings[binding.key] = binding;
      } else if (current.baseId == id && current.schema == cap.schema) {
        bindings[binding.key] = current.withBaseContract(cap);
      }
    }
  });

  Future<void> setEnabled(String id, bool enabled) => _change((entries, _) {
    final old = entries[id];
    if (old == null) throw StateError('script_not_installed');
    entries[id] = ScriptInstallation(old.package, enabled: enabled);
  });

  Future<void> remove(String id) => _change((entries, bindings) {
    entries.remove(id);
    for (final key in bindings.keys.toList()) {
      final binding = bindings[key]!;
      if (!entries.values.any(
        (entry) =>
            entry.package.manifest.schoolId == binding.schoolId &&
            entry.package.manifest.capability(binding.capability) != null,
      )) {
        bindings.remove(key);
      } else if (binding.overrideId == id) {
        bindings[key] = binding.withOverride(null);
      }
    }
  });

  Future<void> _change(
    void Function(
      Map<String, ScriptInstallation>,
      Map<String, _ProviderBinding>,
    )
    edit,
  ) {
    final done = Completer<void>();
    _writes = _writes.then((_) async {
      try {
        final next = Map<String, ScriptInstallation>.of(_entries);
        final bindings = Map<String, _ProviderBinding>.of(_bindings);
        edit(next, bindings);
        final bytes = utf8.encode(
          jsonEncode({
            'version': 3,
            'entries': [
              for (final item in next.values)
                {
                  'package': item.package.encode(),
                  'digest': item.package.digest,
                  'enabled': item.enabled,
                },
            ],
            'bindings': [
              for (final binding in bindings.values) binding.toJson(),
            ],
          }),
        );
        if (bytes.length > _maxRegistryBytes) {
          throw StateError('script_registry_size');
        }
        await _blobs?.write(_registryBlob, bytes);
        _entries = next;
        _bindings = bindings;
        _epoch++;
        done.complete();
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }
}
