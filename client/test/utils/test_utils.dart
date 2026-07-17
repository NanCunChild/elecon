/// 客户端 broker / runtime 测试的共享工具。
///
/// 收敛多个测试文件里重复的辅助逻辑：
///   - 仓库根查找（消除 8× 重复的 `_repoPath` / `_repoDir`）
///   - golden 文件 JSON 解码辅助
///   - FakeResolver / FakeTransport（B6b 测试的替身）
///   - golden 夹具 JSON → 领域类型解码器
library;

import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/broker/cookie_jar.dart';
import 'package:elecon/core/broker/fetch_proxy.dart';
import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/broker/ports.dart';

/// 从 [Directory.current] 向上逐层查找仓库根。
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

/// 解析相对仓库根的路径。
String repoPath(String relPath) => '${repoRoot()}/$relPath';

/// 读取并解码 `contract/golden/broker/` 下的 golden JSON 文件。
Map<String, dynamic> readGolden(String fileName) {
  final path = repoPath('contract/golden/broker/$fileName');
  return jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
}

/// 读取并解码 `contract/golden/broker/` 下的 golden JSON 文件为一组 golden 用例列表。
List<Map<String, dynamic>> readGoldenCases(String fileName, [String key = 'cases']) {
  final golden = readGolden(fileName);
  return (golden[key] as List).cast<Map<String, dynamic>>();
}

Map<String, dynamic> readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

// ---------------------------------------------------------------------------
// 测试替身
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
// Golden 夹具解码器
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
