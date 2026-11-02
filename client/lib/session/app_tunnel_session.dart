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

  void _cancelHermesAuthentication() {
    final state = _hermesStates[this];
    if (state == null) return;
    state.authenticationGeneration++;
    state.request?.cancel();
  }

  HermesAccountInfo? hermesAccountInfo() {
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

  /// Online proof from the fixed provider. Errors never imply expiration.
  Future<Map<String, Object?>> checkHermesAccount({
    bool Function()? isActive,
    ScriptRunCancellation? cancellation,
  }) async {
    final school = _school;
    final store = _store;
    final generation = _scripts.generation;
    bool active() =>
        !_scripts.disposed &&
        identical(store, _store) &&
        _school?.id == school?.id &&
        generation == _scripts.generation &&
        cancellation?.isCancelled != true &&
        (isActive?.call() ?? true);
    if (school == null || !active()) {
      throw const ScriptRunException('invocation_cancelled');
    }
    HermesNativeRequest? request;
    try {
      final config = HermesConfigStore(store).load(school.id);
      if (config == null) return {'status': 'signedOut'};
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
    if (_hermes.writing) throw const AppTunnelException('app_tunnel_busy');
    final schoolId = _school?.id;
    return schoolId == null
        ? null
        : HermesConfigStore(_store).load(schoolId)?.info;
  }

  Future<HermesLoginBridge> createHermesLoginBridge({
    required String gatewayUrl,
    String? nodeCertificateSha256,
  }) async {
    final school = _school;
    var generation = _scripts.generation;
    if (school == null) throw const AppTunnelException('app_tunnel_no_school');
    final gateway = HermesConfiguration.validateGateway(gatewayUrl);
    HermesConfiguration.validatePin(nodeCertificateSha256);
    await ensurePersistentStore(
      confirmSoftwareFallback: _scripts.storageConsent ?? () async => false,
    );
    final store = _store;
    bool active() =>
        !_scripts.disposed &&
        generation == _scripts.generation &&
        _school?.id == school.id &&
        identical(store, _store);
    if (!active()) throw const AppTunnelException('hermes_cancelled');
    final registry = await scriptRegistry;
    if (!active()) throw const AppTunnelException('hermes_cancelled');
    final origins = <String>{gateway.origin};
    for (final installation in registry.installations) {
      final package = installation.package;
      if (installation.enabled &&
          !package.requiresUpdate &&
          package.manifest.schoolId == school.id) {
        origins.addAll(
          package.manifest.network.origins
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
