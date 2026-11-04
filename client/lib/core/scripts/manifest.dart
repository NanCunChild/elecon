/// Source package contract and content identity (ADR-034 §2/§6).
/// 🔒 Parsing does not evaluate source or grant execution trust.
library;

import 'sdk_version.dart';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:elecon_contract/output_validator_registry.dart';

import 'network_policy.dart';
import 'localization.dart';
import 'account_auth_declaration.dart';
import 'web_content.dart';
import 'school_declaration.dart';
export 'localization.dart';
export 'account_auth_declaration.dart';
export 'web_content.dart';
export 'school_declaration.dart';

const scriptPackageFormat = 'elecon-script/1';

/// ADR-052: authentication, private windows and side effects stay foreground.
const foregroundCommunityCapabilities = {
  'account.session',
  'forum.session',
  'messages.session',
  'messages.list',
  'messages.conversations',
  'messages.history',
  'messages.send',
  'attendance.checkin',
  'web.content',
};
const maxScriptPackageBytes = 1024 * 1024;

class ScriptPackage {
  ScriptPackage._(
    this.manifest,
    this.source,
    this.digest,
    this._encoded,
    this.requiresUpdate,
  );

  factory ScriptPackage.parse(String text) => ScriptPackage._parse(text);

  /// ADR-046: retain retired installs for review/update, never for execution.
  factory ScriptPackage.restore(String text) =>
      ScriptPackage._parse(text, restoring: true);

  static ScriptPackage _parse(String text, {bool restoring = false}) {
    if (text.length > maxScriptPackageBytes ||
        utf8.encode(text).length > maxScriptPackageBytes) {
      throw const FormatException('script package exceeds 1 MiB');
    }
    final decoded = jsonDecode(text);
    final root = _object(decoded, 'package');
    _keys(root, {'format', 'manifest', 'source'}, 'package');
    if (root['format'] != scriptPackageFormat) {
      throw const FormatException('unsupported script package format');
    }
    final rawManifest = _object(root['manifest'], 'manifest');
    final retired = rawManifest.containsKey('actions');
    if (retired && !restoring) {
      throw const FormatException('actions removed; update the script package');
    }
    final manifest = ScriptManifest.fromJson(
      retired
          ? (Map<String, dynamic>.of(rawManifest)..remove('actions'))
          : rawManifest,
    );
    final source = _text(root, 'source', maxScriptPackageBytes);
    final canonical = jsonEncode(_canonical(root));
    return ScriptPackage._(
      manifest,
      source,
      sha256.convert(utf8.encode(canonical)).toString(),
      canonical,
      retired,
    );
  }

  final ScriptManifest manifest;
  final String source;
  final String digest;
  final String _encoded;
  final bool requiresUpdate;

  String encode() => _encoded;
}

class ScriptManifest {
  ScriptManifest._({
    required this.sdkVersion,
    required this.id,
    required this.version,
    required this.schoolId,
    required this.school,
    required this.name,
    required this.homeTitle,
    required this.network,
    required this.websocketNetwork,
    required this.browser,
    required this.scanner,
    required this.deviceInputs,
    required this.capabilities,
    required this.home,
    required this.cards,
    required this.pages,
    required this.declaresPages,
    required this.accounts,
    required this.appTunnels,
    required this.localization,
    required this.webContent,
  });

  factory ScriptManifest.fromJson(Map<String, dynamic> json) {
    _keys(json, {
      'sdkVersion',
      'id',
      'version',
      'schoolId',
      if (json.containsKey('school')) 'school',
      'name',
      if (json.containsKey('homeTitle')) 'homeTitle',
      'network',
      if (json.containsKey('websocketOrigins')) 'websocketOrigins',
      'browser',
      if (json.containsKey('scanner')) 'scanner',
      if (json.containsKey('deviceInputs')) 'deviceInputs',
      'capabilities',
      if (json.containsKey('home')) 'home',
      if (json.containsKey('cards')) 'cards',
      if (json.containsKey('pages')) 'pages',
      if (json.containsKey('accounts')) 'accounts',
      if (json.containsKey('appTunnels')) 'appTunnels',
      if (json.containsKey('localization')) 'localization',
      if (json.containsKey('webContent')) 'webContent',
    }, 'manifest');
    if (!supportsTrustedScriptSdk(json['sdkVersion']) ||
        json['sdkVersion'] is! int) {
      throw const FormatException('unsupported script SDK version');
    }
    if (json.containsKey('localization') && (json['sdkVersion'] as int) < 13) {
      throw const FormatException('localization requires SDK 13');
    }
    final localization = json.containsKey('localization')
        ? ScriptLocalization.fromJson(json['localization'])
        : null;
    final sockets = json.containsKey('websocketOrigins')
        ? json['websocketOrigins']
        : const [];
    if (sockets is! List ||
        sockets.length > 8 ||
        (json.containsKey('websocketOrigins') &&
            (json['sdkVersion'] as int) < 9) ||
        sockets.any((s) => s is! String || !s.startsWith('wss://'))) {
      throw const FormatException(
        'websocketOrigins requires SDK 9 and exact wss origins',
      );
    }
    final network = ScriptNetworkPolicy.fromJson(
      _object(json['network'], 'network'),
    );
    final websocketNetwork = ScriptNetworkPolicy.fromJson({
      'origins': [
        for (final s in sockets) (s as String).replaceFirst('wss:', 'https:'),
      ],
      if (network.ipAllow != null) 'ipAllow': network.ipAllow,
    });
    String? homeTitle;
    if (json.containsKey('homeTitle')) {
      if ((json['sdkVersion'] as int) < 7) {
        throw const FormatException('homeTitle requires SDK 7');
      }
      homeTitle = _text(json, 'homeTitle', 160);
      if (homeTitle.runes.length > 80) {
        throw const FormatException('homeTitle exceeds 80 characters');
      }
      if (RegExp(
        r'[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]',
      ).hasMatch(homeTitle)) {
        throw const FormatException('homeTitle must be single-line plain text');
      }
    }
    if (json.containsKey('scanner') &&
        ((json['sdkVersion'] as int) < 8 || json['scanner'] is! bool)) {
      throw const FormatException('scanner requires SDK 8 and a boolean');
    }
    final deviceInputs = json.containsKey('deviceInputs')
        ? json['deviceInputs']
        : const [];
    if (json.containsKey('deviceInputs') &&
        ((json['sdkVersion'] as int) < 10 ||
            deviceInputs is! List ||
            deviceInputs.length > 3 ||
            deviceInputs.toSet().length != deviceInputs.length ||
            deviceInputs.any(
              (value) => !const {'camera', 'image', 'location'}.contains(value),
            ))) {
      throw const FormatException(
        'deviceInputs requires SDK 10 and unique input kinds',
      );
    }
    final id = _text(json, 'id', 128);
    final schoolId = _text(json, 'schoolId', 128);
    final version = _text(json, 'version', 64);
    if (!_identifier.hasMatch(id) || !_identifier.hasMatch(schoolId)) {
      throw const FormatException('invalid script or school identifier');
    }
    _versionParts(version);
    final rawCapabilities = json['capabilities'];
    if (rawCapabilities is! List ||
        rawCapabilities.isEmpty ||
        rawCapabilities.length > 64) {
      throw const FormatException(
        'script capabilities must contain 1–64 entries',
      );
    }
    if (json['browser'] is! bool) {
      throw const FormatException('manifest.browser must be a boolean');
    }
    final caps = rawCapabilities
        .map(
          (raw) => ScriptCapability.fromJson(
            _object(raw, 'capability'),
            sdkVersion: json['sdkVersion'] as int,
          ),
        )
        .toList(growable: false);
    if (caps.map((c) => c.id).toSet().length != caps.length) {
      throw const FormatException('duplicate script capability');
    }
    final rawHome = json['home'];
    if (json.containsKey('home') &&
        ((json['sdkVersion'] as int) < 4 ||
            rawHome is! List ||
            rawHome.length > ((json['sdkVersion'] as int) >= 18 ? 32 : 16))) {
      throw const FormatException('invalid script home declaration');
    }
    final home = (rawHome as List? ?? const [])
        .map((raw) => ScriptHomeEntry.fromJson(_object(raw, 'home entry')))
        .toList(growable: false);
    if (home.map((e) => e.capability).toSet().length != home.length ||
        home.any(
          (e) =>
              e.capability == 'climate.command' ||
              e.capability == 'card.qr' ||
              e.capability == 'query.controls' ||
              foregroundCommunityCapabilities.contains(e.capability) ||
              !caps.any((c) => c.id == e.capability),
        )) {
      throw const FormatException('duplicate or undeclared home capability');
    }
    // ADR-043 §3: presentation suggestions do not declare new capabilities.
    final rawCards = json['cards'];
    if (json.containsKey('cards') &&
        ((json['sdkVersion'] as int) < 6 ||
            rawCards is! List ||
            rawCards.length > 10)) {
      throw const FormatException('invalid script cards declaration');
    }
    final cards = (rawCards as List? ?? const [])
        .map(
          (raw) => ScriptCardEntry.fromJson(
            _object(raw, 'card entry'),
            sdkVersion: json['sdkVersion'] as int,
          ),
        )
        .toList(growable: false);
    final capabilityIds = caps.map((c) => c.id).toSet();
    final webContent = json.containsKey('webContent')
        ? ScriptWebContent.parseList(json['webContent'])
        : const <ScriptWebContent>[];
    if (json.containsKey('webContent') &&
        ((json['sdkVersion'] as int) < 14 ||
            json['browser'] != true ||
            !caps.any(
              (c) => c.id == 'web.content' && c.schemaVersion == '1.0',
            ))) {
      throw const FormatException(
        'webContent requires SDK14, browser and web.content/1.0',
      );
    }
    if (capabilityIds.contains('web.content') && webContent.isEmpty) {
      throw const FormatException('web.content requires declared pages');
    }
    final rawPages = json['pages'];
    if (json.containsKey('pages') &&
        ((json['sdkVersion'] as int) < 18 ||
            rawPages is! List ||
            rawPages.length > 32)) {
      throw const FormatException('pages require SDK18 and at most 32 entries');
    }
    final pages = (rawPages as List? ?? const [])
        .map((raw) => ScriptPageEntry.fromJson(_object(raw, 'page entry')))
        .toList(growable: false);
    if (pages.map((page) => page.id).toSet().length != pages.length ||
        pages.any(
          (page) =>
              !page.supports(capabilityIds) ||
              (page.template == 'web' &&
                  !webContent.any((web) => web.id == page.webPageId)),
        )) {
      throw const FormatException('duplicate or unsupported script page');
    }
    for (final card in cards) {
      if (card.pageId == null) continue;
      final matches = pages.where((page) => page.id == card.pageId);
      if (matches.length != 1 ||
          (card.type != 'generic' && card.type != matches.single.template)) {
        throw const FormatException('invalid card page binding');
      }
    }
    if (cards.map((c) => c.id).toSet().length != cards.length ||
        cards.any(
          (c) => !(c.type == 'generic' && c.pageId != null
              ? true
              : c.type == 'card'
              ? capabilityIds.any(
                  const {
                    'card.balance',
                    'card.transactions',
                    'card.qr',
                  }.contains,
                )
              : capabilityIds.containsAll(c.requiredCapabilities)),
        )) {
      throw const FormatException('duplicate or unsupported script card');
    }
    final rawAccounts = json['accounts'];
    if (((json['sdkVersion'] as int) >= 11 && !json.containsKey('accounts')) ||
        (json.containsKey('accounts') &&
            ((json['sdkVersion'] as int) < 11 ||
                rawAccounts is! List ||
                rawAccounts.length > 16))) {
      throw const FormatException('accounts requires SDK 11 and an array');
    }
    final accounts = (rawAccounts as List? ?? const [])
        .map(
          (raw) => ScriptAccount.fromJson(
            _object(raw, 'account'),
            sdkVersion: json['sdkVersion'] as int,
          ),
        )
        .toList(growable: false);
    if (accounts.map((a) => a.id).toSet().length != accounts.length ||
        accounts.any(
          (a) =>
              (a.loginCapability != null &&
                  !capabilityIds.contains(a.loginCapability)) ||
              (a.statusCapability != null &&
                  a.statusCapability != 'account.session') ||
              (a.statusCapability != null &&
                  !capabilityIds.contains(a.statusCapability)) ||
              (a.authentication != null &&
                  (a.loginCapability == null ||
                      (a.authentication!.interactiveWeb &&
                          json['browser'] != true) ||
                      a.authentication!.silentWeb)) ||
              !capabilityIds.containsAll(a.capabilities),
        )) {
      throw const FormatException('duplicate account or undeclared capability');
    }
    final appTunnels = json['appTunnels'] ?? const [];
    if (appTunnels is! List ||
        appTunnels.length > 1 ||
        (json.containsKey('appTunnels') && (json['sdkVersion'] as int) < 12) ||
        appTunnels.any((v) => v != 'hermes-atrust')) {
      throw const FormatException('invalid APPTunnel declaration');
    }
    for (final account in accounts) {
      final tunnel = account.appTunnel;
      if (tunnel != null &&
          (account.authentication != null ||
              account.loginCapability != 'account.session' ||
              account.statusCapability == null ||
              network.ipAllow != null ||
              !appTunnels.contains(tunnel.service) ||
              !network.origins.any((u) => u.origin == tunnel.gatewayUrl))) {
        throw const FormatException('invalid script tunnel binding');
      }
      final reuse = account.credentialReuse;
      if (reuse == null) continue;
      if (tunnel != null &&
          (tunnel.loginMode != 'password' ||
              reuse.service != tunnel.service ||
              reuse.gatewayUrl != tunnel.gatewayUrl ||
              reuse.loginDomain != tunnel.loginDomain)) {
        throw const FormatException('credential reuse target mismatch');
      }
      final source = accounts
          .where((a) => a.id == reuse.sourceAccountId)
          .firstOrNull;
      if (source == null ||
          source.id == account.id ||
          source.authentication == null ||
          source.credentialReuse != null ||
          account.authentication != null ||
          account.loginCapability != 'account.session' ||
          account.statusCapability == null ||
          network.ipAllow != null ||
          !appTunnels.contains(reuse.service) ||
          !network.origins.any((u) => u.origin == reuse.gatewayUrl)) {
        throw const FormatException('invalid credential reuse binding');
      }
    }
    for (final ref in [
      ...caps.map((c) => c.appTunnelAccountId),
      ...accounts.map((a) => a.appTunnelAccountId),
    ]) {
      if (ref != null &&
          !accounts.any((a) => a.id == ref && a.appTunnel != null)) {
        throw const FormatException('unknown tunnel account dependency');
      }
    }
    if (accounts.any(
          (a) =>
              a.appTunnelAccountId != null &&
              (a.appTunnel != null || a.credentialReuse != null),
        ) ||
        caps.any(
          (c) => c.id == 'account.session' && c.appTunnelAccountId != null,
        )) {
      throw const FormatException('tunnel management cannot depend on itself');
    }
    if (json.containsKey('school') && (json['sdkVersion'] as int) < 16) {
      throw const FormatException('school display requires SDK16');
    }
    return ScriptManifest._(
      sdkVersion: json['sdkVersion'] as int,
      id: id,
      version: version,
      schoolId: schoolId,
      school: json.containsKey('school')
          ? ScriptSchool.fromJson(json['school'])
          : null,
      name: _text(json, 'name', 160),
      homeTitle: homeTitle,
      network: network,
      websocketNetwork: websocketNetwork,
      browser: json['browser'] as bool,
      scanner: json['scanner'] == true,
      deviceInputs: Set.unmodifiable((deviceInputs as List).cast<String>()),
      capabilities: List.unmodifiable(caps),
      home: List.unmodifiable(home),
      cards: List.unmodifiable(cards),
      pages: List.unmodifiable(pages),
      declaresPages: json.containsKey('pages'),
      accounts: List.unmodifiable(accounts),
      appTunnels: Set.unmodifiable(appTunnels.cast<String>()),
      localization: localization,
      webContent: webContent,
    );
  }

  final int sdkVersion;
  final ScriptSchool? school;
  final String id;
  final String version;
  final String schoolId;
  final String name;
  final String? homeTitle;

  /// Use [declaresAccounts] to distinguish an older SDK from explicit [].
  final List<ScriptAccount> accounts;
  final Set<String> appTunnels;
  final ScriptLocalization? localization;
  final List<ScriptWebContent> webContent;
  bool get declaresAccounts => sdkVersion >= 11;
  final ScriptNetworkPolicy network;
  final ScriptNetworkPolicy websocketNetwork;
  final bool browser;
  final bool scanner;
  final Set<String> deviceInputs;
  final List<ScriptCapability> capabilities;
  final List<ScriptHomeEntry> home;
  final List<ScriptCardEntry> cards;
  final List<ScriptPageEntry> pages;
  final bool declaresPages;

  ScriptCapability? capability(String id) {
    for (final c in capabilities) {
      if (c.id == id) return c;
    }
    return null;
  }
}

class ScriptCapability {
  const ScriptCapability({
    required this.id,
    required this.schema,
    required this.schemaVersion,
    this.appTunnelAccountId,
  });

  factory ScriptCapability.fromJson(
    Map<String, dynamic> json, {
    int sdkVersion = 1,
  }) {
    _keys(json, {
      'id',
      'schema',
      'schemaVersion',
      if (sdkVersion >= 16 && json.containsKey('appTunnelAccountId'))
        'appTunnelAccountId',
    }, 'capability');
    final id = _text(json, 'id', 128);
    final schema = _text(json, 'schema', 160);
    final version = _text(json, 'schemaVersion', 32);
    if (!_identifier.hasMatch(id) ||
        schema != 'elecon.$id' ||
        outputValidatorFor(schema, version) == null) {
      throw const FormatException(
        'invalid capability or unsupported output schema',
      );
    }
    final ref = json.containsKey('appTunnelAccountId')
        ? _text(json, 'appTunnelAccountId', 128)
        : null;
    if (ref != null && !_identifier.hasMatch(ref)) {
      throw const FormatException('invalid tunnel account id');
    }
    return ScriptCapability(
      id: id,
      schema: schema,
      schemaVersion: version,
      appTunnelAccountId: ref,
    );
  }

  final String id;
  final String schema;
  final String schemaVersion;
  final String? appTunnelAccountId;
}

final _identifier = RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$');
final _semver = RegExp(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$');

int compareScriptVersions(String a, String b) {
  final aa = _versionParts(a);
  final bb = _versionParts(b);
  for (var i = 0; i < 3; i++) {
    final diff = aa[i].compareTo(bb[i]);
    if (diff != 0) return diff;
  }
  return 0;
}

List<BigInt> _versionParts(String value) {
  if (!_semver.hasMatch(value) || value.trim() != value || value.length > 64) {
    throw const FormatException(
      'version must be three numeric SemVer components',
    );
  }
  return value.split('.').map(BigInt.parse).toList(growable: false);
}

Map<String, dynamic> _object(Object? value, String label) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('$label must be an object');
  }
  return value;
}

String _text(Map<String, dynamic> value, String key, int max) {
  final text = value[key];
  if (text is! String ||
      text.trim().isEmpty ||
      text.length > max ||
      text.contains('\u0000')) {
    throw FormatException('invalid $key');
  }
  return text;
}

void _keys(Map<String, dynamic> value, Set<String> allowed, String label) {
  if (value.length != allowed.length ||
      value.keys.any((key) => !allowed.contains(key))) {
    throw FormatException('$label contains missing or unknown fields');
  }
}

Object? _canonical(Object? value) {
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList(growable: false);
  return value;
}

/// ADR-038 §1: script-owned freshness and default preload query.
class ScriptHomeEntry {
  const ScriptHomeEntry({
    required this.capability,
    required this.ttlSeconds,
    this.params = const {},
    this.preload = false,
  });
  factory ScriptHomeEntry.fromJson(Map<String, dynamic> json) {
    if (json.keys.any(
          (k) => !const {
            'capability',
            'ttlSeconds',
            'params',
            'preload',
          }.contains(k),
        ) ||
        json['ttlSeconds'] is! int ||
        (json['ttlSeconds'] as int) < 30 ||
        (json['ttlSeconds'] as int) > 86400 ||
        (json.containsKey('preload') && json['preload'] is! bool)) {
      throw const FormatException('invalid home policy');
    }
    final params = json.containsKey('params')
        ? _object(json['params'], 'home params')
        : <String, dynamic>{};
    if (utf8.encode(jsonEncode(params)).length > 4096) {
      throw const FormatException('home params exceed limit');
    }
    return ScriptHomeEntry(
      capability: _text(json, 'capability', 128),
      ttlSeconds: json['ttlSeconds'] as int,
      params: _immutableJson(params) as Map<String, dynamic>,
      preload: json['preload'] == true,
    );
  }
  final String capability;
  final int ttlSeconds;
  final Map<String, dynamic> params;
  final bool preload;
}

/// ADR-064: descriptive requirements and one explicit same-package login call.
/// This is not a credential access policy or a server-side account status.
class ScriptAccount {
  const ScriptAccount._({
    required this.id,
    required this.name,
    required this.instructions,
    required this.capabilities,
    required this.loginCapability,
    required this.loginParams,
    required this.statusCapability,
    required this.statusParams,
    required this.authentication,
    required this.credentialReuse,
    required this.appTunnel,
    required this.appTunnelAccountId,
  });

  factory ScriptAccount.fromJson(
    Map<String, dynamic> json, {
    int sdkVersion = 11,
  }) {
    _keys(json, {
      'id',
      'name',
      'instructions',
      'capabilities',
      if (json.containsKey('login')) 'login',
      if (sdkVersion >= 12 && json.containsKey('status')) 'status',
      if (sdkVersion >= 14 && json.containsKey('authentication'))
        'authentication',
      if (sdkVersion >= 15 && json.containsKey('credentialReuse'))
        'credentialReuse',
      if (sdkVersion >= 16 && json.containsKey('appTunnel')) 'appTunnel',
      if (sdkVersion >= 16 && json.containsKey('appTunnelAccountId'))
        'appTunnelAccountId',
    }, 'account');
    final id = _text(json, 'id', 128);
    final name = _text(json, 'name', 160);
    final instructions = _text(json, 'instructions', 2048);
    final plainText = RegExp(
      r'[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]',
    );
    final capabilities = json['capabilities'];
    if (!_identifier.hasMatch(id) ||
        plainText.hasMatch(name) ||
        plainText.hasMatch(instructions) ||
        capabilities is! List ||
        capabilities.isEmpty ||
        capabilities.length > 64 ||
        capabilities.any((c) => c is! String || c.isEmpty || c.length > 128) ||
        capabilities.toSet().length != capabilities.length) {
      throw const FormatException('invalid account declaration');
    }
    final login = json.containsKey('login')
        ? _object(json['login'], 'account login')
        : <String, dynamic>{};
    _keys(login, {
      if (json.containsKey('login')) 'capability',
      if (login.containsKey('params')) 'params',
    }, 'account login');
    final params = login.containsKey('params')
        ? _object(login['params'], 'account login params')
        : <String, dynamic>{};
    if (login['capability'] == 'account.session' &&
        (params['account'] != id ||
            params['operation'] != 'login' ||
            params.length != 2)) {
      throw const FormatException('invalid account login binding');
    }
    if (utf8.encode(jsonEncode(params)).length > 4096) {
      throw const FormatException('account login params exceed limit');
    }
    final status = json.containsKey('status')
        ? _object(json['status'], 'account status')
        : <String, dynamic>{};
    _keys(status, {
      if (json.containsKey('status')) 'capability',
      if (status.containsKey('params')) 'params',
    }, 'account status');
    final statusParams = status.containsKey('params')
        ? _object(status['params'], 'account status params')
        : <String, dynamic>{};
    if (utf8.encode(jsonEncode(statusParams)).length > 4096 ||
        (json.containsKey('status') &&
            (status['capability'] != 'account.session' ||
                statusParams['operation'] != 'status' ||
                statusParams['account'] != id ||
                statusParams.length != 2))) {
      throw const FormatException('invalid read-only account status binding');
    }
    return ScriptAccount._(
      id: id,
      name: name,
      instructions: instructions,
      capabilities: List.unmodifiable(capabilities.cast<String>()),
      loginCapability: json.containsKey('login')
          ? _text(login, 'capability', 128)
          : null,
      loginParams: _immutableJson(params) as Map<String, dynamic>,
      statusCapability: status['capability'] as String?,
      statusParams: _immutableJson(statusParams) as Map<String, dynamic>,
      authentication: json.containsKey('authentication')
          ? ScriptAccountAuthentication.fromJson(json['authentication'])
          : null,
      credentialReuse: json.containsKey('credentialReuse')
          ? ScriptCredentialReuse.fromJson(json['credentialReuse'])
          : null,
      appTunnel: json.containsKey('appTunnel')
          ? ScriptAppTunnel.fromJson(json['appTunnel'])
          : null,
      appTunnelAccountId: json.containsKey('appTunnelAccountId')
          ? _text(json, 'appTunnelAccountId', 128)
          : null,
    );
  }

  final String id, name, instructions;
  final String? loginCapability;
  final String? statusCapability;
  final Map<String, dynamic> statusParams;
  final List<String> capabilities;
  final Map<String, dynamic> loginParams;
  final ScriptAccountAuthentication? authentication;
  final ScriptCredentialReuse? credentialReuse;
  final ScriptAppTunnel? appTunnel;
  final String? appTunnelAccountId;
}

// ADR-038 §1 / ADR-034 §2: nested declaration parameters are digest-bound too.
Object? _immutableJson(Object? value) {
  if (value is Map<String, dynamic>) {
    return Map<String, dynamic>.unmodifiable(
      value.map((key, item) => MapEntry(key, _immutableJson(item))),
    );
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_immutableJson));
  }
  return value;
}

/// ADR-043 §3: finite host-owned presentation, never executable layout.
class ScriptCardEntry {
  const ScriptCardEntry._(
    this.type,
    this.defaultVariant,
    this.id,
    this.title,
    this.hasExplicitId,
    this.pageId,
  );

  factory ScriptCardEntry.fromJson(
    Map<String, dynamic> json, {
    int sdkVersion = 6,
  }) {
    _keys(json, {
      'type',
      'defaultVariant',
      if (sdkVersion >= 12 && json.containsKey('id')) 'id',
      if (sdkVersion >= 12 && json.containsKey('title')) 'title',
      if (sdkVersion >= 18 && json.containsKey('pageId')) 'pageId',
    }, 'card entry');
    final type = _text(json, 'type', 32);
    final variant = _text(json, 'defaultVariant', 32);
    if (!requiredCapabilitiesByType.containsKey(type) ||
        !variantsFor(type).contains(variant)) {
      throw const FormatException('unsupported script card presentation');
    }
    final id = json.containsKey('id') ? _text(json, 'id', 128) : type;
    final title = json.containsKey('title') ? _text(json, 'title', 160) : null;
    if (!_identifier.hasMatch(id) ||
        (title != null &&
            RegExp(
              r'[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]',
            ).hasMatch(title))) {
      throw const FormatException('invalid card instance identity or title');
    }
    final pageId = json.containsKey('pageId')
        ? _text(json, 'pageId', 128)
        : null;
    if (pageId != null && !_identifier.hasMatch(pageId)) {
      throw const FormatException('invalid page id');
    }
    return ScriptCardEntry._(
      type,
      variant,
      id,
      title,
      json.containsKey('id'),
      pageId,
    );
  }

  final String type;
  final String defaultVariant;
  final String id;
  final String? title;
  final bool hasExplicitId;
  final String? pageId;

  static const requiredCapabilitiesByType = <String, List<String>>{
    'notice': ['notice.list'],
    'schedule': ['schedule.week'],
    'grades': ['grades.list'],
    'card': ['card.balance'],
    'library': ['library.loans'],
    'exam': ['exam.list'],
    'classroom': ['classroom.buildings', 'classroom.available'],
    'energy': ['energy.meters', 'energy.usage'],
    'climate': ['climate.devices', 'climate.status'],
    'generic': ['generic.section'],
    'directory': ['directory.phones'],
  };

  static const _resizableTypes = {'notice', 'schedule', 'grades', 'library'};

  static List<String> variantsFor(String type) => _resizableTypes.contains(type)
      ? const ['compact', 'regular', 'expanded']
      : const ['regular'];

  List<String> get requiredCapabilities => requiredCapabilitiesByType[type]!;
}

/// SDK18 host-owned second-level page, bound to one approved package.
class ScriptPageEntry {
  const ScriptPageEntry({
    required this.id,
    required this.title,
    required this.template,
    this.tab = false,
    this.webPageId,
  });
  factory ScriptPageEntry.fromJson(Map<String, dynamic> json) {
    _keys(json, {
      'id',
      'title',
      'template',
      if (json.containsKey('tab')) 'tab',
      if (json.containsKey('webPageId')) 'webPageId',
    }, 'page entry');
    final id = _text(json, 'id', 128);
    final title = _text(json, 'title', 160);
    final template = _text(json, 'template', 32);
    final webPageId = json.containsKey('webPageId')
        ? _text(json, 'webPageId', 128)
        : null;
    if (!_identifier.hasMatch(id) ||
        RegExp(
          r'[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]',
        ).hasMatch(title) ||
        !templates.contains(template) ||
        (json.containsKey('tab') && json['tab'] is! bool) ||
        ((template == 'web') != (webPageId != null)) ||
        (webPageId != null && !_identifier.hasMatch(webPageId))) {
      throw const FormatException('invalid script page');
    }
    return ScriptPageEntry(
      id: id,
      title: title,
      template: template,
      tab: json['tab'] == true,
      webPageId: webPageId,
    );
  }
  static final templates = {
    ...ScriptCardEntry.requiredCapabilitiesByType.keys,
    'faculty',
    'forum',
    'messages',
    'web',
  };
  final String id;
  final String title;
  final String template;
  final bool tab;
  final String? webPageId;
  bool supports(Set<String> caps) => switch (template) {
    'card' => caps.any(
      const {'card.balance', 'card.transactions', 'card.qr'}.contains,
    ),
    'messages' =>
      caps.contains('messages.conversations') || caps.contains('messages.list'),
    'forum' => caps.contains('forum.session'),
    'web' => caps.contains('web.content'),
    'faculty' => caps.contains('faculty.search'),
    _ => caps.containsAll(
      ScriptCardEntry.requiredCapabilitiesByType[template] ?? const ['invalid'],
    ),
  };
}
