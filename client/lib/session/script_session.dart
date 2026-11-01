/// 🔒 ADR-034: selected-school script execution; UI never obtains CredentialStore.
part of 'session_controller.dart';

typedef ScriptBrowserCall =
    Future<Object?> Function(String method, Map<String, Object?> arguments);
typedef ScriptBrowserPresenter =
    Future<Object?> Function(
      ScriptPackage package,
      Future<Object?> Function(ScriptBrowserCall call) execute,
    );
typedef ScriptInputPresenter =
    Future<Object?> Function(
      ScriptPackage package,
      Future<Object?> Function(ScriptInputCall input) execute,
    );

class _ScriptSessionState {
  Future<ScriptRegistry>? registry;
  Future<void> queue = Future.value();
  bool recoveredRegistry = false;
  ScriptBrowserPresenter? presenter;
  ScriptInputPresenter? inputPresenter;
  Future<bool> Function()? storageConsent;
  int generation = 0;
  bool disposed = false;
  int homeRevision = 0;
  Future<void>? refreshingHome;
  final Set<ScriptHttpTransport> transports = {};
  final Map<String, Map<String, dynamic>> climateDevices = {};
  final Map<String, Map<String, dynamic>> climateStates = {};
  final Set<String> busyActions = {};
}

final _scriptStates = Expando<_ScriptSessionState>();

extension TrustedScriptSession on SessionController {
  _ScriptSessionState get _scripts =>
      _scriptStates[this] ??= _ScriptSessionState();

  int get trustedScriptViewGeneration => _scripts.generation;

  /// 🔒 ADR-040 §4: the UI can review this immutable request, not issue grants.
  Future<ClimateActionRequest> prepareClimateCommand(
    String deviceId,
    String command,
    Object value,
  ) async {
    if (!climateControlAvailable || !climateActionForeground) {
      throw const ScriptActionException('action_platform_unavailable');
    }
    final generation = _scripts.generation;
    final school = _school;
    if (school == null) {
      throw const ScriptActionException('action_not_authorized');
    }
    final package = (await scriptRegistry).provider(
      school.id,
      'climate.command',
    );
    final device = _scripts.climateDevices[deviceId];
    final observed = _scripts.climateStates[deviceId];
    if (_scripts.generation != generation ||
        package == null ||
        device == null ||
        observed == null ||
        observed['power'] is! bool ||
        observed['mode'] is! String ||
        observed['fanSpeed'] is! String ||
        observed['targetTemperature'] is! int ||
        observed['online'] == false ||
        observed['errorCode'] != null ||
        device['_packageDigest'] != package.digest ||
        DateTime.now().millisecondsSinceEpoch - (device['_verifiedAt'] as int) >
            300000) {
      throw const ScriptActionException('action_device_not_verified');
    }
    final settings = climateTarget(device, command, value);
    return ClimateActionRequest._(
      this,
      generation,
      package,
      deviceId,
      device['label'] as String,
      command,
      settings,
    );
  }

  Future<ClimateActionResult> runClimateCommand(
    ClimateActionRequest request, {
    required Future<bool> Function(ClimateActionRequest) confirm,
    required bool Function() isCurrent,
  }) async {
    final state = _scripts;
    final key = '${request._generation}:${request.deviceId}';
    bool valid() =>
        climateActionForeground &&
        identical(request._owner, this) &&
        !state.disposed &&
        state.generation == request._generation &&
        state.climateDevices[request.deviceId]?['_packageDigest'] ==
            request._package.digest &&
        state.climateStates[request.deviceId] != null &&
        _school?.id == request._package.manifest.schoolId &&
        isCurrent() &&
        DateTime.now().isBefore(request._expiresAt);
    if (!climateControlAvailable ||
        request._used ||
        !valid() ||
        !state.busyActions.add(key)) {
      return const ClimateActionResult('rejected');
    }
    request._used = true;
    try {
      if (!await confirm(request) || !valid()) {
        return const ClimateActionResult('rejected');
      }
      final current = (await scriptRegistry).provider(
        request._package.manifest.schoolId,
        'climate.command',
      );
      if (!valid() || current?.digest != request._package.digest) {
        return const ClimateActionResult('rejected');
      }
      final scope = ScriptActionScope(
        package: request._package,
        params: request._params,
        isActive: valid,
      );
      final result = await _queueTrustedScript(
        request._package.manifest.id,
        'climate.command',
        params: request._params,
        interactive: false,
        actionScope: scope,
      );
      var status = climateCommandOutcome(
        requestStarted: scope.requestStarted,
        ok: result.ok,
        output: result.data,
      );
      CapabilityRun? observed;
      if (valid()) {
        // Exactly one independent read; never retry a command, even on unknown.
        observed = await runTrustedScript(
          request._package.manifest.id,
          'climate.status',
          params: {'deviceId': request.deviceId},
          interactive: false,
        );
        if (observed.ok &&
            observed.data is Map &&
            (observed.data as Map)['deviceId'] == request.deviceId &&
            request.settings.entries.every(
              (entry) => (observed!.data as Map)[entry.key] == entry.value,
            )) {
          if (status == 'accepted' || status == 'unknown') status = 'applied';
        }
      }
      return ClimateActionResult(status, observed: valid() ? observed : null);
    } catch (_) {
      return const ClimateActionResult('unknown');
    } finally {
      state.busyActions.remove(key);
    }
  }

  set scriptStorageConsent(Future<bool> Function()? consent) =>
      _scripts.storageConsent = consent;

  ScriptBrowserPresenter? get scriptBrowserPresenter => _scripts.presenter;

  void cancelTrustedScriptRuns() => _cancelTrustedScripts();

  set scriptBrowserPresenter(ScriptBrowserPresenter? presenter) =>
      _scripts.presenter = presenter;

  ScriptInputPresenter? get scriptInputPresenter => _scripts.inputPresenter;
  set scriptInputPresenter(ScriptInputPresenter? presenter) =>
      _scripts.inputPresenter = presenter;

  Future<ScriptRegistry> get scriptRegistry =>
      _scripts.registry ??= _openScriptRegistry();

  Future<ScriptRegistry> _openScriptRegistry() async {
    final blobs = await _resolveBlobs();
    try {
      return await ScriptRegistry.open(blobs);
    } on FormatException {
      // Corrupt optional local installs grant no execution; legacy remains usable.
      _scripts.recoveredRegistry = true;
      return ScriptRegistry.empty(blobs);
    }
  }

  bool get scriptRegistryRecovered => _scripts.recoveredRegistry;

  void _cancelTrustedScripts({bool dispose = false}) {
    final state = _scriptStates[this];
    if (state == null) return;
    state.generation++;
    state.climateDevices.clear();
    state.climateStates.clear();
    state.busyActions.clear();
    state.homeRevision++;
    state.refreshingHome = null;
    if (dispose) {
      state.disposed = true;
      state.presenter = null;
      state.inputPresenter = null;
    }
    for (final transport in state.transports.toList()) {
      transport.close();
    }
    state.transports.clear();
  }

  /// Reconstruct local schools without requiring a catalog release or App update.
  Future<void> _restoreScriptSchools() async {
    final ScriptRegistry registry;
    try {
      registry = await scriptRegistry;
    } catch (_) {
      return;
    }
    final schools = [
      for (final s in _availableSchools)
        if (!s.adapterId.startsWith('script:')) s,
    ];
    // The first enabled school package owns its local school descriptor.
    // The workbench lists newest first; a later enhancement must not rename
    // an existing school or replace its header owner merely by installation.
    for (final installation in registry.installations.reversed) {
      if (!installation.enabled) continue;
      final m = installation.package.manifest;
      if (schools.any((school) => school.id == m.schoolId)) continue;
      final origins = m.network.origins
          .map((uri) => '${uri.toString().replaceFirst(RegExp(r'/$'), '')}/*')
          .toList();
      schools.add(
        SchoolDescriptor(
          id: m.schoolId,
          displayName: m.name,
          subtitle: m.id,
          adapterId: 'script:${m.id}',
          login: LoginManifestView(
            schoolId: m.schoolId,
            url:
                m.network.origins.firstOrNull?.toString() ??
                'https://example.invalid',
            navigationAllow: origins,
            successUrlMatches: const [],
            brokerView: BrokerManifestView(
              allow: origins,
              credentials: const {},
            ),
          ),
        ),
      );
    }
    _availableSchools = List.unmodifiable(schools);
    if (_school?.adapterId.startsWith('script:') ?? false) {
      _school = schools.where((s) => s.id == _school?.id).firstOrNull;
    }
  }

  Future<void> installTrustedScript(
    ScriptPackage package, {
    required String approvedDigest,
  }) async {
    final registry = await scriptRegistry;
    await registry.install(package, approvedDigest: approvedDigest);
    _scripts.recoveredRegistry = false;
    _cancelTrustedScripts();
    await _restoreScriptSchools();
    if (!_scripts.disposed) onCredentialsChanged();
  }

  Future<void> enableTrustedScript(String id, bool enabled) async {
    await (await scriptRegistry).setEnabled(id, enabled);
    _cancelTrustedScripts();
    await _restoreScriptSchools();
    _scheduleSessionPersist();
    if (!_scripts.disposed) onCredentialsChanged();
  }

  Future<void> removeTrustedScript(String id) async {
    await (await scriptRegistry).remove(id);
    _cancelTrustedScripts();
    await _restoreScriptSchools();
    _scheduleSessionPersist();
    if (!_scripts.disposed) onCredentialsChanged();
  }

  /// 🔒 ADR-043 §1: explicit source selection revokes all in-flight UI results.
  Future<void> selectTrustedScriptProvider(
    String schoolId,
    String capability,
    String? packageId,
  ) async {
    await (await scriptRegistry).setProviderOverride(
      schoolId,
      capability,
      packageId,
    );
    _cancelTrustedScripts();
    if (!_scripts.disposed) onCredentialsChanged();
  }

  Future<void> selectTrustedScriptSchool(String id) async {
    final installation = (await scriptRegistry).find(id);
    if (installation == null || !installation.enabled) {
      throw StateError('script_not_installed');
    }
    final school = _availableSchools
        .where((s) => s.id == installation.package.manifest.schoolId)
        .firstOrNull;
    if (school == null) throw StateError('script_school_unavailable');
    selectSchool(school);
  }

  Future<Set<String>> trustedScriptCapabilities() async {
    final school = _school;
    if (school == null) return const {};
    final registry = await scriptRegistry;
    return {
      for (final installation in registry.installations)
        if (installation.enabled &&
            installation.package.manifest.schoolId == school.id)
          for (final cap in installation.package.manifest.capabilities)
            if (registry.provider(school.id, cap.id) != null) cap.id,
    };
  }

  /// ADR-038: these APIs expose validated business outputs, never a store.
  int get homeDataRevision => _scripts.homeRevision;

  Future<ScriptCachedData?> cachedCapability(
    String capability, {
    Map<String, dynamic>? params,
  }) async {
    final school = _school;
    final generation = _scripts.generation;
    if (school == null || _scripts.disposed) return null;
    try {
      final package = (await scriptRegistry).provider(school.id, capability);
      if (package == null ||
          generation != _scripts.generation ||
          _school?.id != school.id) {
        return null;
      }
      return ScriptDataCache(
        _store,
      ).read(package, capability, params: params ?? const {});
    } on Object {
      return null;
    }
  }

  Future<ScriptCachedData?> latestCachedCapability(String capability) async {
    final school = _school;
    final generation = _scripts.generation;
    if (school == null || _scripts.disposed) return null;
    try {
      final package = (await scriptRegistry).provider(school.id, capability);
      if (package == null ||
          generation != _scripts.generation ||
          _school?.id != school.id) {
        return null;
      }
      return ScriptDataCache(_store).latest(package, capability);
    } on Object {
      return null;
    }
  }

  Future<void> refreshHomeData({bool force = false}) {
    final state = _scripts;
    if (state.refreshingHome != null) return state.refreshingHome!;
    final generation = state.generation;
    final school = _school;
    if (school == null || state.disposed) return Future.value();
    final future = () async {
      try {
        final registry = await scriptRegistry;
        for (final installation in registry.installations.toList()) {
          final package = installation.package;
          if (!installation.enabled || package.manifest.schoolId != school.id) {
            continue;
          }
          for (final query in package.manifest.home.where((e) => e.preload)) {
            // Only the selected handler owns this capability's background work.
            if (registry.provider(school.id, query.capability)?.digest !=
                package.digest) {
              continue;
            }
            if (state.disposed ||
                state.generation != generation ||
                _school?.id != school.id) {
              return;
            }
            final cached = ScriptDataCache(
              _store,
            ).read(package, query.capability, params: query.params);
            if (!force && cached != null && !cached.isStale) continue;
            await runTrustedScript(
              package.manifest.id,
              query.capability,
              params: query.params,
              interactive: false,
            );
          }
        }
      } on Object {
        // Optional background data never replaces a prior successful snapshot.
      }
    }();
    state.refreshingHome = future;
    return future.whenComplete(() {
      if (identical(state.refreshingHome, future)) state.refreshingHome = null;
    });
  }

  Future<CapabilityRun> runTrustedScript(
    String id,
    String capability, {
    Map<String, dynamic>? params,
    bool interactive = true,
    String? htmlStdlib,
    ScriptBrowserCall? browserCall,
    ScriptInputCall? inputCall,
    void Function(String, String)? onLog,
  }) => _queueTrustedScript(
    id,
    capability,
    params: params,
    interactive: interactive,
    htmlStdlib: htmlStdlib,
    browserCall: browserCall,
    inputCall: inputCall,
    onLog: onLog,
  );

  Future<CapabilityRun> _queueTrustedScript(
    String id,
    String capability, {
    Map<String, dynamic>? params,
    bool interactive = true,
    String? htmlStdlib,
    ScriptBrowserCall? browserCall,
    ScriptInputCall? inputCall,
    void Function(String, String)? onLog,
    ScriptActionScope? actionScope,
  }) {
    final state = _scripts;
    final generation = state.generation;
    final pending = state.queue.then<CapabilityRun>((_) {
      if (state.disposed || state.generation != generation) {
        return const CapabilityRun.failed(
          CapabilityFailureKind.run,
          'script_cancelled',
        );
      }
      return _executeTrustedScript(
        id,
        capability,
        expectedGeneration: generation,
        params: params,
        interactive: interactive,
        htmlStdlib: htmlStdlib,
        browserCall: browserCall,
        inputCall: inputCall,
        onLog: onLog,
        actionScope: actionScope,
      );
    });
    state.queue = pending.then<void>((_) {}, onError: (Object _) {});
    return pending;
  }

  Future<CapabilityRun> _executeTrustedScript(
    String id,
    String capability, {
    required int expectedGeneration,
    Map<String, dynamic>? params,
    bool interactive = true,
    String? htmlStdlib,
    ScriptBrowserCall? browserCall,
    ScriptInputCall? inputCall,
    void Function(String, String)? onLog,
    ScriptActionScope? actionScope,
  }) async {
    if (capability == 'climate.command' && actionScope == null) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'action_confirmation_required',
      );
    }
    final state = _scripts;
    final ScriptRegistry registry;
    try {
      registry = await scriptRegistry;
    } catch (_) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.load,
        'script_registry_unavailable',
      );
    }
    if (state.disposed || state.generation != expectedGeneration) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'script_cancelled',
      );
    }
    final installation = registry.find(id);
    final school = _school;
    if (state.disposed ||
        installation == null ||
        !installation.enabled ||
        school == null ||
        installation.package.manifest.schoolId != school.id) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.load,
        'script_not_authorized',
      );
    }
    final admissionEpoch = registry.epoch;
    try {
      if (interactive) {
        await ensurePersistentStore(
          confirmSoftwareFallback: state.storageConsent ?? () async => false,
        );
      }
    } catch (_) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'credential_storage_unavailable',
      );
    }
    if (state.disposed ||
        state.generation != expectedGeneration ||
        registry.epoch != admissionEpoch ||
        _school?.id != school.id) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'script_cancelled',
      );
    }
    final package = installation.package;
    final generation = expectedGeneration;
    final epoch = admissionEpoch;
    final store = _store;
    final backend = _secure;
    bool active() =>
        !state.disposed &&
        state.generation == generation &&
        registry.epoch == epoch &&
        identical(store, _store) &&
        _school?.id == school.id &&
        registry.find(id)?.enabled == true &&
        registry.find(id)?.package.digest == package.digest;
    final transport = ScriptHttpTransport(policy: package.manifest.network);
    state.transports.add(transport);
    DevLog.instance.runtime('script start: $id $capability');
    CapabilityRun result;
    try {
      final credentials = ScriptCredentials(
        store: store,
        schoolId: school.id,
        scriptId: package.manifest.id,
        sdkVersion: package.manifest.sdkVersion,
        isActive: active,
      );
      Future<Object?> execute(
        ScriptBrowserCall? browser,
        ScriptInputCall? input,
      ) async => const TrustedScriptRuntime().run(
        package: package,
        capability: capability,
        params: params ?? const {},
        credentials: credentials,
        fetch: transport.fetch,
        browserCall: browser,
        inputCall: input,
        isActive: active,
        htmlStdlib: htmlStdlib ?? await loadHtmlStdlib(),
        wallTimeout: Duration(
          seconds:
              interactive &&
                  (package.manifest.browser || package.manifest.sdkVersion >= 3)
              ? 120
              : 35,
        ),
        // ADR-034 §6: use the existing bounded SDK maximum for interactive
        // authentication (captcha/MFA plus a redirect chain).
        maxRequests: actionScope != null
            ? 1
            : interactive && package.manifest.browser
            ? 40
            : 20,
        actionScope: actionScope,
        onLog: (level, message) {
          DevLog.instance.adapter(level, message);
          onLog?.call(level, message);
        },
      );
      Future<Object?> withBrowser(ScriptInputCall? input) async {
        // ADR-038 §3: background work cannot open a login page or native form.
        if (!interactive) {
          return execute(
            (_, _) async {
              throw const ScriptRunException('script_browser_unavailable');
            },
            (_) async {
              throw const ScriptRunException('input_unavailable');
            },
          );
        }
        if (package.manifest.browser && browserCall == null) {
          final presenter = state.presenter;
          if (presenter == null) {
            // ADR-034 §5: browser permission does not require a visible page for
            // HTTP-only calls. Report platform/UI absence only when invoked.
            return execute((_, _) async {
              throw const ScriptRunException('script_browser_unavailable');
            }, input);
          } else {
            return presenter(package, (call) => execute(call, input));
          }
        } else {
          return execute(browserCall, input);
        }
      }

      final inputPresenter = state.inputPresenter;
      final data =
          interactive &&
              package.manifest.sdkVersion >= 3 &&
              inputCall == null &&
              inputPresenter != null
          ? await inputPresenter(package, (call) => withBrowser(call))
          : await withBrowser(inputCall);
      if (!active()) {
        throw const ScriptRunException('script_cancelled');
      }
      if (capability == 'climate.devices' &&
          data is Map &&
          data['items'] is List) {
        state.climateDevices.clear();
        state.climateStates.clear();
        for (final device in data['items'] as List) {
          if (device is Map && device['deviceId'] is String) {
            state.climateDevices[device['deviceId'] as String] =
                Map<String, dynamic>.from(jsonDecode(jsonEncode(device)) as Map)
                  ..['_packageDigest'] = package.digest;
            state.climateDevices[device['deviceId'] as String]!['_verifiedAt'] =
                DateTime.now().millisecondsSinceEpoch;
          }
        }
      }
      if (capability == 'climate.status' &&
          data is Map &&
          data['deviceId'] == params?['deviceId']) {
        final deviceId = data['deviceId'] as String;
        if (state.climateDevices[deviceId]?['_packageDigest'] ==
            package.digest) {
          state.climateStates[deviceId] = Map<String, dynamic>.from(data);
          state.climateDevices[deviceId]!['_verifiedAt'] =
              DateTime.now().millisecondsSinceEpoch;
        }
      }
      if (ScriptDataCache(
        store,
      ).write(package, capability, params ?? const {}, data)) {
        state.homeRevision++;
      }
      result = CapabilityRun.ok(
        data,
        supportedCapabilities: {
          for (final cap in package.manifest.capabilities) cap.id,
        },
      );
    } catch (error) {
      if (capability == 'climate.status') {
        state.climateStates.remove(params?['deviceId']);
      }
      // Adapter-controlled exception messages may contain credentials.
      final code = switch (error) {
        ScriptRunException() => error.code,
        ScriptBrowserException() => error.code,
        _ => 'script_failed',
      };
      result = CapabilityRun.failed(CapabilityFailureKind.run, code);
    } finally {
      transport.close();
      state.transports.remove(transport);
    }
    // ADR-035 §3: authentication may already have rotated remotely even when
    // parsing/output fails. Persist completed writes without rolling them back.
    // Await the backend bound to this invocation, never a later replacement.
    try {
      await _flushCredentialBackend(backend);
    } catch (_) {
      result = const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'credential_persist_failed',
      );
    }
    if (result.ok && !active()) {
      result = const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'script_cancelled',
      );
    }
    if (result.ok &&
        active() &&
        capability == 'generic.section' &&
        registry.provider(school.id, 'climate.devices')?.digest ==
            package.digest) {
      // ADR-030 §5.1 / ADR-040 §5: login lifecycle sync, never a timer/preload.
      Future<void>(() async {
        if (!active()) return;
        final devices = await runTrustedScript(
          id,
          'climate.devices',
          interactive: false,
        );
        if (!active() ||
            !devices.ok ||
            registry.provider(school.id, 'climate.status')?.digest !=
                package.digest) {
          return;
        }
        for (final device in state.climateDevices.keys.toList()) {
          if (!active()) return;
          await runTrustedScript(
            id,
            'climate.status',
            params: {'deviceId': device},
            interactive: false,
          );
        }
      });
    }
    if (!state.disposed) onCredentialsChanged();
    DevLog.instance.runtime(
      'script end: $id $capability ${result.ok ? "ok" : result.reason}',
    );
    return result;
  }
}

class ClimateActionRequest {
  ClimateActionRequest._(
    this._owner,
    this._generation,
    this._package,
    this.deviceId,
    this.deviceLabel,
    this.command,
    this.settings,
  ) : _expiresAt = DateTime.now().add(const Duration(minutes: 1));
  final SessionController _owner;
  final int _generation;
  final ScriptPackage _package;
  final DateTime _expiresAt;
  bool _used = false;
  final String deviceId, deviceLabel, command;
  final Map<String, dynamic> settings;
  String get packageName => _package.manifest.name;
  String get maskedDevice => deviceId.length <= 4
      ? '••••'
      : '••••${deviceId.substring(deviceId.length - 4)}';
  Map<String, dynamic> get _params => Map.unmodifiable({
    'deviceId': deviceId,
    'command': command,
    'settings': settings,
  });
}

class ClimateActionResult {
  const ClimateActionResult(this.status, {this.observed});
  final String status;
  final CapabilityRun? observed;
}
