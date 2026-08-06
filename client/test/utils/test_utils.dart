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

/// 解析兄弟仓 elecon-adapters 中某学校 adapter 目录（ADR-018 分离仓）。
///
/// 优先级（ADR-018 §2.11.1，按需拉取取代子模块）：env `ELECON_ADAPTERS_REPO`
/// → 按需拉取缓存 `.adapters-cache/elecon-adapters`（scripts/fetch-adapters.sh 默认落点） → 并排检出
/// `../elecon-adapters`。缺仓（CI 未拉子模块 / 本地无并排检出）返回 null，调用方 **skip-if-absent**，
/// 与服务端 `smoke-utils.adapterDirIfPresent` 一致。核心仓自有的 `_stdlib`/`_canary`/`_template`/
/// `school-helloworld` 仍用 [repoPath]（不经本函数）。
String? schoolAdapterDir(String adapterId, {bool? requireAdapters}) {
  final root = repoRoot();
  final envRepo = Platform.environment['ELECON_ADAPTERS_REPO'];
  final candidates = <String>[
    if (envRepo != null && envRepo.isNotEmpty) '$envRepo/adapters/$adapterId',
    '$root/.adapters-cache/elecon-adapters/adapters/$adapterId',
    '${Directory(root).parent.path}/elecon-adapters/adapters/$adapterId',
  ];
  for (final dir in candidates) {
    if (File('$dir/index.js').existsSync()) return dir;
  }
  if (requireAdapters ??
      (Platform.environment['ELECON_REQUIRE_ADAPTERS'] == '1')) {
    throw FileSystemException(
      "缺必需 adapter '$adapterId'：请运行 bash scripts/fetch-adapters.sh 或设置 ELECON_ADAPTERS_REPO",
    );
  }
  return null;
}

/// 读取并解码 `contract/golden/broker/` 下的 golden JSON 文件。
Map<String, dynamic> readGolden(String fileName) {
  final path = repoPath('contract/golden/broker/$fileName');
  return jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
}

/// 读取并解码 `contract/golden/broker/` 下的 golden JSON 文件为一组 golden 用例列表。
List<Map<String, dynamic>> readGoldenCases(
  String fileName, [
  String key = 'cases',
]) {
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
  Future<TransportResponse> fetch(
    TransportRequest req, {
    TransportCancelToken? cancelToken,
  }) async {
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
        queryParam: d['queryParam'] as String?,
        headerName: d['headerName'] as String?,
        role: d['role'] as String?,
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
  hostOnly: c['hostOnly'] as bool? ?? false,
  path: c['path'] as String,
  source: c['source'] as String,
);

Map<String, String> headersFromJson(Object? json) =>
    (json as Map).map((k, v) => MapEntry(k as String, v as String));
