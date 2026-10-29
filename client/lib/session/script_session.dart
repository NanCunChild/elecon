/// 🔒 ADR-034: selected-school script execution; UI never obtains CredentialStore.
part of 'session_controller.dart';

typedef ScriptBrowserCall =
    Future<Object?> Function(String method, Map<String, Object?> arguments);
typedef ScriptBrowserPresenter =
    Future<Object?> Function(
      ScriptPackage package,
      Future<Object?> Function(ScriptBrowserCall call) execute,
    );

class _ScriptSessionState {
  Future<ScriptRegistry>? registry;
  Future<void> queue = Future.value();
  bool recoveredRegistry = false;
  ScriptBrowserPresenter? presenter;
  Future<bool> Function()? storageConsent;
  int generation = 0;
  bool disposed = false;
  final Set<ScriptHttpTransport> transports = {};
}

final _scriptStates = Expando<_ScriptSessionState>();

extension TrustedScriptSession on SessionController {
  _ScriptSessionState get _scripts =>
      _scriptStates[this] ??= _ScriptSessionState();

  int get trustedScriptViewGeneration => _scripts.generation;
  set scriptStorageConsent(Future<bool> Function()? consent) =>
      _scripts.storageConsent = consent;

  ScriptBrowserPresenter? get scriptBrowserPresenter => _scripts.presenter;

  void cancelTrustedScriptRuns() => _cancelTrustedScripts();

  set scriptBrowserPresenter(ScriptBrowserPresenter? presenter) =>
      _scripts.presenter = presenter;

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
    if (dispose) {
      state.disposed = true;
      state.presenter = null;
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
    for (final installation in registry.installations) {
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
    return {
      for (final installation in (await scriptRegistry).installations)
        if (installation.enabled &&
            installation.package.manifest.schoolId == school.id)
          for (final cap in installation.package.manifest.capabilities) cap.id,
    };
  }

  Future<CapabilityRun> runTrustedScript(
    String id,
    String capability, {
    Map<String, dynamic>? params,
    String? htmlStdlib,
    ScriptBrowserCall? browserCall,
    void Function(String, String)? onLog,
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
        params: params,
        htmlStdlib: htmlStdlib,
        browserCall: browserCall,
        onLog: onLog,
      );
    });
    state.queue = pending.then<void>((_) {}, onError: (Object _) {});
    return pending;
  }

  Future<CapabilityRun> _executeTrustedScript(
    String id,
    String capability, {
    Map<String, dynamic>? params,
    String? htmlStdlib,
    ScriptBrowserCall? browserCall,
    void Function(String, String)? onLog,
  }) async {
    final state = _scripts;
    final registry = await scriptRegistry;
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
    final admissionGeneration = state.generation;
    await ensurePersistentStore(
      confirmSoftwareFallback: state.storageConsent ?? () async => false,
    );
    if (state.disposed ||
        state.generation != admissionGeneration ||
        _school?.id != school.id) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'script_cancelled',
      );
    }
    final package = installation.package;
    final generation = state.generation;
    final epoch = registry.epoch;
    final store = _store;
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
    try {
      final credentials = ScriptCredentials(
        store: store,
        schoolId: school.id,
        isActive: active,
      );
      Future<Object?> execute(ScriptBrowserCall? browser) async =>
          const TrustedScriptRuntime().run(
            package: package,
            capability: capability,
            params: params ?? const {},
            credentials: credentials,
            fetch: transport.fetch,
            browserCall: browser,
            isActive: active,
            htmlStdlib: htmlStdlib ?? await loadHtmlStdlib(),
            wallTimeout: Duration(seconds: package.manifest.browser ? 120 : 35),
            onLog: onLog,
          );
      final Object? data;
      if (package.manifest.browser && browserCall == null) {
        final presenter = state.presenter;
        if (presenter == null) {
          return const CapabilityRun.failed(
            CapabilityFailureKind.run,
            'script_browser_unavailable',
          );
        }
        data = await presenter(package, (call) => execute(call));
      } else {
        data = await execute(browserCall);
      }
      if (!active()) {
        return const CapabilityRun.failed(
          CapabilityFailureKind.run,
          'script_cancelled',
        );
      }
      await flush();
      if (!active()) {
        return const CapabilityRun.failed(
          CapabilityFailureKind.run,
          'script_cancelled',
        );
      }
      return CapabilityRun.ok(
        data,
        supportedCapabilities: {
          for (final cap in package.manifest.capabilities) cap.id,
        },
      );
    } catch (error) {
      // Adapter-controlled exception messages may contain credentials.
      final code = switch (error) {
        ScriptRunException() => error.code,
        ScriptBrowserException() => error.code,
        _ => 'script_failed',
      };
      return CapabilityRun.failed(CapabilityFailureKind.run, code);
    } finally {
      transport.close();
      state.transports.remove(transport);
      if (!state.disposed) onCredentialsChanged();
    }
  }
}
