import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../session/capability_query.dart';
import '../../session/profile_controller.dart';
import '../../session/session_controller.dart';
import '../scripts/manifest.dart';
import 'schedule_widget_snapshot.dart';

class ScheduleWidgetOpenRequest {
  const ScheduleWidgetOpenRequest(this.serial, this.source);
  final int serial;
  final CapabilitySource source;
}

class ScheduleWidgetController extends ChangeNotifier
    with WidgetsBindingObserver {
  ScheduleWidgetController({required this.profiles, this.channel}) {
    if (channel == null) return;
    profiles.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    channel!.setMethodCallHandler((call) async {
      if (call.method == 'widgetsChanged') _changed();
      if (call.method == 'openWidget') await _open(call.arguments);
    });
    unawaited(_initialize());
  }

  final ProfileController profiles;
  final MethodChannel? channel;
  bool _disposed = false;
  bool _ready = false;
  int _serial = 0;
  Object? _identity;
  ScheduleWidgetOpenRequest? pending;
  int? _pendingWidgetId;
  Object? _pendingBinding;
  final Map<String, CapabilitySource> _sources = {};
  Future<void> _work = Future.value();

  Future<void> _initialize() async {
    try {
      final initial = await channel!.invokeMethod<int>('beginSession');
      if (_disposed) return;
      _pendingWidgetId = initial;
      _ready = true;
      _changed();
    } on PlatformException {
      /* No native snapshot on failure. */
    } on MissingPluginException {
      /* Unsupported platform. */
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _changed();
  }

  void _changed() {
    if (_disposed || !_ready) return;
    if (!profiles.isRestored) return;
    final session = profiles.active.session;
    final identity = (
      profiles.active.id,
      session.selectedSchool?.id,
      session.identityRevision,
      session.trustedScriptDataGeneration,
      session.trustedScriptSourceRevision,
    );
    final serial = ++_serial;
    if ((_identity != null && _identity != identity) || profiles.busy) {
      pending = null;
      if (_pendingBinding != null && _pendingBinding != identity) {
        _pendingWidgetId = null;
        _pendingBinding = null;
      }
      _sources.clear();
      // Invoked immediately, before any further asynchronous cache read.
      unawaited(
        channel!
            .invokeMethod<void>('invalidate', serial)
            .catchError((Object _) {}),
      );
    }
    _identity = identity;
    _work = _work.then((_) => _sync(serial)).catchError((Object _) async {
      if (!_disposed && serial == _serial) {
        await channel!
            .invokeMethod<void>('invalidate', serial)
            .catchError((Object _) {});
      }
    });
    notifyListeners();
  }

  Future<void> _sync(int serial) async {
    if (_disposed || serial != _serial) return;
    final profile = profiles.active;
    final session = profile.session;
    final school = session.selectedSchool;
    final viewGeneration = session.trustedScriptViewGeneration;
    bool current() =>
        !_disposed &&
        serial == _serial &&
        profiles.isRestored &&
        !profiles.busy &&
        identical(profile, profiles.active) &&
        session.trustedScriptViewGeneration == viewGeneration;
    if (!profiles.isRestored ||
        profiles.busy ||
        !session.isRestored ||
        session.hardwareUnlockFailed ||
        school == null) {
      await channel!.invokeMethod<void>('invalidate', serial);
      return;
    }
    final registry = await session.scriptRegistry;
    if (!current()) return;
    final packages = registry.installations
        .where(
          (installation) =>
              installation.enabled &&
              !installation.package.requiresUpdate &&
              installation.package.manifest.schoolId == school.id &&
              installation.package.manifest.capability('schedule.week') != null,
        )
        .map((installation) => installation.package)
        .take(16)
        .toList();
    final contexts = <Map<String, Object?>>[];
    final sourcePackages = <String, ScriptPackage>{};
    for (final package in packages) {
      final token = await session.scheduleWidgetIdentity(
        package.manifest.id,
        package.digest,
      );
      if (!current()) return;
      if (token == null) continue;
      final scope = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                profile.id,
                school.id,
                token,
                package.manifest.id,
                package.digest,
              ]),
            ),
          )
          .toString();
      sourcePackages[scope] = package;
      contexts.add({
        'scope': scope,
        'label':
            '${profile.name} · ${school.displayName} · ${package.manifest.name}',
        'persistent': session.scheduleWidgetPersistence,
      });
    }
    if (!current()) return;
    _sources.clear();
    _sources.addAll({
      for (final entry in sourcePackages.entries)
        entry.key: CapabilitySource(
          packageId: entry.value.manifest.id,
          digest: entry.value.digest,
        ),
    });
    final granted =
        await channel!.invokeListMethod<String>('synchronize', {
          'revision': serial,
          'contexts': contexts,
        }) ??
        const [];
    for (final scope in granted) {
      final package = sourcePackages[scope];
      if (package == null || !current()) continue;
      final cache = await session.latestCachedCapability(
        'schedule.week',
        packageId: package.manifest.id,
        expectedDigest: package.digest,
      );
      if (!current()) return;
      Future<Map<String, Object?>?> project(ScriptCachedData? cached) async {
        final raw = cached?.data;
        if (cached == null ||
            raw is! Map ||
            raw['timeZone'] is! String ||
            package.manifest.capability('schedule.week')?.schemaVersion !=
                '1.3') {
          return null;
        }
        final date = await channel!.invokeMethod<String>(
          'schoolDate',
          raw['timeZone'],
        );
        if (!current() || date == null) return null;
        return scheduleWidgetSnapshot(
          cached,
          schoolDate: date,
          schemaVersion: '1.3',
        );
      }

      var snapshot = await project(cache);
      if (!current()) return;
      bool knowsToday(Map<String, Object?>? value) {
        final days = value?['days'];
        return days is List &&
            days.isNotEmpty &&
            days.first is Map &&
            days.first['known'] == true;
      }

      // Browsing a historical week must not replace a usable current-day cache.
      // This reads the same approved source locally; it never refreshes school data.
      if (!knowsToday(snapshot)) {
        final defaults = await session.cachedCapability(
          'schedule.week',
          packageId: package.manifest.id,
          expectedDigest: package.digest,
        );
        if (!current()) return;
        final fallback = await project(defaults);
        if (!current()) return;
        if (knowsToday(fallback)) snapshot = fallback;
      }
      if (!current()) return;
      await channel!.invokeMethod<void>('publish', {
        'revision': serial,
        'scope': scope,
        'snapshot': snapshot,
      });
    }
    if (current()) await _resolvePending(serial);
  }

  Future<void> _open(Object? id) async {
    if (!_ready || _disposed || id is! int) return;
    _pendingWidgetId = id;
    _pendingBinding =
        profiles.isRestored && profiles.active.session.isConfigured
        ? _identity
        : null;
    _changed();
  }

  Future<void> _resolvePending(int serial) async {
    final id = _pendingWidgetId;
    if (id == null || _disposed || serial != _serial) return;
    final scope = await channel!.invokeMethod<String>('widgetScope', id);
    if (_disposed || serial != _serial || id != _pendingWidgetId) return;
    _pendingWidgetId = null;
    _pendingBinding = null;
    final source = _sources[scope];
    if (source == null) return;
    pending = ScheduleWidgetOpenRequest(serial, source);
    notifyListeners();
  }

  bool consume(ScheduleWidgetOpenRequest request) {
    // Cache refreshes advance publication serials, not navigation. Identity and
    // approved-source changes already discard pending synchronously in _changed.
    if (_disposed || !identical(request, pending)) {
      return false;
    }
    pending = null;
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    if (channel != null) {
      profiles.removeListener(_changed);
      WidgetsBinding.instance.removeObserver(this);
      channel!.setMethodCallHandler(null);
    }
    super.dispose();
  }
}
