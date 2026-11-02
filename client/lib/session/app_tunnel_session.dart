/// ADR-062: UI receives configuration metadata and a value-free login bridge.
part of 'session_controller.dart';

extension HermesTunnelSession on SessionController {
  List<AppTunnelProvider> _defaultAppTunnelProviders() => [
    HermesProvider(
      configuration: (schoolId) async {
        if (_scripts.disposed || _school?.id != schoolId) {
          throw const AppTunnelException('hermes_cancelled');
        }
        return HermesConfigStore(_store).load(schoolId);
      },
    ),
  ];

  HermesConfigurationInfo? hermesConfigurationInfo() {
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
    final backend = _secure;
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
      gatewayUrl: gateway.origin,
      nodeCertificateSha256: nodeCertificateSha256,
      allowedOrigins: origins,
      isActive: active,
      save: (configuration) async {
        if (!active()) throw const AppTunnelException('hermes_cancelled');
        final archive = HermesConfigStore(store);
        HermesConfiguration? previous;
        try {
          previous = archive.load(school.id);
        } on AppTunnelException {
          // An explicitly verified fresh login may replace corrupt old material.
        }
        archive.save(school.id, configuration);
        final written = archive.revision(school.id);
        try {
          await _flushCredentialBackend(backend);
        } catch (_) {
          if (identical(written, archive.revision(school.id))) {
            if (active() && previous != null) {
              archive.save(school.id, previous);
            } else {
              archive.clear(school.id);
            }
          }
          throw const AppTunnelException('hermes_persist_failed');
        }
        if (!active() || !identical(written, archive.revision(school.id))) {
          // Changing school/profile during flush never publishes a new login.
          if (identical(written, archive.revision(school.id))) {
            archive.clear(school.id);
            await _flushCredentialBackend(backend);
          }
          throw const AppTunnelException('hermes_cancelled');
        }
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
    HermesConfigStore(_store).clear(school.id);
    onCredentialsChanged();
    await _flushCredentialBackend(_secure);
  }
}
