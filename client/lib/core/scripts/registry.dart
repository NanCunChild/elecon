/// 🔒 ADR-034 §2: explicit local installation trust and monotonic updates.
library;

import 'dart:async';
import 'dart:convert';

import '../credential/blob_store.dart';
import 'manifest.dart';

const _registryBlob = 'trusted-scripts.json';
const _maxRegistryBytes = 32 * 1024 * 1024;

class ScriptInstallation {
  const ScriptInstallation(this.package, {this.enabled = true});
  final ScriptPackage package;
  final bool enabled;
}

class ScriptRegistry {
  ScriptRegistry._(this._blobs);
  factory ScriptRegistry.empty(BlobStore? blobs) => ScriptRegistry._(blobs);
  final BlobStore? _blobs;
  Map<String, ScriptInstallation> _entries = {};
  Future<void> _writes = Future.value();
  int _epoch = 0;
  int get epoch => _epoch;
  List<ScriptInstallation> get installations =>
      List.unmodifiable(_entries.values.toList().reversed);

  static Future<ScriptRegistry> open(BlobStore? blobs) async {
    final registry = ScriptRegistry._(blobs);
    final bytes = await blobs?.read(_registryBlob);
    if (bytes == null) return registry;
    if (bytes.length > _maxRegistryBytes) {
      throw const FormatException('script_registry_size');
    }
    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is! Map || raw['version'] != 1 || raw['entries'] is! List ||
        (raw['entries'] as List).length > 32) {
      throw const FormatException('script_registry_format');
    }
    for (final item in raw['entries'] as List) {
      if (item is! Map || item['package'] is! String ||
          item['digest'] is! String || item['enabled'] is! bool) {
        throw const FormatException('script_registry_entry');
      }
      final package = ScriptPackage.parse(item['package'] as String);
      if (package.digest != item['digest'] ||
          registry._entries.containsKey(package.manifest.id)) {
        throw const FormatException('script_registry_digest');
      }
      registry._entries[package.manifest.id] =
          ScriptInstallation(package, enabled: item['enabled'] as bool);
    }
    return registry;
  }

  ScriptInstallation? find(String id) => _entries[id];
  ScriptPackage? provider(String schoolId, String capability) {
    for (final installation in installations) {
      final package = installation.package;
      if (installation.enabled && package.manifest.schoolId == schoolId &&
          package.manifest.capabilities.any((c) => c.id == capability)) {
        return package;
      }
    }
    return null;
  }

  /// Caller obtains approvedDigest from the package shown on the install page.
  Future<void> install(ScriptPackage package, {required String approvedDigest}) =>
      _change((entries) {
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
            package.manifest.version, old.package.manifest.version);
          if (order < 0) throw StateError('script_downgrade');
          if (order == 0 && old.package.digest != package.digest) {
            throw StateError('script_version_reused');
          }
        } else if (entries.length >= 32) {
          throw StateError('script_install_limit');
        }
        entries.remove(id);
        entries[id] = ScriptInstallation(package);
      });

  Future<void> setEnabled(String id, bool enabled) => _change((entries) {
    final old = entries[id];
    if (old == null) throw StateError('script_not_installed');
    entries[id] = ScriptInstallation(old.package, enabled: enabled);
  });

  Future<void> remove(String id) => _change((entries) => entries.remove(id));

  Future<void> _change(void Function(Map<String, ScriptInstallation>) edit) {
    final done = Completer<void>();
    _writes = _writes.then((_) async {
      try {
        final next = Map<String, ScriptInstallation>.of(_entries);
        edit(next);
        final bytes = utf8.encode(jsonEncode({
          'version': 1,
          'entries': [for (final item in next.values) {
            'package': item.package.encode(),
            'digest': item.package.digest,
            'enabled': item.enabled,
          }],
        }));
        if (bytes.length > _maxRegistryBytes) {
          throw StateError('script_registry_size');
        }
        await _blobs?.write(_registryBlob, bytes);
        _entries = next;
        _epoch++;
        done.complete();
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }
}
