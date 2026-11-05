/// ADR-097: a foreground owner, never a persistent background service.
part of 'session_controller.dart';

class ScriptExecutionUpdate {
  const ScriptExecutionUpdate(this.trigger, this.registrationId, this.result);
  final String trigger;
  final String? registrationId;

  /// Null while queued/running. Results have already passed the normal session.
  final CapabilityRun? result;
}

class _ScriptScheduledCall {
  _ScriptScheduledCall(this.at);
  final int at;
  Timer? timer;
  final cancellation = ScriptRunCancellation();
  void cancel() {
    timer?.cancel();
    cancellation.cancel();
  }
}

class ScriptExecutionScope extends ChangeNotifier {
  ScriptExecutionScope._(this._session, this.package, this.capability)
    : _generation = _session.trustedScriptViewGeneration,
      _dataGeneration = _session.trustedScriptDataGeneration;

  final SessionController _session;
  final ScriptPackage package;
  final String capability;
  final int _generation, _dataGeneration;
  final _memory = ScriptExecutionMemory();
  final _jobs = <String, _ScriptScheduledCall>{};
  ScriptRunCancellation? _running;
  Future<CapabilityRun>? _pending;
  ScriptExecutionUpdate? _update;
  bool _closed = false;
  ScriptExecutionUpdate? get update => _update;
  bool get isClosed => _closed;
  bool get isBusy => _pending != null;
  bool get hasScheduledCalls => _jobs.isNotEmpty;

  bool get _active =>
      !_closed &&
      !_session._scripts.disposed &&
      _session._scripts.foreground &&
      _session.trustedScriptViewGeneration == _generation &&
      _session.trustedScriptDataGeneration == _dataGeneration &&
      _session.selectedSchool?.id == package.manifest.schoolId;

  static CapabilityRun _failure(String code) =>
      CapabilityRun.failed(CapabilityFailureKind.run, code);

  Future<CapabilityRun> run({
    Map<String, dynamic>? params,
    bool interactive = true,
  }) => _start(params: params, interactive: interactive, trigger: 'initial');

  /// Host-directed button/event invocation. No business arguments are accepted.
  Future<CapabilityRun> invoke(String id) {
    if (isBusy) return Future.value(_failure('execution_busy'));
    cancel(id);
    return _start(id: id, trigger: 'manual');
  }

  void cancel(String id) => _jobs.remove(id)?.cancel();

  void _cancelAppointments() {
    for (final job in _jobs.values) {
      job.cancel();
    }
    _jobs.clear();
  }

  Future<CapabilityRun> _start({
    String? id,
    required String trigger,
    Map<String, dynamic>? params,
    bool interactive = false,
    _ScriptScheduledCall? job,
  }) {
    if (!_active) return Future.value(_failure('script_cancelled'));
    if (isBusy) return Future.value(_failure('execution_busy'));
    final registration = id == null ? null : _memory.registrations[id];
    Future<CapabilityRun> rejected(String code) {
      _cancelAppointments();
      final result = _failure(code);
      _update = ScriptExecutionUpdate(trigger, id, result);
      notifyListeners();
      return Future.value(result);
    }

    if (id != null && registration == null) {
      return rejected('execution_registration_missing');
    }
    if (registration != null &&
        !_memory.values.containsKey(registration.stateKey)) {
      return rejected('execution_state_missing');
    }
    final turn = ScriptExecutionTurn(
      _memory,
      trigger: trigger,
      handler: registration?.handler,
      stateKey: registration?.stateKey,
      deadline: job == null ? null : job.at + 30000,
    );
    final cancellation = job?.cancellation ?? ScriptRunCancellation();
    _running = cancellation;
    final future = _session
        .runTrustedScript(
          package.manifest.id,
          capability,
          expectedDigest: package.digest,
          params: params,
          interactive: interactive,
          cancellation: cancellation,
          execution: turn,
        )
        .then((result) {
          if (!_active || cancellation.isCancelled) {
            turn.discard();
            return _failure('script_cancelled');
          }
          if (result.ok) {
            turn.commit(_memory);
            for (final change in turn.schedules.entries) {
              cancel(change.key);
              final at = change.value;
              if (at == null) continue;
              final next = _ScriptScheduledCall(at);
              _jobs[change.key] = next;
              final delay = at - DateTime.now().millisecondsSinceEpoch;
              next.timer = Timer(
                Duration(milliseconds: delay < 0 ? 0 : delay),
                () => unawaited(_fire(change.key, next)),
              );
            }
          } else {
            turn.discard();
            // A failed refresh must never keep another automatic retry alive.
            _cancelAppointments();
          }
          return result;
        })
        .catchError((Object _) {
          turn.discard();
          _cancelAppointments();
          return _failure('script_failed');
        })
        .whenComplete(() {
          _pending = null;
          _running = null;
        });
    _pending = future;
    _update = ScriptExecutionUpdate(trigger, id, null);
    notifyListeners();
    return future.then((result) {
      if (_active) {
        _update = ScriptExecutionUpdate(trigger, id, result);
        notifyListeners();
      }
      return result;
    });
  }

  Future<void> _fire(String id, _ScriptScheduledCall job) async {
    while (_pending != null) {
      await _pending;
      if (!_active || !identical(_jobs[id], job)) return;
    }
    if (!_active ||
        !identical(_jobs[id], job) ||
        job.cancellation.isCancelled) {
      return;
    }
    // Timer waits are relative; a wall-clock adjustment must not run an
    // appointment before its requested absolute time.
    final remaining = job.at - DateTime.now().millisecondsSinceEpoch;
    if (remaining > 0) {
      job.timer = Timer(
        Duration(milliseconds: remaining),
        () => unawaited(_fire(id, job)),
      );
      return;
    }
    await _start(id: id, trigger: 'timer', job: job);
    if (identical(_jobs[id], job)) _jobs.remove(id);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _running?.cancel();
    _cancelAppointments();
    _memory.clear();
    _update = null;
    _session._scripts.executions.remove(this);
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}

extension RegisteredScriptSession on SessionController {
  /// The page opts into scoped read-only execution. Ordinary calls, preload and
  /// system queries never acquire this port implicitly.
  Future<ScriptExecutionScope?> openScriptExecutionScope(
    String capability, {
    String? packageId,
    String? expectedDigest,
  }) async {
    final generation = trustedScriptViewGeneration;
    final dataGeneration = trustedScriptDataGeneration;
    final school = selectedSchool?.id;
    final ScriptRegistry registry;
    try {
      registry = await scriptRegistry;
    } catch (_) {
      return null;
    }
    final installation = packageId == null ? null : registry.find(packageId);
    final package = packageId == null
        ? registry.provider(school ?? '', capability)
        : installation?.package;
    if (_scripts.disposed ||
        !_scripts.foreground ||
        hardwareUnlockFailed ||
        generation != trustedScriptViewGeneration ||
        dataGeneration != trustedScriptDataGeneration ||
        selectedSchool?.id != school ||
        package == null ||
        package.requiresUpdate ||
        package.manifest.sdkVersion < 19 ||
        package.manifest.schoolId != school ||
        (packageId != null && installation?.enabled != true) ||
        (expectedDigest != null && package.digest != expectedDigest) ||
        package.manifest.capability(capability) == null ||
        foregroundCommunityCapabilities.contains(capability) ||
        capability == 'climate.command' ||
        capability == 'query.controls' ||
        package.manifest.accounts.any((a) => a.loginCapability == capability) ||
        (capability != 'card.qr' &&
            !package.manifest.home.any((e) => e.capability == capability))) {
      return null;
    }
    final scope = ScriptExecutionScope._(this, package, capability);
    _scripts.executions.add(scope);
    return scope;
  }
}
