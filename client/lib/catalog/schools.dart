/// 已验签学校 manifest 的客户端视图（ADR-015 / ADR-017 / ADR-018）。
///
/// 本文件不内置任何学校登录 URL、导航域、凭证 scope 或 mint service。所有这些事实只能从
/// 完整验签后的 adapter bundle manifest 解析，避免客户端与热更新 bundle 双事实源。
///
/// 🔒 红线 #1/#4：只解析签名覆盖的非秘密声明；调用方必须先完成 AdapterLoader 全门链。
library;

import '../core/broker/inject_policy.dart';
import '../core/login/webview_login.dart';

/// 当前产品入口会主动发现的学校 adapter。它只定位签名 bundle，不承载认证事实。
/// catalog 尚无“可展示学校”字段，不能直接把测试 adapter 全部显示在选校页。
const List<String> schoolAdapterIds = ['school-xidian'];

class SchoolDescriptor {
  const SchoolDescriptor({
    required this.id,
    required this.displayName,
    required this.subtitle,
    required this.login,
    required this.adapterId,
    this.tlsProceedHosts = const {},
    this.available = true,
    this.capabilityCredentials = const {},
  });

  final String id;
  final String displayName;
  final String subtitle;
  final String adapterId;
  final LoginManifestView login;
  final Set<String> tlsProceedHosts;
  final bool available;

  /// 能力→凭证是客户端核心的执行前闸门，尚不属于 manifest 契约。
  final Map<String, List<String>> capabilityCredentials;

  /// 从已验签 bundle manifest 建立学校描述。畸形或核心 policy 引用未声明 ref 时 fail-closed。
  factory SchoolDescriptor.fromVerifiedManifest(Map<String, dynamic> manifest) {
    final adapterId = _string(manifest, 'adapterId');
    final schoolId = _string(manifest, 'schoolId');
    final displayName = _string(manifest, 'displayName');
    final network = _map(manifest, 'network');
    final allow = _stringList(network, 'allow');
    final credentialsJson = manifest['credentials'];
    if (credentialsJson is! Map<String, dynamic>) {
      throw const FormatException('manifest.credentials 缺失或非法');
    }
    final credentials = <String, CredentialDecl>{};
    for (final entry in credentialsJson.entries) {
      if (entry.value is! Map<String, dynamic>) {
        throw FormatException("credential '${entry.key}' 非对象");
      }
      final value = entry.value as Map<String, dynamic>;
      final type = _string(value, 'type');
      if (!const {'cookie', 'header', 'query'}.contains(type)) {
        throw FormatException("credential '${entry.key}' type 非法");
      }
      final queryParam = value['queryParam'];
      final role = value['role'];
      credentials[entry.key] = CredentialDecl(
        scope: _stringList(value, 'scope'),
        type: type,
        queryParam: queryParam is String ? queryParam : null,
        role: role is String ? role : null,
      );
    }

    final loginJson = _map(manifest, 'login');
    final success = _map(loginJson, 'success');
    final ssoMint = _parseSsoMint(loginJson['ssoMint']);
    final policy = _coreCapabilityPolicy[schoolId] ?? const {};
    for (final refs in policy.values) {
      for (final ref in refs) {
        if (!credentials.containsKey(ref)) {
          throw FormatException("核心 capability policy 引用未声明凭证 '$ref'");
        }
      }
    }

    return SchoolDescriptor(
      id: schoolId,
      displayName: displayName,
      subtitle: '统一身份认证',
      adapterId: adapterId,
      login: LoginManifestView(
        schoolId: schoolId,
        url: _string(loginJson, 'url'),
        navigationAllow: _stringList(loginJson, 'navigationAllow'),
        successUrlMatches: _stringList(success, 'whenUrlMatches'),
        ssoMint: ssoMint,
        brokerView: BrokerManifestView(allow: allow, credentials: credentials),
      ),
      capabilityCredentials: policy,
    );
  }
}

SsoMintDecl? _parseSsoMint(Object? raw) {
  if (raw == null) return null;
  if (raw is! Map<String, dynamic>) {
    throw const FormatException('login.ssoMint 非对象');
  }
  final servicesRaw = raw['services'];
  if (servicesRaw is! Map<String, dynamic> || servicesRaw.isEmpty) {
    throw const FormatException('login.ssoMint.services 缺失或为空');
  }
  final services = <String, SsoMintServiceDecl>{};
  for (final entry in servicesRaw.entries) {
    if (entry.value is! Map<String, dynamic>) {
      throw FormatException("ssoMint service '${entry.key}' 非对象");
    }
    final value = entry.value as Map<String, dynamic>;
    final formsRaw = value['forms'];
    List<SsoMintForm>? forms;
    if (formsRaw != null) {
      if (formsRaw is! List || formsRaw.isEmpty) {
        throw FormatException("ssoMint service '${entry.key}' forms 非法");
      }
      forms = [];
      for (final item in formsRaw) {
        final form = SsoMintForm.tryParse(item);
        if (form == null || forms.contains(form)) {
          throw FormatException("ssoMint service '${entry.key}' forms 非法");
        }
        forms.add(form);
      }
    }
    final via = value['via'];
    services[entry.key] = SsoMintServiceDecl(
      service: _string(value, 'service'),
      success: _stringList(value, 'success'),
      via: via is String ? via : null,
      forms: forms,
    );
  }
  return SsoMintDecl(
    authEndpoint: _string(raw, 'authEndpoint'),
    services: services,
  );
}

Map<String, dynamic> _map(Map<String, dynamic> source, String key) {
  final value = source[key];
  if (value is! Map<String, dynamic>) {
    throw FormatException('$key 缺失或非对象');
  }
  return value;
}

String _string(Map<String, dynamic> source, String key) {
  final value = source[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key 缺失或非法');
  }
  return value;
}

List<String> _stringList(Map<String, dynamic> source, String key) {
  final value = source[key];
  if (value is! List || value.isEmpty || value.any((item) => item is! String)) {
    throw FormatException('$key 缺失或非法');
  }
  return List<String>.unmodifiable(value.cast<String>());
}

/// 暂未进入 contract 的核心凭证闸门。只保留 ref 关系，不重复 URL/scope/type/mint 事实。
const Map<String, Map<String, List<String>>> _coreCapabilityPolicy = {
  'xidian': {
    'grades.list': ['ehall-session'],
    'schedule.week': ['ehall-session'],
    'exam.list': ['ehall-session'],
    'classroom.buildings': ['ehall-session'],
    'classroom.available': ['ehall-session'],
    'card.balance': ['card-session'],
    'card.transactions': ['card-session'],
    'library.loans': ['library-session'],
  },
};
