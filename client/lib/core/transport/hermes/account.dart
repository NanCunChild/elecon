/// ADR-064: host-owned tunnel passwords never enter the script credential API.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../credential/store.dart';
import '../../credential/types.dart';
import '../app_tunnel.dart';
import 'configuration.dart';

class HermesAccountInfo {
  const HermesAccountInfo({
    required this.gatewayUrl,
    required this.username,
    required this.loginDomain,
    this.nodeCertificateSha256,
  });
  final String gatewayUrl, username, loginDomain;
  final String? nodeCertificateSha256;
}

class HermesAccount {
  HermesAccount({
    required String gatewayUrl,
    required String username,
    required String password,
    String loginDomain = '',
    String? nodeCertificateSha256,
  }) : gateway = HermesConfiguration.validateGateway(gatewayUrl),
       username = username.trim(),
       loginDomain = loginDomain.trim(),
       _password = password,
       nodeCertificateSha256 = HermesConfiguration.validatePin(
         nodeCertificateSha256,
       ) {
    final control = RegExp(r'[\x00-\x1f\x7f]');
    if (this.username.isEmpty ||
        this.username.length > 256 ||
        this.loginDomain.length > 256 ||
        control.hasMatch(this.username) ||
        control.hasMatch(this.loginDomain) ||
        password.isEmpty ||
        password.length > 4096 ||
        password.contains('\u0000')) {
      throw const AppTunnelException('hermes_invalid_configuration');
    }
  }
  final Uri gateway;
  final String username, loginDomain;
  final String _password;
  final String? nodeCertificateSha256;
  HermesAccountInfo get info => HermesAccountInfo(
    gatewayUrl: gateway.origin,
    username: username,
    loginDomain: loginDomain,
    nodeCertificateSha256: nodeCertificateSha256,
  );

  Map<String, Object?> nativeAuthenticate() => {
    'op': 'authenticatePassword',
    'gatewayUrl': gateway.origin,
    'username': username,
    'password': _password,
    'loginDomain': loginDomain,
  };

  /// Blank is only a password-preserving edit of the same login identity.
  static HermesAccount edit({
    required String gatewayUrl,
    required String username,
    required String password,
    String loginDomain = '',
    String? nodeCertificateSha256,
    HermesAccount? previous,
  }) {
    final gateway = HermesConfiguration.validateGateway(gatewayUrl);
    if (password.isEmpty &&
        (previous == null ||
            previous.gateway != gateway ||
            previous.username != username.trim() ||
            previous.loginDomain != loginDomain.trim())) {
      throw const AppTunnelException('hermes_password_required');
    }
    return HermesAccount(
      gatewayUrl: gateway.origin,
      username: username,
      password: password.isEmpty ? previous!._password : password,
      loginDomain: loginDomain,
      nodeCertificateSha256: nodeCertificateSha256,
    );
  }

  @override
  String toString() => 'HermesAccount([protected])';
}

class HermesAccountStore {
  HermesAccountStore(this._credentials);
  static const type = 'app-tunnel-account';
  final CredentialStore _credentials;
  String _key(String schoolId) =>
      '$type:hermes-atrust:${sha256.convert(utf8.encode(schoolId))}';

  HermesAccount? load(String schoolId) {
    final entry = _credentials
        .list()
        .where((e) => e.ref == _key(schoolId))
        .firstOrNull;
    if (entry == null) return null;
    if (entry.schoolId != schoolId ||
        entry.type != type ||
        entry.status != CredentialStatus.active ||
        entry.value.length > 64 * 1024) {
      throw const AppTunnelException('hermes_invalid_configuration');
    }
    try {
      final json = jsonDecode(entry.value) as Map;
      if (json['version'] != 1) throw const FormatException();
      return HermesAccount(
        gatewayUrl: json['gatewayUrl'] as String,
        username: json['username'] as String,
        password: json['password'] as String,
        loginDomain: json['loginDomain'] as String,
        nodeCertificateSha256: json['nodeCertificateSha256'] as String?,
      );
    } catch (_) {
      throw const AppTunnelException('hermes_invalid_configuration');
    }
  }

  void save(String schoolId, HermesAccount account) => _credentials.put(
    CredentialEntry(
      ref: _key(schoolId),
      schoolId: schoolId,
      type: type,
      scope: const [],
      value: jsonEncode({
        'version': 1,
        'gatewayUrl': account.gateway.origin,
        'username': account.username,
        'password': account._password,
        'loginDomain': account.loginDomain,
        'nodeCertificateSha256': account.nodeCertificateSha256,
      }),
      acquiredAt: DateTime.now().millisecondsSinceEpoch,
      expiresAt: null,
      status: CredentialStatus.active,
    ),
  );
  void clear(String schoolId) => _credentials.delete(_key(schoolId));
}
