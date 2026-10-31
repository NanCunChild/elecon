/// Source package contract and content identity (ADR-034 §2/§6).
/// 🔒 Parsing does not evaluate source or grant execution trust.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:elecon_contract/output_validator_registry.dart';

import 'network_policy.dart';

const scriptPackageFormat = 'elecon-script/1';
const maxScriptPackageBytes = 1024 * 1024;

class ScriptPackage {
  ScriptPackage._(this.manifest, this.source, this.digest, this._encoded);

  factory ScriptPackage.parse(String text) {
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
    final manifest = ScriptManifest.fromJson(
      _object(root['manifest'], 'manifest'),
    );
    final source = _text(root, 'source', maxScriptPackageBytes);
    final canonical = jsonEncode(_canonical(root));
    return ScriptPackage._(
      manifest,
      source,
      sha256.convert(utf8.encode(canonical)).toString(),
      canonical,
    );
  }

  final ScriptManifest manifest;
  final String source;
  final String digest;
  final String _encoded;

  String encode() => _encoded;
}

class ScriptManifest {
  ScriptManifest._({
    required this.sdkVersion,
    required this.id,
    required this.version,
    required this.schoolId,
    required this.name,
    required this.network,
    required this.browser,
    required this.capabilities,
    required this.home,
    required this.actions,
    required this.cards,
  });

  factory ScriptManifest.fromJson(Map<String, dynamic> json) {
    _keys(json, {
      'sdkVersion',
      'id',
      'version',
      'schoolId',
      'name',
      'network',
      'browser',
      'capabilities',
      if (json.containsKey('home')) 'home',
      if (json.containsKey('actions')) 'actions',
      if (json.containsKey('cards')) 'cards',
    }, 'manifest');
    if (!const {1, 2, 3, 4, 5, 6}.contains(json['sdkVersion']) ||
        json['sdkVersion'] is! int) {
      throw const FormatException('unsupported script SDK version');
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
        .map((raw) => ScriptCapability.fromJson(_object(raw, 'capability')))
        .toList(growable: false);
    if (caps.map((c) => c.id).toSet().length != caps.length) {
      throw const FormatException('duplicate script capability');
    }
    final rawHome = json['home'];
    if (json.containsKey('home') &&
        ((json['sdkVersion'] as int) < 4 ||
            rawHome is! List ||
            rawHome.length > 16)) {
      throw const FormatException('invalid script home declaration');
    }
    final home = (rawHome as List? ?? const [])
        .map((raw) => ScriptHomeEntry.fromJson(_object(raw, 'home entry')))
        .toList(growable: false);
    if (home.map((e) => e.capability).toSet().length != home.length ||
        home.any(
          (e) =>
              e.capability == 'climate.command' ||
              !caps.any((c) => c.id == e.capability),
        )) {
      throw const FormatException('duplicate or undeclared home capability');
    }
    // ADR-043 §3: presentation suggestions do not declare new capabilities.
    final rawCards = json['cards'];
    if (json.containsKey('cards') &&
        (json['sdkVersion'] != 6 ||
            rawCards is! List ||
            rawCards.length > 10)) {
      throw const FormatException('invalid script cards declaration');
    }
    final cards = (rawCards as List? ?? const [])
        .map((raw) => ScriptCardEntry.fromJson(_object(raw, 'card entry')))
        .toList(growable: false);
    final capabilityIds = caps.map((c) => c.id).toSet();
    if (cards.map((c) => c.type).toSet().length != cards.length ||
        cards.any((c) => !capabilityIds.containsAll(c.requiredCapabilities))) {
      throw const FormatException('duplicate or unsupported script card');
    }
    final network = ScriptNetworkPolicy.fromJson(
      _object(json['network'], 'network'),
    );
    final rawActions = json['actions'];
    if (json.containsKey('actions') &&
        ((json['sdkVersion'] as int) < 5 ||
            rawActions is! List ||
            rawActions.length > 4)) {
      throw const FormatException('invalid script actions');
    }
    final actions = (rawActions as List? ?? const [])
        .map(
          (raw) =>
              ScriptActionDeclaration.fromJson(_object(raw, 'action'), network),
        )
        .toList(growable: false);
    if (actions.map((a) => a.capability).toSet().length != actions.length ||
        actions.any((a) => !caps.any((c) => c.id == a.capability)) ||
        caps.any(
          (c) =>
              c.id == 'climate.command' &&
              !actions.any((a) => a.capability == c.id),
        )) {
      throw const FormatException('action capability mismatch');
    }
    return ScriptManifest._(
      sdkVersion: json['sdkVersion'] as int,
      id: id,
      version: version,
      schoolId: schoolId,
      name: _text(json, 'name', 160),
      network: network,
      browser: json['browser'] as bool,
      capabilities: List.unmodifiable(caps),
      home: List.unmodifiable(home),
      actions: List.unmodifiable(actions),
      cards: List.unmodifiable(cards),
    );
  }

  final int sdkVersion;
  final String id;
  final String version;
  final String schoolId;
  final String name;
  final ScriptNetworkPolicy network;
  final bool browser;
  final List<ScriptCapability> capabilities;
  final List<ScriptHomeEntry> home;
  final List<ScriptActionDeclaration> actions;
  final List<ScriptCardEntry> cards;

  ScriptActionDeclaration? action(String capability) {
    for (final action in actions) {
      if (action.capability == capability) return action;
    }
    return null;
  }

  ScriptCapability? capability(String id) {
    for (final c in capabilities) {
      if (c.id == id) return c;
    }
    return null;
  }
}

/// 🔒 ADR-040 §4: exact action destination is part of the approved digest.
class ScriptActionDeclaration {
  const ScriptActionDeclaration._(this.capability, this.method, this.url);
  factory ScriptActionDeclaration.fromJson(
    Map<String, dynamic> json,
    ScriptNetworkPolicy network,
  ) {
    _keys(json, {'capability', 'method', 'url'}, 'action');
    final url = _text(json, 'url', 2048);
    final uri = Uri.tryParse(url);
    if (json['capability'] != 'climate.command' ||
        json['method'] != 'POST' ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        !network.allowsUrl(uri) ||
        uri.path.isEmpty ||
        url != uri.toString()) {
      throw const FormatException('invalid action endpoint');
    }
    return ScriptActionDeclaration._('climate.command', 'POST', url);
  }
  final String capability, method, url;
}

class ScriptCapability {
  const ScriptCapability({
    required this.id,
    required this.schema,
    required this.schemaVersion,
  });

  factory ScriptCapability.fromJson(Map<String, dynamic> json) {
    _keys(json, {'id', 'schema', 'schemaVersion'}, 'capability');
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
    return ScriptCapability(id: id, schema: schema, schemaVersion: version);
  }

  final String id;
  final String schema;
  final String schemaVersion;
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
  const ScriptCardEntry._(this.type, this.defaultVariant);

  factory ScriptCardEntry.fromJson(Map<String, dynamic> json) {
    _keys(json, {'type', 'defaultVariant'}, 'card entry');
    final type = _text(json, 'type', 32);
    final variant = _text(json, 'defaultVariant', 32);
    if (!requiredCapabilitiesByType.containsKey(type) ||
        !variantsFor(type).contains(variant)) {
      throw const FormatException('unsupported script card presentation');
    }
    return ScriptCardEntry._(type, variant);
  }

  final String type;
  final String defaultVariant;

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
  };

  static const _resizableTypes = {'notice', 'schedule', 'grades', 'library'};

  static List<String> variantsFor(String type) => _resizableTypes.contains(type)
      ? const ['compact', 'regular', 'expanded']
      : const ['regular'];

  List<String> get requiredCapabilities => requiredCapabilitiesByType[type]!;
}
