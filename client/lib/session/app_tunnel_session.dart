/// ADR-062: UI receives configuration metadata and a value-free login bridge.
part of 'session_controller.dart';

class _HermesSessionState {
  HermesNativeRequest? request;
  int authenticationGeneration = 0;
  bool writing = false;
}

final _hermesStates = Expando<_HermesSessionState>();

extension HermesTunnelSession on SessionController {
  _HermesSessionState get _hermes =>
      _hermesStates[this] ??= _HermesSessionState();

  bool hasDeclaredTunnelConfiguration(ScriptAppTunnel declaration) {
    if (hardwareUnlockFailed) return false;
    final school = _school;
    if (school == null || _hermes.writing) return false;
    try {
      return HermesConfigStore(_store)
              .load(school.id)
              ?.matchesAccountScope(
                gatewayUrl: declaration.gatewayUrl,
                loginDomain: declaration.loginDomain,
                certificateSha256: declaration.nodeCertificateSha256,
                checkCertificate: true,
              ) ==
          true;
    } catch (_) {
      return false;
    }
  }

  AppTunnelRoute _declaredTunnelRoute(ScriptAppTunnel declaration) {
    final school = _school;
    if (school == null || !hasDeclaredTunnelConfiguration(declaration)) {
      throw const AppTunnelException('app_tunnel_required');
    }
    final config = HermesConfigStore(_store).load(school.id)!;
    final provider =
        _injectedAppTunnelProviders
            ?.where((p) => p.id == declaration.service)
            .firstOrNull ??
        HermesProvider(
          binding: _hermesBinding,
          configuration: (_) async => config,
        );
    return AppTunnelRoute(provider, school.id);
  }

  void _cancelHermesAuthentication() {
    final state = _hermesStates[this];
    if (state == null) return;
    state.authenticationGeneration++;
    state.request?.cancel();
  }

  HermesAccountInfo? hermesAccountInfo() {
    if (hardwareUnlockFailed) return null;
    if (_hermes.writing) throw const AppTunnelException('app_tunnel_busy');
    final schoolId = _school?.id;
    return schoolId == null
        ? null
        : HermesAccountStore(_store).load(schoolId)?.info;
  }

  /// Update the bounded host-owned records together; publish only after flush.
  Future<void> _persistHermesChange({
    required String schoolId,
    required bool Function() active,
    required void Function() change,
  }) async {
    if (_hermes.writing) throw const AppTunnelException('app_tunnel_busy');
    if (!active()) throw const AppTunnelException('hermes_cancelled');
    _hermes.writing = true;
    final store = _store;
    final backend = _secure;
    Map<String, CredentialEntry> snapshot() => {
      for (final e in store.list())
        if (e.schoolId == schoolId &&
            {HermesConfigStore.type, HermesAccountStore.type}.contains(e.type))
          e.ref: e,
    };
    final previous = snapshot();
    Map<String, CredentialEntry>? written;
    try {
      change();
      written = snapshot();
      await _flushCredentialBackend(backend);
      if (!active()) throw const AppTunnelException('hermes_cancelled');
    } catch (error) {
      final current = snapshot();
      final changed = written ?? current;
      for (final ref in {...previous.keys, ...changed.keys}) {
        if (identical(current[ref], changed[ref]) &&
            !identical(previous[ref], changed[ref])) {
          final old = previous[ref];
          if (old != null && (active() || changed[ref] != null)) {
            store.put(old);
          } else {
            store.delete(ref);
          }
        }
      }
      try {
        await _flushCredentialBackend(backend);
      } catch (_) {
        /* Fixed error below. */
      }
      if (error is AppTunnelException) rethrow;
      throw const AppTunnelException('hermes_persist_failed');
    } finally {
      _hermes.writing = false;
    }
  }

  Future<void> saveHermesAccount({
    required String gatewayUrl,
    required String username,
    required String password,
    String loginDomain = '',
    String? nodeCertificateSha256,
  }) async {
    final school = _school;
    final generation = _scripts.generation;
    if (school == null) throw const AppTunnelException('app_tunnel_no_school');
    await ensurePersistentStore(
      confirmSoftwareFallback: _scripts.storageConsent ?? () async => false,
    );
    final store = _store;
    bool active() =>
        !_scripts.disposed &&
        _school?.id == school.id &&
        _scripts.generation == generation &&
        identical(store, _store);
    if (!active()) throw const AppTunnelException('hermes_cancelled');
    final archive = HermesAccountStore(store);
    HermesAccount? previous;
    try {
      previous = archive.load(school.id);
    } on AppTunnelException {
      // Explicit replacement with a new password may repair corrupt material.
    }
    final account = HermesAccount.edit(
      gatewayUrl: gatewayUrl,
      username: username,
      password: password,
      loginDomain: loginDomain,
      nodeCertificateSha256: nodeCertificateSha256,
      previous: previous,
    );
    await _persistHermesChange(
      schoolId: school.id,
      active: active,
      change: () {
        archive.save(school.id, account);
        HermesConfigStore(store).clear(school.id);
      },
    );
    _cancelTrustedScripts();
    onCredentialsChanged();
  }

  Future<void> loginHermesAccount() async {
    _requireProtectedStoreAccess();
    final school = _school;
    final generation = _scripts.generation;
    final store = _store;
    final authenticationGeneration = _hermes.authenticationGeneration;
    if (school == null) throw const AppTunnelException('app_tunnel_no_school');
    if (_hermes.request != null || _hermes.writing) {
      throw const AppTunnelException('app_tunnel_busy');
    }
    bool active() =>
        !_scripts.disposed &&
        _school?.id == school.id &&
        _scripts.generation == generation &&
        identical(store, _store) &&
        _hermes.authenticationGeneration == authenticationGeneration;
    final account = HermesAccountStore(store).load(school.id);
    if (account == null) {
      throw const AppTunnelException('hermes_authentication_required');
    }
    if (!active()) throw const AppTunnelException('hermes_cancelled');
    final request = _hermesBinding.request(account.nativeAuthenticate());
    _hermes.request = request;
    try {
      final response = await request.result;
      if (!active()) throw const AppTunnelException('hermes_cancelled');
      final session = response['session'];
      if (session is! Map) {
        throw const AppTunnelException('hermes_authentication_required');
      }
      final configuration = HermesConfiguration(
        gatewayUrl: account.gateway.origin,
        session: Map<String, dynamic>.from(session),
        nodeCertificateSha256: account.nodeCertificateSha256,
      );
      await _persistHermesChange(
        schoolId: school.id,
        active: active,
        change: () => HermesConfigStore(store).save(school.id, configuration),
      );
      _hermes.request = null;
      _cancelTrustedScripts();
      onCredentialsChanged();
    } finally {
      if (identical(_hermes.request, request)) _hermes.request = null;
    }
  }

  /// SDK15: a declared foreground target login reuses a protected source once.
  Future<Map<String, Object?>> loginHermesWithScriptAccount({
    required ScriptPackage package,
    required String accountId,
    required String capability,
    required Map<String, dynamic> params,
    required bool Function() isActive,
    ScriptRunCancellation? cancellation,
    ScriptPasswordCall? passwordCall,
    Future<void> Function()? webLogin,
  }) async {
    _requireProtectedStoreAccess();
    final generation = _scripts.generation;
    final store = _store;
    final school = _school;
    final authGeneration = _hermes.authenticationGeneration;
    final registry = await scriptRegistry;
    final epoch = registry.epoch;
    final target = package.manifest.accounts
        .where((a) => a.id == accountId)
        .firstOrNull;
    final reuse = target?.credentialReuse;
    final tunnel = target?.appTunnel;
    if (package.manifest.sdkVersion < 15 ||
        target == null ||
        (reuse == null && tunnel == null) ||
        !ScriptAccountBridge.isLoginInvocation(target, capability, params) ||
        !_scripts.deviceInputLease.foreground ||
        school?.id != package.manifest.schoolId ||
        registry.find(package.manifest.id)?.enabled != true ||
        registry.find(package.manifest.id)?.package.digest != package.digest) {
      throw const ScriptRunException('input_unavailable');
    }
    final source = reuse == null
        ? null
        : package.manifest.accounts.firstWhere(
            (a) => a.id == reuse.sourceAccountId,
          );
    final archive = ScriptAccountStore(store);
    final namespace = source?.authentication!.namespace;
    final revision = namespace == null
        ? null
        : archive.entry(school!.id, namespace);
    final schoolId = school!.id;
    bool active() =>
        !_scripts.disposed &&
        _scripts.deviceInputLease.foreground &&
        generation == _scripts.generation &&
        identical(store, _store) &&
        _school?.id == schoolId &&
        registry.epoch == epoch &&
        authGeneration == _hermes.authenticationGeneration &&
        (namespace == null ||
            identical(archive.entry(schoolId, namespace), revision)) &&
        cancellation?.isCancelled != true &&
        isActive();
    if (!active()) throw const ScriptRunException('invocation_cancelled');
    if (_hermes.request != null || _hermes.writing) {
      throw const ScriptRunException('app_tunnel_unavailable');
    }
    final gatewayUrl = tunnel?.gatewayUrl ?? reuse!.gatewayUrl;
    final domain = tunnel?.loginDomain ?? reuse!.loginDomain;
    HermesAccount account;
    bool? remember;
    if (reuse != null) {
      final saved = archive.read(schoolId, namespace!);
      if (saved == null) {
        throw const ScriptRunException('authentication_required');
      }
      account = HermesAccount(
        gatewayUrl: gatewayUrl,
        username: saved['username'] as String,
        password: saved['password'] as String,
        loginDomain: domain,
        nodeCertificateSha256: tunnel?.nodeCertificateSha256,
      );
    } else {
      if (tunnel!.loginMode == 'web') {
        if (webLogin == null) {
          throw const ScriptRunException('input_unavailable');
        }
        await webLogin();
        return {
          'status': 'unknown',
        }; // UI rechecks after the browser identity transition.
      }
      if (passwordCall == null) {
        throw const ScriptRunException('input_unavailable');
      }
      final saved = HermesAccountStore(store).load(schoolId);
      final matching =
          saved != null &&
              saved.gateway.origin == gatewayUrl &&
              saved.loginDomain == domain &&
              saved.nodeCertificateSha256 == tunnel.nodeCertificateSha256
          ? saved
          : null;
      final input = await passwordCall(
        ScriptPasswordPrompt(
          accountName: target.name,
          username: matching?.username ?? '',
          hasSavedPassword: matching != null,
          blocked: false,
          allowWeb: domain.isEmpty,
          isActive: active,
          instructions: target.instructions,
          tunnel: tunnel,
        ),
      );
      if (!active()) throw const ScriptRunException('invocation_cancelled');
      if (input == null) throw const ScriptRunException('input_cancelled');
      if (input.useWeb) {
        if (domain.isNotEmpty || webLogin == null) {
          throw const ScriptRunException('input_unavailable');
        }
        await webLogin();
        return {'status': 'unknown'};
      }
      if (input.useSaved) {
        if (matching == null) {
          throw const ScriptRunException('authentication_required');
        }
        account = matching;
      } else {
        account = HermesAccount(
          gatewayUrl: gatewayUrl,
          username: input.username,
          password: input.password,
          loginDomain: domain,
          nodeCertificateSha256: tunnel.nodeCertificateSha256,
        );
      }
      remember = input.useSaved || input.remember;
    }
    HermesNativeRequest? request;
    void cancel() => request?.cancel();
    cancellation?.addListener(cancel);
    try {
      request = _hermesBinding.request(account.nativeAuthenticate());
      _hermes.request = request;
      final response = await request.result;
      if (!active()) throw const ScriptRunException('invocation_cancelled');
      final raw = response['session'];
      if (raw is! Map) return {'status': 'unknown'};
      var config = HermesConfiguration(
        gatewayUrl: gatewayUrl,
        session: Map<String, dynamic>.from(raw),
        nodeCertificateSha256: tunnel?.nodeCertificateSha256,
      );
      if (!config.matchesAccountScope(
        gatewayUrl: gatewayUrl,
        loginDomain: domain,
      )) {
        return {'status': 'unknown'};
      }
      request = _hermesBinding.request(config.nativeCheck());
      _hermes.request = request;
      final state = await request.result;
      if (!active()) throw const ScriptRunException('invocation_cancelled');
      if (state['status'] != 'authenticated') {
        return {'status': state['status'] == 'expired' ? 'expired' : 'unknown'};
      }
      if (state.containsKey('session')) {
        if (state['session'] is! Map) return {'status': 'unknown'};
        config = config.withRotatedSession(
          Map<String, dynamic>.from(state['session'] as Map),
        );
      }
      await _persistHermesChange(
        schoolId: schoolId,
        active: active,
        change: () {
          HermesConfigStore(store).save(schoolId, config);
          if (remember == true) {
            HermesAccountStore(store).save(schoolId, account);
          }
          if (remember == false) HermesAccountStore(store).clear(schoolId);
        },
      );
      onCredentialsChanged();
      final label = state['accountLabel'];
      return {
        'status': 'authenticated',
        if (label is String && label.isNotEmpty && label.length <= 160)
          'accountLabel': label,
        'checkedAt': DateTime.now().toUtc().toIso8601String(),
      };
    } on ScriptRunException {
      rethrow;
    } catch (_) {
      if (!active()) throw const ScriptRunException('invocation_cancelled');
      return {'status': 'unknown'};
    } finally {
      cancellation?.removeListener(cancel);
      if (identical(_hermes.request, request)) _hermes.request = null;
    }
  }

  /// Online proof from the fixed provider. Errors never imply expiration.
  Future<Map<String, Object?>> checkHermesAccount({
    bool Function()? isActive,
    ScriptRunCancellation? cancellation,
    String? expectedGatewayUrl,
    String? expectedLoginDomain,
    String? expectedCertificateSha256,
    bool checkCertificate = false,
  }) async {
    _requireProtectedStoreAccess();
    final school = _school;
    final store = _store;
    final generation = _scripts.generation;
    final authenticationGeneration = _hermes.authenticationGeneration;
    bool active() =>
        !_scripts.disposed &&
        identical(store, _store) &&
        _school?.id == school?.id &&
        generation == _scripts.generation &&
        authenticationGeneration == _hermes.authenticationGeneration &&
        cancellation?.isCancelled != true &&
        (isActive?.call() ?? true);
    if (school == null || !active()) {
      throw const ScriptRunException('invocation_cancelled');
    }
    HermesNativeRequest? request;
    try {
      final archive = HermesConfigStore(store);
      final revision = archive.revision(school.id);
      final config = archive.load(school.id);
      if (config == null) return {'status': 'signedOut'};
      if (!config.matchesAccountScope(
        gatewayUrl: expectedGatewayUrl,
        loginDomain: expectedLoginDomain,
        certificateSha256: expectedCertificateSha256,
        checkCertificate: checkCertificate,
      )) {
        return {'status': 'signedOut'};
      }
      if (_hermes.request != null || _hermes.writing) {
        return {'status': 'unknown'};
      }
      request = _hermesBinding.request(config.nativeCheck());
      _hermes.request = request;
      cancellation?.addListener(request.cancel);
      final value = await request.result;
      if (!active()) throw const ScriptRunException('invocation_cancelled');
      final status = value['status'];
      if (!const ['authenticated', 'expired', 'unknown'].contains(status)) {
        return {'status': 'unknown'};
      }
      if (status == 'authenticated' && value.containsKey('session')) {
        final raw = value['session'];
        if (raw is! Map) return {'status': 'unknown'};
        final rotated = config.withRotatedSession(
          Map<String, dynamic>.from(raw),
        );
        // Preserve the exact captured record revision through the mutation.
        // Checking before change prevents a stale status overwriting a login.
        if (!identical(archive.revision(school.id), revision)) {
          return {'status': 'unknown'};
        }
        await _persistHermesChange(
          schoolId: school.id,
          active: active,
          change: () => archive.save(school.id, rotated),
        );
      }
      final label = value['accountLabel'];
      return {
        'status': status,
        if (status == 'authenticated' &&
            label is String &&
            label.isNotEmpty &&
            label.length <= 160)
          'accountLabel': label,
        if (status != 'unknown')
          'checkedAt': DateTime.now().toUtc().toIso8601String(),
      };
    } on ScriptRunException {
      rethrow;
    } catch (_) {
      if (!active()) throw const ScriptRunException('invocation_cancelled');
      return {'status': 'unknown'};
    } finally {
      if (request != null) cancellation?.removeListener(request.cancel);
      if (identical(_hermes.request, request)) _hermes.request = null;
    }
  }

  void cancelHermesAccountLogin() => _cancelHermesAuthentication();

  List<AppTunnelProvider> _defaultAppTunnelProviders() => [
    HermesProvider(
      binding: _hermesBinding,
      configuration: (schoolId) async {
        if (_hermes.writing) throw const AppTunnelException('app_tunnel_busy');
        if (_scripts.disposed || _school?.id != schoolId) {
          throw const AppTunnelException('hermes_cancelled');
        }
        return HermesConfigStore(_store).load(schoolId);
      },
    ),
  ];

  HermesConfigurationInfo? hermesConfigurationInfo() {
    if (hardwareUnlockFailed) return null;
    if (_hermes.writing) throw const AppTunnelException('app_tunnel_busy');
    final schoolId = _school?.id;
    return schoolId == null
        ? null
        : HermesConfigStore(_store).load(schoolId)?.info;
  }

  Future<HermesLoginBridge> createHermesLoginBridge({
    required String gatewayUrl,
    String? nodeCertificateSha256,
    ScriptPackage? package,
    bool Function()? isAuthorized,
  }) async {
    _requireProtectedStoreAccess();
    final school = _school;
    var generation = _scripts.generation;
    if (school == null) throw const AppTunnelException('app_tunnel_no_school');
    final gateway = HermesConfiguration.validateGateway(gatewayUrl);
    HermesConfiguration.validatePin(nodeCertificateSha256);
    if (package != null &&
        !package.manifest.accounts.any(
          (a) =>
              a.appTunnel?.gatewayUrl == gateway.origin &&
              a.appTunnel?.loginDomain == '' &&
              a.appTunnel?.nodeCertificateSha256 == nodeCertificateSha256,
        )) {
      throw const AppTunnelException('hermes_invalid_configuration');
    }
    await ensurePersistentStore(
      confirmSoftwareFallback: _scripts.storageConsent ?? () async => false,
    );
    final approvedRegistry = package == null ? null : await scriptRegistry;
    final approvedEpoch = approvedRegistry?.epoch;
    final store = _store;
    bool active() =>
        !_scripts.disposed &&
        (isAuthorized?.call() ?? true) &&
        (package == null ||
            (approvedRegistry!.epoch == approvedEpoch &&
                approvedRegistry.find(package.manifest.id)?.enabled == true &&
                approvedRegistry.find(package.manifest.id)?.package.digest ==
                    package.digest &&
                package.manifest.schoolId == school.id)) &&
        generation == _scripts.generation &&
        _school?.id == school.id &&
        identical(store, _store);
    if (!active()) throw const AppTunnelException('hermes_cancelled');
    final registry = await scriptRegistry;
    if (!active()) throw const AppTunnelException('hermes_cancelled');
    final origins = <String>{gateway.origin};
    for (final installation in registry.installations) {
      final candidate = installation.package;
      if (installation.enabled &&
          (package == null || installation.package.digest == package.digest) &&
          !candidate.requiresUpdate &&
          candidate.manifest.schoolId == school.id) {
        origins.addAll(
          candidate.manifest.network.origins
              .where((uri) => uri.scheme == 'https')
              .map((uri) => uri.origin),
        );
      }
    }
    return HermesLoginBridge(
      binding: _hermesBinding,
      gatewayUrl: gateway.origin,
      nodeCertificateSha256: nodeCertificateSha256,
      allowedOrigins: origins,
      isActive: active,
      save: (configuration) async {
        if (!active()) throw const AppTunnelException('hermes_cancelled');
        await _persistHermesChange(
          schoolId: school.id,
          active: active,
          change: () {
            HermesConfigStore(store).save(school.id, configuration);
            final accounts = HermesAccountStore(store);
            try {
              final account = accounts.load(school.id);
              if (account != null && account.gateway != configuration.gateway) {
                accounts.clear(school.id);
              }
            } on AppTunnelException {
              accounts.clear(school.id);
            }
          },
        );
        _cancelTrustedScripts();
        // Publishing this verified session revokes old-account routes while
        // preserving this bridge's completion within the new generation.
        generation = _scripts.generation;
        onCredentialsChanged();
      },
    );
  }

  Future<void> clearHermesConfiguration() async {
    _requireProtectedStoreAccess();
    final school = _school;
    if (school == null) return;
    _cancelTrustedScripts();
    final generation = _scripts.generation;
    final store = _store;
    bool active() =>
        !_scripts.disposed &&
        _scripts.generation == generation &&
        _school?.id == school.id &&
        identical(store, _store);
    await _persistHermesChange(
      schoolId: school.id,
      active: active,
      change: () {
        HermesConfigStore(store).clear(school.id);
        HermesAccountStore(store).clear(school.id);
      },
    );
    onCredentialsChanged();
  }
}
