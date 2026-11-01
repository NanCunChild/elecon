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

typedef ScriptScannerPresenter =
    Future<Object?> Function(ScriptPackage package, bool Function() isActive);

/// ADR-053: one page may revoke its own work without revoking school identity.
class ScriptRunCancellation extends ChangeNotifier {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    notifyListeners();
  }
}

class _ScriptSessionState {
  Future<ScriptRegistry>? registry;
  Future<void> queue = Future.value();
  bool recoveredRegistry = false;
  ScriptBrowserPresenter? presenter;
  ScriptInputPresenter? inputPresenter;
  ScriptScannerPresenter? scannerPresenter;
  Future<bool> Function()? storageConsent;
  int generation = 0;
  bool disposed = false;
  int homeRevision = 0;
  Future<void>? refreshingHome;
  final Set<ScriptHttpTransport> transports = {};
  final Set<ScriptWebSocketTransport> sockets = {};
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

  ScriptInputPresenter? get scriptInputPresenter => _scripts.inputPresenter;
  set scriptInputPresenter(ScriptInputPresenter? presenter) =>
      _scripts.inputPresenter = presenter;

  ScriptScannerPresenter? get scriptScannerPresenter =>
      _scripts.scannerPresenter;
  set scriptScannerPresenter(ScriptScannerPresenter? presenter) =>
      _scripts.scannerPresenter = presenter;

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
    state.homeRevision++;
    state.refreshingHome = null;
    if (dispose) {
      state.disposed = true;
      state.presenter = null;
      state.inputPresenter = null;
      state.scannerPresenter = null;
    }
    for (final transport in state.transports.toList()) {
      transport.close();
    }
    state.transports.clear();
    for (final socket in state.sockets.toList()) {
      socket.close();
    }
    state.sockets.clear();
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
    ScriptRunCancellation? cancellation,
    void Function(String, String)? onLog,
  }) => _queueTrustedScript(
    id,
    capability,
    params: params,
    interactive: interactive,
    htmlStdlib: htmlStdlib,
    browserCall: browserCall,
    inputCall: inputCall,
    cancellation: cancellation,
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
    ScriptRunCancellation? cancellation,
    void Function(String, String)? onLog,
  }) {
    final state = _scripts;
    final generation = state.generation;
    final pending = state.queue.then<CapabilityRun>((_) {
      if (state.disposed ||
          state.generation != generation ||
          cancellation?.isCancelled == true) {
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
        cancellation: cancellation,
        onLog: onLog,
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
    ScriptRunCancellation? cancellation,
    void Function(String, String)? onLog,
  }) async {
    final state = _scripts;
    if (!interactive && foregroundCommunityCapabilities.contains(capability)) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'foreground_required',
      );
    }
    final ScriptRegistry registry;
    try {
      registry = await scriptRegistry;
    } catch (_) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.load,
        'script_registry_unavailable',
      );
    }
    if (state.disposed ||
        state.generation != expectedGeneration ||
        cancellation?.isCancelled == true) {
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
        cancellation?.isCancelled == true ||
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
        cancellation?.isCancelled != true &&
        state.generation == generation &&
        registry.epoch == epoch &&
        identical(store, _store) &&
        _school?.id == school.id &&
        registry.find(id)?.enabled == true &&
        registry.find(id)?.package.digest == package.digest;
    final transport = ScriptHttpTransport(policy: package.manifest.network);
    state.transports.add(transport);
    final socket = ScriptWebSocketTransport(
      policy: package.manifest.websocketNetwork,
    );
    state.sockets.add(socket);
    void closeTransports() {
      transport.close();
      socket.close();
    }

    cancellation?.addListener(closeTransports);
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
        websocketCall: interactive ? socket.call : null,
        browserCall: browser,
        inputCall: input,
        scanCall: interactive && state.scannerPresenter != null
            ? (valid) => state.scannerPresenter!(package, valid)
            : null,
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
        maxRequests: interactive && package.manifest.browser ? 40 : 20,
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
      // Adapter-controlled exception messages may contain credentials.
      final code = switch (error) {
        ScriptRunException() => error.code,
        ScriptBrowserException() => error.code,
        _ => 'script_failed',
      };
      result = CapabilityRun.failed(CapabilityFailureKind.run, code);
    } finally {
      cancellation?.removeListener(closeTransports);
      transport.close();
      state.transports.remove(transport);
      socket.close();
      state.sockets.remove(socket);
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
    if (!state.disposed) onCredentialsChanged();
    DevLog.instance.runtime(
      'script end: $id $capability ${result.ok ? "ok" : result.reason}',
    );
    return result;
  }
}
