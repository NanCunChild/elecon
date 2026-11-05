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

typedef ScriptDeviceInputPresenter =
    Future<Object?> Function(
      ScriptPackage package,
      String kind,
      bool Function() isActive,
      ScriptSystemInputLease lease,
    );

typedef ScriptPasswordPresenter =
    Future<ScriptPasswordInput?> Function(
      ScriptPackage package,
      ScriptPasswordPrompt request,
      bool Function() isActive,
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
  ScriptPasswordPresenter? passwordPresenter;
  final accountEvents = <String, ScriptAccountEvent>{};
  final accountChanges = ValueNotifier<int>(0);
  ScriptScannerPresenter? scannerPresenter;
  ScriptDeviceInputPresenter? deviceInputPresenter;
  final deviceInputLease = ScriptSystemInputLease();
  Future<bool> Function()? storageConsent;
  int generation = 0;
  // Separate from execution generation: a login must invalidate business data
  // without cancelling its own browser/password presenter.
  int dataGeneration = 0;
  // ADR-090: approved source changes are distinct from lifecycle cancellation.
  int sourceRevision = 0;
  final pendingCacheRemovals = <String, Set<String>>{};
  String locale = 'zh';
  bool disposed = false;
  int homeRevision = 0;
  Future<void>? refreshingHome;
  final Set<ScriptHttpTransport> transports = {};
  final Set<ScriptWebSocketTransport> sockets = {};
  final Set<AppTunnelRoute> routes = {};
}

final _scriptStates = Expando<_ScriptSessionState>();

extension TrustedScriptSession on SessionController {
  _ScriptSessionState get _scripts =>
      _scriptStates[this] ??= _ScriptSessionState();

  int get trustedScriptViewGeneration => _scripts.generation;
  int get trustedScriptDataGeneration => _scripts.dataGeneration;
  int get trustedScriptSourceRevision => _scripts.sourceRevision;

  set scriptStorageConsent(Future<bool> Function()? consent) =>
      _scripts.storageConsent = consent;

  ScriptBrowserPresenter? get scriptBrowserPresenter => _scripts.presenter;

  void cancelTrustedScriptRuns() => _cancelTrustedScripts();

  set scriptBrowserPresenter(ScriptBrowserPresenter? presenter) =>
      _scripts.presenter = presenter;

  ScriptInputPresenter? get scriptInputPresenter => _scripts.inputPresenter;
  set scriptInputPresenter(ScriptInputPresenter? presenter) =>
      _scripts.inputPresenter = presenter;

  ScriptPasswordPresenter? get scriptPasswordPresenter =>
      _scripts.passwordPresenter;
  set scriptPasswordPresenter(ScriptPasswordPresenter? value) =>
      _scripts.passwordPresenter = value;
  Listenable get scriptAccountChanges => _scripts.accountChanges;
  ScriptAccountEvent? scriptAccountEvent(
    ScriptPackage package,
    String accountId,
  ) => _scripts.accountEvents['${package.digest}:$accountId'];
  ScriptAccountMetadata? savedScriptAccount(
    ScriptPackage package,
    String accountId,
  ) {
    if (_school?.id != package.manifest.schoolId) return null;
    final auth = package.manifest.accounts
        .where((a) => a.id == accountId)
        .firstOrNull
        ?.authentication;
    if (auth == null) return null;
    return ScriptAccountStore(
      _store,
    ).metadata(package.manifest.schoolId, auth.namespace);
  }

  Future<void> deleteSavedScriptAccount(
    ScriptPackage package,
    String accountId,
  ) async {
    final registry = await scriptRegistry;
    if (_school?.id != package.manifest.schoolId ||
        registry.find(package.manifest.id)?.package.digest != package.digest ||
        registry.find(package.manifest.id)?.enabled != true) {
      throw const ScriptAccountException('account_not_declared');
    }
    final auth = package.manifest.accounts
        .where((a) => a.id == accountId)
        .firstOrNull
        ?.authentication;
    if (auth == null) {
      throw const ScriptAccountException('account_not_declared');
    }
    _cancelTrustedScripts();
    final store = _store;
    final backend = _secure;
    final accounts = ScriptAccountStore(store);
    final generation = _scripts.generation;
    final epoch = registry.epoch;
    await accounts.commit(
      package.manifest.schoolId,
      auth.namespace,
      null,
      () => _flushCredentialBackend(backend),
      () =>
          !_scripts.disposed &&
          _scripts.generation == generation &&
          registry.epoch == epoch &&
          identical(store, _store) &&
          _school?.id == package.manifest.schoolId,
    );
    _scripts.accountChanges.value++;
  }

  ScriptScannerPresenter? get scriptScannerPresenter =>
      _scripts.scannerPresenter;
  set scriptScannerPresenter(ScriptScannerPresenter? presenter) =>
      _scripts.scannerPresenter = presenter;

  ScriptDeviceInputPresenter? get scriptDeviceInputPresenter =>
      _scripts.deviceInputPresenter;
  set scriptDeviceInputPresenter(ScriptDeviceInputPresenter? value) =>
      _scripts.deviceInputPresenter = value;
  bool get scriptSystemInputPending => _scripts.deviceInputLease.active;
  set scriptAppForeground(bool value) =>
      _scripts.deviceInputLease.foreground = value;

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
    _cancelHermesAuthentication();
    for (final bridge in _legacyAuthBridges.toList()) {
      bridge.stop().then<void>((_) {}, onError: (Object _) {});
    }
    _legacyAuthBridges.clear();
    final state = _scriptStates[this];
    if (state == null) return;
    state.deviceInputLease.revoke();
    state.generation++;
    state.homeRevision++;
    state.refreshingHome = null;
    state.accountEvents.clear();
    state.accountChanges.value++;
    if (dispose) {
      state.disposed = true;
      state.presenter = null;
      state.inputPresenter = null;
      state.passwordPresenter = null;
      state.scannerPresenter = null;
      state.deviceInputPresenter = null;
    }
    for (final transport in state.transports.toList()) {
      transport.close();
    }
    state.transports.clear();
    for (final socket in state.sockets.toList()) {
      socket.close();
    }
    state.sockets.clear();
    for (final route in state.routes.toList()) {
      route.close();
    }
    state.routes.clear();
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
          displayName: m.school?.name ?? m.name,
          subtitle: m.school?.type.name ?? m.id,
          institutionId: m.school?.id,
          typeId: m.school?.type.id,
          typeName: m.school?.type.name,
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
    final previous = registry.find(package.manifest.id)?.package;
    await registry.install(package, approvedDigest: approvedDigest);
    _scripts.sourceRevision++;
    final cleared =
        previous?.digest != package.digest &&
        MessageArchiveStore(
          _store,
        ).clearSource(package.manifest.schoolId, package.manifest.id);
    _scripts.recoveredRegistry = false;
    _cancelTrustedScripts();
    await _restoreScriptSchools();
    if (!_scripts.disposed) onCredentialsChanged();
    if (cleared) await _flushCredentialBackend(_secure);
  }

  Future<void> enableTrustedScript(String id, bool enabled) async {
    final registry = await scriptRegistry;
    await registry.setEnabled(id, enabled);
    _scripts.sourceRevision++;
    final package = registry.find(id)?.package;
    final cleared =
        package != null &&
        MessageArchiveStore(_store).clearSource(package.manifest.schoolId, id);
    _cancelTrustedScripts();
    await _restoreScriptSchools();
    _scheduleSessionPersist();
    if (!_scripts.disposed) onCredentialsChanged();
    if (cleared) await _flushCredentialBackend(_secure);
  }

  Future<void> removeTrustedScript(String id) async {
    final registry = await scriptRegistry;
    final package = registry.find(id)?.package;
    await registry.remove(id);
    _scripts.sourceRevision++;
    final cleared =
        package != null &&
        MessageArchiveStore(_store).clearSource(package.manifest.schoolId, id);
    _cancelTrustedScripts();
    await _restoreScriptSchools();
    _scheduleSessionPersist();
    if (!_scripts.disposed) onCredentialsChanged();
    if (cleared) await _flushCredentialBackend(_secure);
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

  /// ADR-076: only the selected, approved source can assess its accounts.
  /// Null means revoked while checking; a null entry means no status contract.
  Future<Map<String, String?>?> checkTrustedScriptAccounts(
    ScriptPackage package,
  ) async {
    final generation = _scripts.generation;
    final registry = await scriptRegistry;
    bool active() =>
        !_scripts.disposed &&
        _scripts.generation == generation &&
        _school?.id == package.manifest.schoolId &&
        registry.find(package.manifest.id)?.enabled == true &&
        registry.find(package.manifest.id)?.package.digest == package.digest;
    if (!active()) return null;
    final results = <String, String?>{};
    for (final account in package.manifest.accounts) {
      if (!active()) return null;
      if (account.statusCapability == null) {
        results[account.id] = null;
        continue;
      }
      // account.session/status disables every interactive authentication port.
      final run = await runTrustedScript(
        package.manifest.id,
        account.statusCapability!,
        expectedDigest: package.digest,
        params: account.statusParams,
      );
      if (!active()) return null;
      final status = run.ok && run.data is Map
          ? (run.data as Map)['status']
          : null;
      results[account.id] =
          const {
            'authenticated',
            'signedOut',
            'expired',
            'unknown',
          }.contains(status)
          ? status as String
          : 'unknown';
    }
    return results;
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

  // Explicit feature sources never fall back to the global override or another package.
  Future<ScriptPackage?> _querySource(
    String schoolId,
    String capability,
    String? packageId,
    String? expectedDigest,
  ) async {
    final registry = await scriptRegistry;
    if (packageId == null) {
      return expectedDigest == null
          ? registry.provider(schoolId, capability)
          : null;
    }
    final installation = registry.find(packageId);
    final package = installation?.package;
    if (installation?.enabled != true ||
        package == null ||
        package.requiresUpdate ||
        expectedDigest == null ||
        package.digest != expectedDigest ||
        package.manifest.schoolId != schoolId ||
        package.manifest.capability(capability) == null) {
      return null;
    }
    return package;
  }

  Future<ScriptCachedData?> cachedCapability(
    String capability, {
    Map<String, dynamic>? params,
    String? packageId,
    String? expectedDigest,
  }) async {
    final school = _school;
    final generation = _scripts.generation;
    final dataGeneration = _scripts.dataGeneration;
    if (school == null || _scripts.disposed) return null;
    try {
      final package = await _querySource(
        school.id,
        capability,
        packageId,
        expectedDigest,
      );
      if (package == null ||
          generation != _scripts.generation ||
          dataGeneration != _scripts.dataGeneration ||
          _school?.id != school.id) {
        return null;
      }
      return ScriptDataCache(
        _store,
        locale: scriptLocale,
      ).read(package, capability, params: params ?? const {});
    } on Object {
      return null;
    }
  }

  Future<ScriptCachedData?> latestCachedCapability(
    String capability, {
    String? packageId,
    String? expectedDigest,
  }) async {
    final school = _school;
    final generation = _scripts.generation;
    final dataGeneration = _scripts.dataGeneration;
    if (school == null || _scripts.disposed) return null;
    try {
      final package = await _querySource(
        school.id,
        capability,
        packageId,
        expectedDigest,
      );
      if (package == null ||
          generation != _scripts.generation ||
          dataGeneration != _scripts.dataGeneration ||
          _school?.id != school.id) {
        return null;
      }
      return ScriptDataCache(
        _store,
        locale: scriptLocale,
      ).latest(package, capability);
    } on Object {
      return null;
    }
  }

  /// ADR-059: only the current selected provider can supply setup state.
  Future<bool> capabilityNeedsConfiguration(
    String capability, {
    Map<String, dynamic>? params,
    String? packageId,
    String? expectedDigest,
  }) async {
    final school = _school;
    final generation = _scripts.generation;
    if (school == null || _scripts.disposed) return false;
    final package = await _querySource(
      school.id,
      capability,
      packageId,
      expectedDigest,
    );
    if (package == null ||
        generation != _scripts.generation ||
        _school?.id != school.id ||
        _scripts.disposed) {
      return false;
    }
    return ScriptReadinessStore(
      _store,
    ).needsConfiguration(package, capability, params ?? const {});
  }

  /// Await only a preload already in flight; inspecting its outcome never schedules work.
  Future<void> waitForHomeRefresh() =>
      _scripts.refreshingHome ?? Future.value();

  Future<void> refreshHomeData({bool force = false}) {
    final state = _scripts;
    if (state.refreshingHome != null) return state.refreshingHome!;
    final generation = state.generation;
    final dataGeneration = state.dataGeneration;
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
            final ownsCard = package.manifest.cards.any(
              (card) =>
                  card.hasExplicitId &&
                  card.requiredCapabilities.contains(query.capability),
            );
            if (!ownsCard &&
                registry.provider(school.id, query.capability)?.digest !=
                    package.digest) {
              continue;
            }
            if (state.disposed ||
                state.generation != generation ||
                state.dataGeneration != dataGeneration ||
                _school?.id != school.id) {
              return;
            }
            if (ScriptReadinessStore(
              _store,
            ).needsConfiguration(package, query.capability, query.params)) {
              continue;
            }
            final cached = ScriptDataCache(
              _store,
              locale: scriptLocale,
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
    String? expectedDigest,
    bool interactive = true,
    String? htmlStdlib,
    ScriptBrowserCall? browserCall,
    Future<void> Function()? appTunnelLogin,
    ScriptInputCall? inputCall,
    ScriptPasswordCall? passwordCall,
    ScriptRunCancellation? cancellation,
    void Function(String, String)? onLog,
  }) {
    final ScriptInvocation invocation;
    try {
      invocation = ScriptInvocation(
        packageId: id,
        capability: capability,
        params: params,
        expectedDigest: expectedDigest,
        interactive: interactive,
      );
    } catch (_) {
      return Future.value(
        const CapabilityRun.failed(
          CapabilityFailureKind.run,
          'input_invalid_request',
        ),
      );
    }
    return _queueTrustedScript(
      invocation,
      htmlStdlib: htmlStdlib,
      browserCall: browserCall,
      inputCall: inputCall,
      passwordCall: passwordCall,
      appTunnelLogin: appTunnelLogin,
      cancellation: cancellation,
      onLog: onLog,
    );
  }

  Future<CapabilityRun> _queueTrustedScript(
    ScriptInvocation invocation, {
    String? htmlStdlib,
    ScriptBrowserCall? browserCall,
    Future<void> Function()? appTunnelLogin,
    ScriptInputCall? inputCall,
    ScriptPasswordCall? passwordCall,
    ScriptRunCancellation? cancellation,
    void Function(String, String)? onLog,
  }) {
    final state = _scripts;
    final generation = state.generation;
    final dataGeneration = state.dataGeneration;
    final pending = state.queue.then<CapabilityRun>((_) {
      if (state.disposed ||
          state.generation != generation ||
          state.dataGeneration != dataGeneration ||
          cancellation?.isCancelled == true) {
        return const CapabilityRun.failed(
          CapabilityFailureKind.run,
          'script_cancelled',
        );
      }
      return _executeTrustedScript(
        invocation,
        expectedGeneration: generation,
        htmlStdlib: htmlStdlib,
        browserCall: browserCall,
        inputCall: inputCall,
        passwordCall: passwordCall,
        appTunnelLogin: appTunnelLogin,
        cancellation: cancellation,
        onLog: onLog,
      );
    });
    state.queue = pending.then<void>((_) {}, onError: (Object _) {});
    return pending;
  }

  Future<CapabilityRun> _executeTrustedScript(
    ScriptInvocation invocation, {
    required int expectedGeneration,
    String? htmlStdlib,
    ScriptBrowserCall? browserCall,
    Future<void> Function()? appTunnelLogin,
    ScriptInputCall? inputCall,
    ScriptPasswordCall? passwordCall,
    ScriptRunCancellation? cancellation,
    void Function(String, String)? onLog,
  }) async {
    final id = invocation.packageId;
    final capability = invocation.capability;
    final params = invocation.params;
    final expectedDigest = invocation.expectedDigest;
    final interactive = invocation.interactive;
    final state = _scripts;
    final statusOnly =
        capability == 'account.session' && params['operation'] == 'status';
    if (_changingNetwork) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'app_tunnel_busy',
      );
    }
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
        (expectedDigest != null &&
            installation.package.digest != expectedDigest) ||
        school == null ||
        installation.package.manifest.schoolId != school.id) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.load,
        'script_not_authorized',
      );
    }
    if (!interactive &&
        ScriptReadinessStore(
          _store,
        ).needsConfiguration(installation.package, capability, params)) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.configuration,
        'configuration_required',
      );
    }
    // A declared login can replace the principal without changing the school.
    // Invalidate assistant grants at initiation, not only after a successful
    // password response. Query-only ticket renewal does not enter this branch.
    final identityLogin =
        interactive &&
        installation.package.manifest.accounts.any(
          (account) => ScriptAccountBridge.isLoginInvocation(
            account,
            capability,
            params,
          ),
        );
    if (identityLogin) {
      _invalidateIdentity();
    }
    final admissionEpoch = registry.epoch;
    try {
      if (interactive && !statusOnly) {
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
    if (identityLogin) {
      // ADR-038: no old-school-principal snapshots may survive a new login.
      // Persist removal before allowing school code to replace credentials.
      // Failure/cancellation cannot restore those snapshots: authentication
      // may already have changed remotely even if the final result is unknown.
      state.dataGeneration++;
      state.homeRevision++;
      state.refreshingHome = null;
      final removals = state.pendingCacheRemovals.putIfAbsent(
        school.id,
        () => <String>{},
      );
      // SecureStore deletes update memory before their async flush. Retry the
      // removals after a storage failure without restoring old account data.
      for (final ref in removals) {
        store.delete(ref);
      }
      removals.addAll(ScriptDataCache(store).clearSchool(school.id));
      removals.addAll(ScriptQueryFormCache(store).clearSchool(school.id));
      removals.addAll(
        ScheduleWidgetIdentityStore(store).clearSchool(school.id),
      );
      onCredentialsChanged();
      try {
        await _flushCredentialBackend(backend);
        state.pendingCacheRemovals.remove(school.id);
      } catch (_) {
        return const CapabilityRun.failed(
          CapabilityFailureKind.run,
          'credential_persist_failed',
        );
      }
    }
    final dataGeneration = state.dataGeneration;
    var foregroundRevoked = false;
    bool active() {
      // A picker lease only suspends lifecycle cancellation while native input
      // is pending. Null/error/timeout must never resume script work offscreen.
      if (interactive && !state.deviceInputLease.executionAllowed) {
        foregroundRevoked = true;
      }
      return !foregroundRevoked &&
          !state.disposed &&
          cancellation?.isCancelled != true &&
          state.generation == generation &&
          state.dataGeneration == dataGeneration &&
          registry.epoch == epoch &&
          identical(store, _store) &&
          _school?.id == school.id &&
          registry.find(id)?.enabled == true &&
          registry.find(id)?.package.digest == package.digest;
    }

    final AppTunnelRoute? route;
    try {
      final account = capability == 'account.session'
          ? package.manifest.accounts
                .where((a) => a.id == params['account'])
                .firstOrNull
          : null;
      final dependency =
          account?.appTunnelAccountId ??
          package.manifest.capability(capability)?.appTunnelAccountId;
      if (dependency != null) {
        final declaration = package.manifest.accounts
            .firstWhere((a) => a.id == dependency)
            .appTunnel!;
        route = _declaredTunnelRoute(declaration);
      } else {
        route = package.manifest.sdkVersion >= 16
            ? null
            : await _networkRoutes.route(school.id);
      }
    } on AppTunnelException catch (error) {
      return CapabilityRun.failed(
        error.code == 'app_tunnel_required'
            ? CapabilityFailureKind.auth
            : CapabilityFailureKind.run,
        error.code,
      );
    }
    if (!active() || _changingNetwork) {
      route?.close();
      return const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'script_cancelled',
      );
    }
    if (route != null) state.routes.add(route);
    final transport = ScriptHttpTransport(
      policy: package.manifest.network,
      appTunnel: route,
    );
    state.transports.add(transport);
    final socket = ScriptWebSocketTransport(
      policy: package.manifest.websocketNetwork,
      appTunnel: route,
    );
    state.sockets.add(socket);
    void closeTransports() {
      transport.close();
      socket.close();
      route?.close();
    }

    cancellation?.addListener(closeTransports);
    DevLog.instance.runtime('script start: $id $capability');
    CapabilityRun result;
    List<CredentialEntry>? previousCachedData;
    ScriptAccountBridge? accountBridge;
    try {
      if (MessageArchiveStore.capabilities.contains(capability) &&
          (params['accountId'] == null ||
              MessageArchiveStore(store).account(package)?['accountId'] !=
                  params['accountId'])) {
        throw const ScriptRunException('input_invalid_request');
      }
      // Explicit account transitions revoke old archives before any network or
      // browser work, even when login/logout is later cancelled.
      if (capability == 'messages.session' &&
          const ['login', 'logout'].contains(params['operation'])) {
        MessageArchiveStore(store).clearSource(school.id, id);
        await _flushCredentialBackend(backend);
        if (!active()) throw const ScriptRunException('script_cancelled');
      }
      final credentials = ScriptCredentials(
        store: store,
        schoolId: school.id,
        scriptId: package.manifest.id,
        sdkVersion: package.manifest.sdkVersion,
        isActive: active,
      );
      final accounts = accountBridge = ScriptAccountBridge(
        package: package,
        capability: capability,
        params: params,
        store: ScriptAccountStore(store),
        persist: () => _flushCredentialBackend(backend),
        isActive: active,
        interactive: interactive && !statusOnly,
        passwordCall: interactive && !statusOnly
            ? passwordCall ??
                  (state.passwordPresenter == null
                      ? null
                      : (request) =>
                            state.passwordPresenter!(package, request, active))
            : null,
        onEvent: (event) {
          if (!active()) return;
          state.accountEvents['${package.digest}:${event.accountId}'] = event;
          state.accountChanges.value++;
        },
      );
      Future<Object?> execute(
        ScriptBrowserCall? browser,
        ScriptInputCall? input,
      ) async => const TrustedScriptRuntime().run(
        package: package,
        capability: capability,
        params: params,
        locale: state.locale,
        credentials: credentials,
        accountCall: accounts.call,
        fetch: transport.fetch,
        websocketCall: interactive ? socket.call : null,
        browserCall: route == null
            ? browser
            : (_, _) async {
                throw const ScriptRunException(
                  'app_tunnel_browser_unavailable',
                );
              },
        inputCall: input,
        appTunnelReuseCall: interactive && !statusOnly
            ? (accountId) => loginHermesWithScriptAccount(
                package: package,
                accountId: accountId,
                capability: capability,
                params: params,
                isActive: active,
                cancellation: cancellation,
                passwordCall:
                    passwordCall ??
                    (state.passwordPresenter == null
                        ? null
                        : (request) => state.passwordPresenter!(
                            package,
                            request,
                            active,
                          )),
                webLogin: appTunnelLogin,
              )
            : null,
        appTunnelCall: interactive
            ? (method, provider) async {
                if (!active()) {
                  throw const ScriptRunException('invocation_cancelled');
                }
                if (method == 'login') {
                  if (statusOnly || appTunnelLogin == null) {
                    throw const ScriptRunException('input_unavailable');
                  }
                  await appTunnelLogin();
                  if (!active()) {
                    throw const ScriptRunException('invocation_cancelled');
                  }
                }
                final target = capability == 'account.session'
                    ? package.manifest.accounts
                          .where((a) => a.id == params['account'])
                          .firstOrNull
                    : null;
                final reuse = target?.credentialReuse;
                final tunnel = target?.appTunnel;
                return checkHermesAccount(
                  isActive: active,
                  cancellation: cancellation,
                  expectedGatewayUrl: tunnel?.gatewayUrl ?? reuse?.gatewayUrl,
                  expectedLoginDomain:
                      tunnel?.loginDomain ?? reuse?.loginDomain,
                  expectedCertificateSha256: tunnel?.nodeCertificateSha256,
                  checkCertificate: tunnel != null,
                );
              }
            : null,
        deviceInputCall: interactive && state.deviceInputPresenter != null
            ? (kind, valid) => state.deviceInputPresenter!(
                package,
                kind,
                valid,
                state.deviceInputLease,
              )
            : null,
        scanCall: interactive && state.scannerPresenter != null
            ? (valid) => state.scannerPresenter!(package, valid)
            : null,
        isActive: active,
        htmlStdlib: htmlStdlib ?? await loadHtmlStdlib(),
        wallTimeout: Duration(
          seconds:
              interactive &&
                  !statusOnly &&
                  (package.manifest.browser || package.manifest.sdkVersion >= 3)
              ? 120
              : 35,
        ),
        // ADR-034 §6: use the existing bounded SDK maximum for interactive
        // authentication (captcha/MFA plus a redirect chain).
        maxRequests: interactive && package.manifest.browser ? 40 : 20,
        onLog: (level, message) {
          if (message.startsWith('probe/1')) {
            DevLog.instance.log(DevLogCategory.probe, message);
          } else {
            DevLog.instance.adapter(level, message);
          }
          onLog?.call(level, message);
        },
      );
      Future<Object?> withBrowser(ScriptInputCall? input) async {
        // ADR-038 §3: background work cannot open a login page or native form.
        if (!interactive || statusOnly) {
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
              !statusOnly &&
              package.manifest.sdkVersion >= 3 &&
              inputCall == null &&
              inputPresenter != null
          ? await inputPresenter(package, (call) => withBrowser(call))
          : await withBrowser(inputCall);
      if (!active()) {
        throw const ScriptRunException('script_cancelled');
      }
      var archiveFailed = false;
      final archive = MessageArchiveStore(store);
      if (capability == 'messages.session') {
        archive.saveAccount(package, Map<String, dynamic>.from(data as Map));
      } else if (MessageArchiveStore.capabilities.contains(capability)) {
        final value = Map<String, dynamic>.from(data as Map);
        if (!archive.accepts(package, capability, params, value)) {
          throw const ScriptRunException('source_response_invalid');
        }
        try {
          await archive.merge(
            package,
            capability,
            params,
            value,
            isActive: active,
          );
        } catch (_) {
          archiveFailed = true;
        }
        if (!active()) throw const ScriptRunException('script_cancelled');
      }
      final cachedBeforeWrite = store
          .list()
          .where(
            (entry) =>
                entry.type == ScriptDataCache.type &&
                entry.schoolId == school.id,
          )
          .toList();
      if (ScriptDataCache(
        store,
        locale: state.locale,
      ).write(package, capability, params, data)) {
        previousCachedData = cachedBeforeWrite;
        state.homeRevision++;
      }
      result = CapabilityRun.ok(
        data,
        localStorageFailed: archiveFailed,
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
      if (code == 'authentication_required' &&
          active() &&
          package.manifest.capability('messages.session') != null) {
        MessageArchiveStore(store).clearSource(school.id, id);
      }
      result = CapabilityRun.failed(
        code == 'configuration_required'
            ? CapabilityFailureKind.configuration
            : CapabilityFailureKind.run,
        code,
        businessCode: error is ScriptRunException ? error.businessCode : null,
      );
    } finally {
      accountBridge?.close();
      cancellation?.removeListener(closeTransports);
      transport.close();
      state.transports.remove(transport);
      socket.close();
      state.sockets.remove(socket);
      route?.close();
      if (route != null) state.routes.remove(route);
    }
    List<CredentialEntry> clearedReadiness = const [];
    if (active()) {
      final readiness = ScriptReadinessStore(store);
      if (result.ok && interactive) {
        clearedReadiness = readiness.entries(package, capability);
      }
      final changed = result.failureKind == CapabilityFailureKind.configuration
          ? readiness.mark(package, capability, params)
          : result.ok && interactive
          ? readiness.clear(package, capability)
          : false;
      if (changed) state.homeRevision++;
    }
    // ADR-035 §3: authentication may already have rotated remotely even when
    // parsing/output fails. Persist completed writes without rolling them back.
    // Await the backend bound to this invocation, never a later replacement.
    try {
      await _flushCredentialBackend(backend);
    } catch (_) {
      // Setup is not complete until its writes are durable. Restore display
      // cache and prerequisite markers, never roll back school credentials.
      if (active() &&
          (clearedReadiness.isNotEmpty || previousCachedData != null)) {
        for (final entry in clearedReadiness) {
          store.put(entry);
        }
        if (previousCachedData != null) {
          for (final entry
              in store
                  .list()
                  .where(
                    (entry) =>
                        entry.type == ScriptDataCache.type &&
                        entry.schoolId == school.id,
                  )
                  .toList()) {
            store.delete(entry.ref);
          }
          for (final entry in previousCachedData) {
            store.put(entry);
          }
          state.homeRevision++;
        }
        try {
          await _flushCredentialBackend(backend);
        } catch (_) {}
      }
      result =
          result.ok && MessageArchiveStore.capabilities.contains(capability)
          ? CapabilityRun.ok(
              result.data,
              supportedCapabilities: result.supportedCapabilities,
              localStorageFailed: true,
            )
          : const CapabilityRun.failed(
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
