/// ADR-062: gateway material lives only in the current protected school store.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../credential/store.dart';
import '../../credential/types.dart';
import '../app_tunnel.dart';

class HermesConfigurationInfo {
  const HermesConfigurationInfo({
    required this.gatewayUrl,
    this.nodeCertificateSha256,
  });
  final String gatewayUrl;
  final String? nodeCertificateSha256;
}

class HermesConfiguration {
  HermesConfiguration({
    required String gatewayUrl,
    required Map<String, dynamic> session,
    String? nodeCertificateSha256,
  }) : gateway = validateGateway(gatewayUrl),
       nodeCertificateSha256 = validatePin(nodeCertificateSha256),
       _session = Map.unmodifiable(session) {
    if (session['version'] != 1 ||
        session['gateway_host'] is! String ||
        (session['gateway_host'] as String).toLowerCase() != gateway.host ||
        session['gateway_port'] != gateway.port ||
        session['cookies'] is! List ||
        (session['cookies'] as List).length > 256 ||
        ['sid', 'device_id', 'connection_id', 'sign_key_hex'].any(
          (key) =>
              session[key] is! String ||
              (session[key] as String).isEmpty ||
              (session[key] as String).length > 4096,
        ) ||
        utf8.encode(jsonEncode(session)).length > 256 * 1024) {
      throw const AppTunnelException('hermes_invalid_configuration');
    }
  }
  final Uri gateway;
  final String? nodeCertificateSha256;
  final Map<String, dynamic> _session;
  HermesConfigurationInfo get info => HermesConfigurationInfo(
    gatewayUrl: gateway.origin,
    nodeCertificateSha256: nodeCertificateSha256,
  );
  Map<String, Object?> nativeCheck() => {
    'op': 'checkSession',
    'gatewayUrl': gateway.origin,
    'session': _session,
  };
  Map<String, Object?> nativeStart(String directory) => {
    'op': 'start',
    'gatewayUrl': gateway.origin,
    'session': _session,
    'socketDirectory': directory,
    if (nodeCertificateSha256 != null)
      'nodeCertificateSha256': nodeCertificateSha256,
  };
  Map<String, Object?> _json() => {
    'version': 1,
    'gatewayUrl': gateway.origin,
    'session': _session,
    if (nodeCertificateSha256 != null)
      'nodeCertificateSha256': nodeCertificateSha256,
  };

  static Uri validateGateway(String value) {
    final uri = Uri.tryParse(value.trim());
    if (value.length > 2048 ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw const AppTunnelException('hermes_invalid_configuration');
    }
    return Uri.parse(uri.origin);
  }

  static String? validatePin(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final pin = value.trim().toLowerCase();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(pin)) {
      throw const AppTunnelException('hermes_invalid_configuration');
    }
    return pin;
  }

  @override
  String toString() => 'HermesConfiguration([protected])';
}

class HermesConfigStore {
  HermesConfigStore(this.credentials);
  static const type = 'app-tunnel-session';
  final CredentialStore credentials;
  String _key(String schoolId) =>
      '$type:hermes-atrust:${sha256.convert(utf8.encode(schoolId))}';
  Object? revision(String schoolId) =>
      credentials.list().where((e) => e.ref == _key(schoolId)).firstOrNull;
  HermesConfiguration? load(String schoolId) {
    final entry = credentials
        .list()
        .where((e) => e.ref == _key(schoolId))
        .firstOrNull;
    if (entry == null) return null;
    if (entry.type != type ||
        entry.schoolId != schoolId ||
        entry.status != CredentialStatus.active ||
        entry.value.length > 512 * 1024) {
      throw const AppTunnelException('hermes_invalid_configuration');
    }
    try {
      final data = jsonDecode(entry.value) as Map;
      if (data['version'] != 1) throw const FormatException();
      return HermesConfiguration(
        gatewayUrl: data['gatewayUrl'] as String,
        session: Map<String, dynamic>.from(data['session'] as Map),
        nodeCertificateSha256: data['nodeCertificateSha256'] as String?,
      );
    } catch (_) {
      throw const AppTunnelException('hermes_invalid_configuration');
    }
  }

  void save(String schoolId, HermesConfiguration configuration) =>
      credentials.put(
        CredentialEntry(
          ref: _key(schoolId),
          schoolId: schoolId,
          type: type,
          scope: const [],
          value: jsonEncode(configuration._json()),
          acquiredAt: DateTime.now().millisecondsSinceEpoch,
          expiresAt: null,
          status: CredentialStatus.active,
        ),
      );
  void clear(String schoolId) => credentials.delete(_key(schoolId));
}
