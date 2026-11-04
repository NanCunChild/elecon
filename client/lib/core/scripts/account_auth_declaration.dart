/// SDK14 account authentication methods. Namespace is addressing, not isolation.
library;

class ScriptAppTunnel {
  const ScriptAppTunnel({
    required this.service,
    required this.gatewayUrl,
    required this.loginDomain,
    this.nodeCertificateSha256,
    this.loginMode = 'password',
  });
  final String service, gatewayUrl, loginDomain;
  final String? nodeCertificateSha256;
  final String loginMode;
  factory ScriptAppTunnel.fromJson(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        raw.keys.any(
          (k) => !const {
            'service',
            'gatewayUrl',
            'loginDomain',
            'nodeCertificateSha256',
            'loginMode',
          }.contains(k),
        )) {
      throw const FormatException('invalid script tunnel');
    }
    final values = Map<String, dynamic>.of(raw);
    if (raw.containsKey('loginMode') && raw['loginMode'] is! String ||
        raw.containsKey('nodeCertificateSha256') &&
            raw['nodeCertificateSha256'] is! String) {
      throw const FormatException('invalid script tunnel options');
    }
    final pin = values.remove('nodeCertificateSha256');
    final mode = values.remove('loginMode') ?? 'password';
    if (!const ['password', 'web'].contains(mode) ||
        (mode == 'web' && values['loginDomain'] != '')) {
      throw const FormatException('invalid tunnel login mode');
    }
    if (pin != null &&
        (pin is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(pin))) {
      throw const FormatException('invalid node certificate fingerprint');
    }
    final config = ScriptCredentialReuse.fromJson({
      ...values,
      'sourceAccountId': 'host',
    });
    return ScriptAppTunnel(
      service: config.service,
      gatewayUrl: config.gatewayUrl,
      loginDomain: config.loginDomain,
      nodeCertificateSha256: pin as String?,
      loginMode: mode as String,
    );
  }
}

/// SDK15: the target and credential source are part of the approved package.
class ScriptCredentialReuse {
  const ScriptCredentialReuse({
    required this.sourceAccountId,
    required this.service,
    required this.gatewayUrl,
    required this.loginDomain,
  });
  factory ScriptCredentialReuse.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 4 ||
        value.keys.any(
          (key) => !const {
            'sourceAccountId',
            'service',
            'gatewayUrl',
            'loginDomain',
          }.contains(key),
        ) ||
        value['sourceAccountId'] is! String ||
        !RegExp(
          r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$',
        ).hasMatch(value['sourceAccountId'] as String) ||
        (value['sourceAccountId'] as String).length > 128 ||
        value['service'] != 'hermes-atrust' ||
        value['gatewayUrl'] is! String ||
        value['loginDomain'] is! String ||
        (value['loginDomain'] as String).length > 256 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value['loginDomain'] as String)) {
      throw const FormatException('invalid credential reuse declaration');
    }
    final gateway = Uri.tryParse(value['gatewayUrl'] as String);
    if (gateway == null ||
        gateway.scheme != 'https' ||
        gateway.host.isEmpty ||
        gateway.userInfo.isNotEmpty ||
        gateway.hasQuery ||
        gateway.hasFragment ||
        gateway.port < 1 ||
        gateway.port > 65535 ||
        gateway.origin != value['gatewayUrl'] ||
        (value['gatewayUrl'] as String).length > 2048) {
      throw const FormatException('credential reuse requires HTTPS origin');
    }
    return ScriptCredentialReuse(
      sourceAccountId: value['sourceAccountId'] as String,
      service: value['service'] as String,
      gatewayUrl: gateway.origin,
      loginDomain: value['loginDomain'] as String,
    );
  }
  final String sourceAccountId, service, gatewayUrl, loginDomain;
}

class ScriptAccountAuthentication {
  const ScriptAccountAuthentication({
    required this.namespace,
    required this.interactiveWeb,
    required this.silentWeb,
  });

  factory ScriptAccountAuthentication.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 4 ||
        value.keys.any(
          (key) => !const {
            'namespace',
            'savedPassword',
            'interactiveWeb',
            'silentWeb',
          }.contains(key),
        ) ||
        value['namespace'] is! String ||
        (value['namespace'] as String).length > 128 ||
        (value['namespace'] as String).contains('\n') ||
        !RegExp(
          r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$',
        ).hasMatch(value['namespace'] as String) ||
        value['savedPassword'] != true ||
        value['interactiveWeb'] is! bool ||
        value['silentWeb'] is! bool ||
        (value['silentWeb'] == true && value['interactiveWeb'] != true)) {
      throw const FormatException('invalid account authentication declaration');
    }
    return ScriptAccountAuthentication(
      namespace: value['namespace'] as String,
      interactiveWeb: value['interactiveWeb'] as bool,
      silentWeb: value['silentWeb'] as bool,
    );
  }

  final String namespace;
  final bool interactiveWeb;
  final bool silentWeb;
}
