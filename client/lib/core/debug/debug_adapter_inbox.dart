/// ADR-100: developer-owned files authorize debug source installs, never calls.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../../session/profile_controller.dart';
import '../../session/session_controller.dart';
import '../scripts/manifest.dart';
import 'dev_log.dart';

class DebugAdapterInbox {
  DebugAdapterInbox(this.directory, this.profiles);
  final Directory directory;
  final ProfileController profiles;
  Timer? _timer;
  bool _foreground = true;
  int _lifecycleRevision = 0;
  bool get foreground => _foreground;
  set foreground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    _lifecycleRevision++;
  }

  bool _busy = false;
  bool _closed = false;
  static final _requestId = RegExp(r'^[a-f0-9]{32}$');

  Future<void> start() async {
    if (!kDebugMode || _closed) return;
    for (final name in ['inbox', 'processing', 'results']) {
      await Directory('${directory.path}/$name').create(recursive: true);
    }
    if (_closed) return;
    _timer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(poll()),
    );
    await poll();
  }

  void close() {
    _closed = true;
    _lifecycleRevision++;
    _timer?.cancel();
  }

  Future<void> _write(String relative, Object data) async {
    final file = File('${directory.path}/$relative');
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(data), flush: true);
    await temporary.rename(file.path);
  }

  /// Also callable by a local file workflow; never follows an external path.
  Future<void> poll() async {
    if (!kDebugMode ||
        _closed ||
        _busy ||
        !foreground ||
        !profiles.isRestored ||
        profiles.busy) {
      return;
    }
    _busy = true;
    try {
      final profile = profiles.active;
      final lifecycleRevision = _lifecycleRevision;
      bool active() =>
          !_closed &&
          foreground &&
          lifecycleRevision == _lifecycleRevision &&
          profiles.isRestored &&
          !profiles.busy &&
          identical(profile, profiles.active);
      bool canCommit() => active() && !profile.session.hardwareUnlockFailed;
      final registry = await profile.session.scriptRegistry;
      if (!active()) return;
      await _write('status.json', {
        'version': 1,
        'profileId': profile.id,
        'locked': profile.session.hardwareUnlockFailed,
        'installations': [
          for (final installation in registry.installations)
            {
              'id': installation.package.manifest.id,
              'version': installation.package.manifest.version,
              'schoolId': installation.package.manifest.schoolId,
              'digest': installation.package.digest,
              'enabled': installation.enabled,
            },
        ],
      });
      final inbox = Directory('${directory.path}/inbox');
      // A bounded scan per tick avoids unbounded work on a developer's queue.
      var processed = 0;
      await for (final entity in inbox.list(followLinks: false)) {
        if (!active()) break;
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final name = entity.uri.pathSegments.last;
        final id = name.substring(0, name.length - 5);
        if (!_requestId.hasMatch(id)) continue;
        if (processed++ >= 8) break;
        final processing = File('${directory.path}/processing/$name');
        // An interrupted request is never replayed, even if submitted again.
        final result = File('${directory.path}/results/$name');
        if (await processing.exists() || await result.exists()) continue;
        await entity.rename(processing.path);
        String code = 'debug_command_rejected';
        try {
          if (await processing.length() > 2 * 1024 * 1024) {
            throw const FormatException('debug_command_size');
          }
          final command = jsonDecode(await processing.readAsString());
          if (!active()) throw StateError('script_cancelled');
          if (command is! Map ||
              command['version'] != 1 ||
              command['profileId'] != profile.id ||
              profile.session.hardwareUnlockFailed ||
              profiles.busy ||
              !identical(profile, profiles.active)) {
            throw const FormatException('debug_command_identity');
          }
          final session = profile.session;
          switch (command['operation']) {
            case 'upsert':
              final text = command['package'];
              if (text is! String ||
                  sha256.convert(utf8.encode(text)).toString() !=
                      command['sha256']) {
                throw const FormatException('debug_command_digest');
              }
              final package = ScriptPackage.parse(text);
              session.cancelTrustedScriptRuns();
              await session.installTrustedScript(
                package,
                approvedDigest: package.digest,
                debugReplace: true,
                isActive: canCommit,
              );
            case 'remove':
              final packageId = command['packageId'];
              if (packageId is! String || registry.find(packageId) == null) {
                throw const FormatException('debug_command_package');
              }
              session.cancelTrustedScriptRuns();
              await session.removeTrustedScript(packageId, isActive: canCommit);
            default:
              throw const FormatException('debug_command_operation');
          }
          code = 'ok';
        } catch (error) {
          // Only fixed host codes; never arbitrary exception text or source.
          const allowed = {
            'debug_command_size',
            'debug_command_identity',
            'debug_command_digest',
            'debug_command_package',
            'debug_command_operation',
            'script_downgrade',
            'script_version_reused',
            'script_school_changed',
            'script_install_limit',
            'script_update_required',
            'script_cancelled',
          };
          final reason = error is FormatException
              ? error.message
              : error is StateError
              ? error.message
              : null;
          if (allowed.contains(reason)) code = reason as String;
        }
        await _write('results/$name', {'requestId': id, 'result': code});
        await processing.delete();
        DevLog.instance.runtime(
          'debug adapter command: request=$id result=$code',
        );
      }
      // Results survive disconnection but have bounded retention. Unacknowledged
      // processing records remain for explicit inspection after a crash.
      final results = await Directory('${directory.path}/results')
          .list(followLinks: false)
          .where((e) => e is File && e.path.endsWith('.json'))
          .toList();
      if (results.length > 64) {
        results.sort((a, b) => a.path.compareTo(b.path));
        for (final old in results.take(results.length - 64)) {
          await old.delete();
        }
      }
    } catch (_) {
      DevLog.instance.runtime('debug adapter inbox unavailable');
    } finally {
      _busy = false;
    }
  }
}
