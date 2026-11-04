/// ADR-074: fixed read-only system tools, with explicit current-scope grants.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../session/profile_controller.dart';
import '../../session/session_controller.dart';
import '../adapter_service.dart';
import '../scripts/registry.dart';
import 'app_functions_projection.dart';

enum AiQuery {
  schedule('getSchedule', 'schedule.week'),
  classrooms('findAvailableClassrooms', 'classroom.available'),
  grades('getGrades', 'grades.list');

  const AiQuery(this.function, this.capability);
  final String function;
  final String capability;
}

class AiServiceChoice {
  const AiServiceChoice(
    this.query, {
    required this.available,
    required this.authorized,
  });
  final AiQuery query;
  final bool available;
  final bool authorized;
}

class _Source {
  const _Source(
    this.session,
    this.school,
    this.generation,
    this.identityRevision,
    this.registry,
    this.epoch,
    this.packageId,
    this.digest,
    this.version,
  );
  final SessionController session;
  final String school;
  final int generation;
  final int identityRevision;
  final ScriptRegistry registry;
  final int epoch;
  final String packageId;
  final String digest;
  final String version;

  String get grantKey => '$school:$identityRevision:$epoch:$packageId:$digest';
}

class AppFunctionsController extends ChangeNotifier {
  AppFunctionsController({
    required this.profiles,
    MethodChannel? channel,
    DateTime Function()? now,
    Future<ScriptRegistry> Function(SessionController)? registryProvider,
    this.timeout = const Duration(seconds: 28),
  }) : _channel = channel,
       _now = now ?? DateTime.now,
       _registryProvider =
           registryProvider ?? ((session) => session.scriptRegistry) {
    profiles.addListener(_scopeChanged);
    _scopeChanged();
    _channel?.setMethodCallHandler(_handleMethod);
  }

  final ProfileController profiles;
  final MethodChannel? _channel;
  final DateTime Function() _now;
  final Future<ScriptRegistry> Function(SessionController) _registryProvider;
  final Duration timeout;
  final _grants = <AiQuery, String>{};
  final _pending = <String, ScriptRunCancellation>{};
  SessionController? _active;
  String? _school;
  int? _generation;
  int? _identityRevision;
  bool _disposed = false;

  Future<bool> isPlatformSupported() async {
    try {
      return await _channel?.invokeMethod<bool>('isSupported') == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  void _scopeChanged() {
    final session = profiles.active.session;
    final identityChanged =
        !identical(_active, session) ||
        _school != session.selectedSchool?.id ||
        _identityRevision != session.identityRevision ||
        profiles.busy;
    if (identityChanged || _generation != session.trustedScriptViewGeneration) {
      _active = session;
      _school = session.selectedSchool?.id;
      _generation = session.trustedScriptViewGeneration;
      _identityRevision = session.identityRevision;
      if (identityChanged) _grants.clear();
      for (final cancellation in _pending.values) {
        cancellation.cancel();
      }
    }
    if (!_disposed) notifyListeners();
  }

  Future<List<AiServiceChoice>> choices() async => [
    for (final query in AiQuery.values) await _choice(query),
  ];

  Future<AiServiceChoice> _choice(AiQuery query) async {
    final source = await _resolve(query);
    return AiServiceChoice(
      query,
      available: source != null,
      authorized: source != null && _grants[query] == source.grantKey,
    );
  }

  /// Called only by the explicit native settings switch, never by a system tool.
  Future<void> setAllowed(AiQuery query, bool allowed) async {
    if (!allowed) {
      _grants.remove(query);
      // A revoke cancels outstanding requests immediately. Cancellation is local
      // to AI work and never cancels an unrelated native page request.
      for (final cancellation in _pending.values) {
        cancellation.cancel();
      }
    } else {
      final source = await _resolve(query);
      if (source != null && _current(source)) _grants[query] = source.grantKey;
    }
    if (!_disposed) notifyListeners();
  }

  Future<_Source?> _resolve(AiQuery query) async {
    if (_disposed || !profiles.isRestored || profiles.busy) return null;
    final session = profiles.active.session;
    final school = session.selectedSchool?.id;
    final generation = session.trustedScriptViewGeneration;
    final identityRevision = session.identityRevision;
    if (!session.isRestored || session.hardwareUnlockFailed || school == null) {
      return null;
    }
    try {
      final registry = await _registryProvider(session);
      final package = registry.provider(school, query.capability);
      final capability = package?.manifest.capability(query.capability);
      if (package == null ||
          package.requiresUpdate ||
          capability == null ||
          (query == AiQuery.classrooms &&
              !const {'1.2', '1.3'}.contains(capability.schemaVersion))) {
        return null;
      }
      final source = _Source(
        session,
        school,
        generation,
        identityRevision,
        registry,
        registry.epoch,
        package.manifest.id,
        package.digest,
        capability.schemaVersion,
      );
      return _current(source) ? source : null;
    } catch (_) {
      return null;
    }
  }

  bool _current(_Source source) =>
      !_disposed &&
      profiles.isRestored &&
      !profiles.busy &&
      identical(profiles.active.session, source.session) &&
      source.session.isRestored &&
      !source.session.hardwareUnlockFailed &&
      source.session.selectedSchool?.id == source.school &&
      source.session.trustedScriptViewGeneration == source.generation &&
      source.session.identityRevision == source.identityRevision &&
      source.registry.epoch == source.epoch &&
      source.registry.find(source.packageId)?.enabled == true &&
      source.registry.find(source.packageId)?.package.digest == source.digest;

  Future<Object?> _handleMethod(MethodCall call) async {
    final arguments = call.arguments;
    if (arguments is! Map || arguments['requestId'] is! String) {
      return jsonEncode(_error('failed', 'invalidArguments'));
    }
    final id = arguments['requestId'] as String;
    if (call.method == 'cancel') {
      cancel(id);
      return null;
    }
    if (call.method != 'execute' ||
        arguments['function'] is! String ||
        arguments['arguments'] is! Map) {
      return jsonEncode(_error('failed', 'invalidArguments'));
    }
    return jsonEncode(
      await execute(
        id,
        arguments['function'] as String,
        Map<String, Object?>.from(arguments['arguments'] as Map),
      ),
    );
  }

  void cancel(String requestId) => _pending[requestId]?.cancel();

  Future<Map<String, Object?>> execute(
    String requestId,
    String function,
    Map<String, Object?> arguments,
  ) async {
    if (_disposed) return _error('unavailable', 'openApp');
    // Lifecycle cancellation does not notify SessionController listeners.
    // Observe its new execution generation before admitting this new request;
    // otherwise a later ordinary query notification would cancel this request
    // as though it belonged to the previous foreground generation.
    _scopeChanged();
    if (requestId.isEmpty ||
        requestId.length > 128 ||
        _pending.containsKey(requestId)) {
      return _error('failed', 'invalidArguments');
    }
    if (_pending.length >= 4) return _error('unavailable', 'busy');
    final cancellation = ScriptRunCancellation();
    _pending[requestId] = cancellation;
    try {
      return await _execute(function, arguments, cancellation).timeout(
        timeout,
        onTimeout: () {
          cancellation.cancel();
          return _error('cancelled', 'cancelled');
        },
      );
    } catch (_) {
      return _error('unavailable', 'openApp');
    } finally {
      _pending.remove(requestId);
      cancellation.cancel();
      cancellation.dispose();
    }
  }

  Future<Map<String, Object?>> _execute(
    String function,
    Map<String, Object?> arguments,
    ScriptRunCancellation cancellation,
  ) async {
    if (function == 'describeAvailableServices') {
      if (arguments.isNotEmpty) return _error('failed', 'invalidArguments');
      if (!profiles.isRestored ||
          profiles.busy ||
          !profiles.active.session.isRestored ||
          profiles.active.session.hardwareUnlockFailed ||
          profiles.active.session.selectedSchool == null) {
        return _error('unavailable', 'openApp');
      }
      final owner = profiles.active.session;
      final school = owner.selectedSchool?.id;
      final generation = owner.trustedScriptViewGeneration;
      final identityRevision = owner.identityRevision;
      final registry = await _registryProvider(owner);
      if (cancellation.isCancelled) return _error('cancelled', 'cancelled');
      final epoch = registry.epoch;
      final available = await choices();
      if (cancellation.isCancelled ||
          !identical(profiles.active.session, owner) ||
          school != owner.selectedSchool?.id ||
          generation != owner.trustedScriptViewGeneration ||
          identityRevision != owner.identityRevision ||
          registry.epoch != epoch) {
        return _error('cancelled', 'cancelled');
      }
      if (_disposed ||
          !profiles.isRestored ||
          profiles.busy ||
          !profiles.active.session.isRestored ||
          profiles.active.session.hardwareUnlockFailed ||
          profiles.active.session.selectedSchool == null) {
        return _error('unavailable', 'openApp');
      }
      return {
        'status': 'ok',
        'services': [
          for (final choice in available)
            {
              'name': choice.query.function,
              'available': choice.available,
              'authorized': choice.authorized,
            },
        ],
      };
    }
    final query = AiQuery.values
        .where((q) => q.function == function)
        .firstOrNull;
    if (query == null) return _error('unavailable', 'unsupportedFunction');
    final AiQueryInput input;
    try {
      input = AiQueryInput.parse(query.function, arguments);
    } on FormatException {
      return _error('failed', 'invalidArguments');
    }
    final source = await _resolve(query);
    if (cancellation.isCancelled) return _error('cancelled', 'cancelled');
    if (source == null) return _error('unavailable', 'openApp');
    if (_grants[query] != source.grantKey) {
      return _error('unavailable', 'authorizationRequired');
    }
    try {
      final run = await source.session
          .runTrustedScript(
            source.packageId,
            query.capability,
            expectedDigest: source.digest,
            params: input.params,
            interactive: false,
            cancellation: cancellation,
          )
          .timeout(
            timeout,
            onTimeout: () {
              cancellation.cancel();
              return const CapabilityRun.failed(
                CapabilityFailureKind.run,
                'script_cancelled',
              );
            },
          );
      if (cancellation.isCancelled ||
          !_current(source) ||
          _grants[query] != source.grantKey) {
        return _error('cancelled', 'cancelled');
      }
      if (!run.ok) return _failure(run);
      final projection = projectAiQuery(query.function, run.data, input);
      final result = <String, Object?>{
        'status': projection.partial
            ? 'partial'
            : projection.empty
            ? 'empty'
            : 'ok',
        'source': {'packageId': source.packageId, 'digest': source.digest},
        'schemaVersion': source.version,
        'observedAt': _now().toUtc().toIso8601String(),
        'stale': false,
        'partial': projection.partial,
        'parameters': input.params,
        'data': projection.data,
      };
      if (utf8.encode(jsonEncode(result)).length > 131072) {
        return _error('failed', 'resultTooLarge');
      }
      return result;
    } on FormatException {
      return _error('failed', 'invalidResponse');
    } catch (_) {
      return _error('failed', 'queryFailed');
    }
  }

  Map<String, Object?> _failure(CapabilityRun run) {
    if (run.failureKind == CapabilityFailureKind.configuration ||
        run.reason == 'configuration_required') {
      return _error('configurationRequired', 'openApp');
    }
    if (run.failureKind == CapabilityFailureKind.auth ||
        const {
          'authentication_required',
          'auth_expired',
          'credentials_rejected',
          'interaction_required',
        }.contains(run.reason)) {
      return _error('authenticationRequired', 'openApp');
    }
    if (run.reason == 'script_cancelled') {
      return _error('cancelled', 'cancelled');
    }
    if (run.reason == 'foreground_required') {
      return _error('unavailable', 'openApp');
    }
    return _error('failed', 'queryFailed');
  }

  static Map<String, Object?> _error(String status, String reason) => {
    'status': status,
    'reason': reason,
  };

  @override
  void dispose() {
    _disposed = true;
    profiles.removeListener(_scopeChanged);
    _channel?.setMethodCallHandler(null);
    _grants.clear();
    for (final cancellation in _pending.values) {
      cancellation.cancel();
    }
    super.dispose();
  }
}
