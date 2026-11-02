/// ADR-062: a routing preference grants neither new origins nor new identities.
part of 'session_controller.dart';

extension AppTunnelSession on SessionController {
  List<AppTunnelProvider> get appTunnelProviders => _networkRoutes.providers;
  bool get appTunnelSelectionBusy => _changingNetwork;

  Future<String?> appTunnelChoice() async {
    final school = _school;
    if (school == null) throw const AppTunnelException('app_tunnel_no_school');
    return _networkRoutes.choice(school.id);
  }

  Future<void> selectAppTunnel(String? providerId) async {
    final school = _school;
    if (school == null) throw const AppTunnelException('app_tunnel_no_school');
    if (_changingNetwork || _legacyNetworkRuns != 0) {
      throw const AppTunnelException('app_tunnel_busy');
    }
    _changingNetwork = true;
    _cancelTrustedScripts();
    onCredentialsChanged();
    try {
      await _networkRoutes.save(school.id, providerId);
    } finally {
      _changingNetwork = false;
      if (!_scripts.disposed) onCredentialsChanged();
    }
  }
}
