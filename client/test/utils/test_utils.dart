/// Shared test utilities for client-side broker / runtime tests.
///
/// Extract common helpers used across multiple test files:
///   - repo root lookup (eliminates 8× duplication of `_repoPath` / `_repoDir`)
///   - golden file JSON decode helpers
///   - FakeResolver / FakeTransport (doubles for B6b tests)
///   - golden fixture JSON → domain type decoders
library;

import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/broker/cookie_jar.dart';
import 'package:elecon/core/broker/fetch_proxy.dart';
import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/broker/ports.dart';

/// Locate the repo root by walking up from [Directory.current].
String repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory('${dir.path}/contract').existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.path;
}

/// Resolve a path relative to the repo root.
String repoPath(String relPath) => '${repoRoot()}/$relPath';

/// Read and decode a golden JSON file under `contract/golden/broker/`.
Map<String, dynamic> readGolden(String fileName) {
  final path = repoPath('contract/golden/broker/$fileName');
  return jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
}

/// Read and decode a golden JSON file under `contract/golden/broker/` as a
/// list of golden cases.
List<Map<String, dynamic>> readGoldenCases(String fileName, [String key = 'cases']) {
  final golden = readGolden(fileName);
  return (golden[key] as List).cast<Map<String, dynamic>>();
}

Map<String, dynamic> readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

class FakeResolver implements CredentialResolver {
  FakeResolver(this._map);
  final Map<String, ResolvedCredential> _map;
  @override
  Future<ResolvedCredential?> get(String ref) async => _map[ref];
}

class FakeTransport implements Transport {
  FakeTransport(this._queue);
  final List<TransportResponse> _queue;
  final List<TransportRequest> seen = [];
  @override
  Future<TransportResponse> fetch(TransportRequest req,
      {TransportCancelToken? cancelToken}) async {
    seen.add(req);
    if (_queue.isEmpty) throw StateError('FakeTransport queue exhausted');
    return _queue.removeAt(0);
  }
}

// ---------------------------------------------------------------------------
// Golden fixture decoders
// ---------------------------------------------------------------------------

BrokerManifestView viewFromJson(Map<String, dynamic> v) {
  final credentials = <String, CredentialDecl>{};
  final c = v['credentials'] as Map<String, dynamic>?;
  if (c != null) {
    c.forEach((ref, decl) {
      final d = decl as Map<String, dynamic>;
      credentials[ref] = CredentialDecl(
        scope: (d['scope'] as List).cast<String>(),
        type: d['type'] as String,
      );
    });
  }
  return BrokerManifestView(
    allow: (v['allow'] as List).cast<String>(),
    credentials: credentials,
  );
}

JarCookie cookieFromJson(Map<String, dynamic> c) => JarCookie(
      name: c['name'] as String,
      value: c['value'] as String,
      domain: c['domain'] as String,
      path: c['path'] as String,
      source: c['source'] as String,
    );

Map<String, String> headersFromJson(Object? json) =>
    (json as Map).map((k, v) => MapEntry(k as String, v as String));
