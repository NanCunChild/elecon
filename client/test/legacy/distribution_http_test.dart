/// 片 F —— `HttpDistributionSource` 端点 D 拉取（ADR-018 §2.6 / 红线 #2）。
///
/// 经注入的 [HttpByteFetcher] 假源验证策略层：https/userinfo 护栏、明文 JSON 解析、bundle 按 digest
/// 拼路径 + 字节透传、大小上限双保险、失败即 null + 遥测——**不碰真实 socket**（IoHttpByteFetcher 的 dart:io 护栏属
/// thin shim，人工复核）。F 不做任何信任裁定，故此处无需签名。
library;

import 'dart:convert';
import 'dart:io' show HttpClient, HttpServer, InternetAddress, gzip;
import 'dart:typed_data';

import 'package:elecon/core/loader/catalog.dart';
import 'package:elecon/core/loader/diagnostics.dart';
import 'package:elecon/core/loader/distribution_http.dart';
import 'package:elecon/core/loader/revocation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可配置假 fetcher：按 url 返回预置字节（null=不可用）；记录被请求的 url 与 maxBytes。
class _FakeFetcher implements HttpByteFetcher {
  _FakeFetcher(this.responses);
  final Map<String, Uint8List?> responses;
  final List<Uri> requested = [];
  final List<int> maxBytesSeen = [];

  @override
  Future<Uint8List?> getBytes(
    Uri url, {
    required int maxBytes,
    required Duration timeout,
    void Function(HttpFetchFailure failure)? onFailure,
  }) async {
    requested.add(url);
    maxBytesSeen.add(maxBytes);
    return responses[url.toString()];
  }
}

Uint8List _jsonBytes(Map<String, dynamic> j) =>
    Uint8List.fromList(utf8.encode(jsonEncode(j)));

Uint8List _gzipJsonBytes(Map<String, dynamic> j) =>
    Uint8List.fromList(gzip.encode(_jsonBytes(j)));

void main() {
  final base = Uri.parse('https://dist.example.edu/');
  const catUrl = 'https://dist.example.edu/catalog.json.gz';
  const revUrl = 'https://dist.example.edu/revocation.json';

  final signedCatalog = SignedCatalog(
    catalogJson: jsonEncode({'catalogVersion': '1.0', 'sequence': 5}),
    signature: 'c2ln',
    keyId: 'k-cat',
    algorithm: 'ed25519',
  );
  final signedRevocation = SignedRevocationList(
    listJson: jsonEncode({'sequence': 3}),
    signature: 'c2ln',
    keyId: 'k-rev',
    algorithm: 'ed25519',
  );

  HttpDistributionSource mk(
    _FakeFetcher f, {
    Uri? baseUrl,
    int maxBundleBytes = kMaxDistributionBundleBytes,
    int maxManifestBytes = kMaxDistributionManifestBytes,
    void Function(String)? onWarning,
    void Function(AdapterDiagnostic)? onDiagnostic,
  }) => HttpDistributionSource(
    baseUrl: baseUrl ?? base,
    fetcher: f,
    maxBundleBytes: maxBundleBytes,
    maxManifestBytes: maxManifestBytes,
    onWarning: onWarning,
    onDiagnostic: onDiagnostic,
  );

  group('签名清单解析', () {
    test('失败类型透传：网络与解析可区分', () async {
      final diagnostics = <AdapterDiagnostic>[];
      final offline = await mk(
        _FakeFetcher({}),
        onDiagnostic: diagnostics.add,
      ).fetchRevocation();
      expect(offline, isNull);
      expect(diagnostics.single.kind, AdapterDiagnosticKind.network);

      diagnostics.clear();
      final malformed = await mk(
        _FakeFetcher({revUrl: Uint8List.fromList(utf8.encode('{bad'))}),
        onDiagnostic: diagnostics.add,
      ).fetchRevocation();
      expect(malformed, isNull);
      expect(diagnostics.single.kind, AdapterDiagnosticKind.parse);
    });

    test('fetchCatalog：gzip JSON → SignedCatalog（字段保真 + 请求正确 url）', () async {
      final f = _FakeFetcher({catUrl: _gzipJsonBytes(signedCatalog.toJson())});
      final r = await mk(f).fetchCatalog();
      expect(r, isNotNull);
      expect(r!.catalogJson, signedCatalog.catalogJson);
      expect(r.keyId, 'k-cat');
      expect(r.algorithm, 'ed25519');
      expect(f.requested.single.toString(), catUrl);
      expect(f.maxBytesSeen.single, kMaxDistributionManifestBytes);
    });

    test('fetchRevocation：有效 JSON → SignedRevocationList', () async {
      final f = _FakeFetcher({revUrl: _jsonBytes(signedRevocation.toJson())});
      final r = await mk(f).fetchRevocation();
      expect(r, isNotNull);
      expect(r!.listJson, signedRevocation.listJson);
      expect(r.keyId, 'k-rev');
    });

    test('fetchRevocation：gzip 内容编码 → SignedRevocationList', () async {
      final f = _FakeFetcher({
        revUrl: _gzipJsonBytes(signedRevocation.toJson()),
      });
      final r = await mk(f).fetchRevocation();
      expect(r, isNotNull);
      expect(r!.keyId, 'k-rev');
    });

    test('离线（fetcher 返回 null）→ null', () async {
      final f = _FakeFetcher({catUrl: null});
      expect(await mk(f).fetchCatalog(), isNull);
    });

    test('畸形 JSON 字节 → null + 遥测', () async {
      final warns = <String>[];
      final f = _FakeFetcher({
        catUrl: Uint8List.fromList(utf8.encode('{not json')),
      });
      final r = await mk(f, onWarning: warns.add).fetchCatalog();
      expect(r, isNull);
      expect(warns.any((w) => w.contains('catalog.json')), isTrue);
    });

    test('JSON 缺必需字段（fromJson 抛）→ null + 遥测', () async {
      final warns = <String>[];
      // 顶层是对象但缺 signature/keyId → SignedCatalog.fromJson 抛。
      final f = _FakeFetcher({
        catUrl: _jsonBytes({'catalogJson': '{}'}),
      });
      final r = await mk(f, onWarning: warns.add).fetchCatalog();
      expect(r, isNull);
      expect(warns, isNotEmpty);
    });

    test('顶层非 JSON 对象（数组）→ null + 遥测', () async {
      final warns = <String>[];
      final f = _FakeFetcher({
        catUrl: Uint8List.fromList(gzip.encode(utf8.encode('[1,2,3]'))),
      });
      final r = await mk(f, onWarning: warns.add).fetchCatalog();
      expect(r, isNull);
      expect(warns.any((w) => w.contains('非 JSON 对象')), isTrue);
    });

    test('catalog gzip 畸形 → null + 遥测', () async {
      final warns = <String>[];
      final f = _FakeFetcher({
        catUrl: Uint8List.fromList([1, 2, 3]),
      });
      final r = await mk(f, onWarning: warns.add).fetchCatalog();
      expect(r, isNull);
      expect(warns.any((w) => w.contains('解压失败')), isTrue);
    });
  });

  group('bundle 按 digest 拼路径 + 字节透传（ADR-018 §2.5.1）', () {
    final digest = 'a' * 64;
    final burl = 'https://dist.example.edu/bundles/$digest.json.gz';

    test('fetchBundle(digest)：请求 base/bundles/<digest>.json.gz，原样返回字节（不解包）', () async {
      final raw = Uint8List.fromList([0x1f, 0x8b, 1, 2, 3, 4]); // 伪 gzip 字节
      final f = _FakeFetcher({burl: raw});
      final r = await mk(f).fetchBundle(digest);
      expect(r, raw);
      expect(f.requested.single.toString(), burl);
      expect(f.maxBytesSeen.single, kMaxDistributionBundleBytes);
    });

    test('base 带子路径时同样相对拼接', () async {
      final raw = Uint8List.fromList([1, 2, 3]);
      final f = _FakeFetcher({'https://mirror.example.org/x/adapters/bundles/$digest.json.gz': raw});
      final r = await mk(
        f,
        baseUrl: Uri.parse('https://mirror.example.org/x/adapters/'),
      ).fetchBundle(digest);
      expect(r, raw);
    });

    test('digest 非 64 位小写 hex → 拒 + 遥测，不触 fetcher（防路径拼接）', () async {
      for (final bad in ['A' * 64, 'a' * 63, '../catalog.json.gz', '${'a' * 60}/../x', '']) {
        final warns = <String>[];
        final f = _FakeFetcher({});
        final r = await mk(f, onWarning: warns.add).fetchBundle(bad);
        expect(r, isNull, reason: 'digest=$bad');
        expect(f.requested, isEmpty, reason: 'digest=$bad');
        expect(warns.any((w) => w.contains('digest')), isTrue, reason: 'digest=$bad');
      }
    });

    test('bundle 超大小上限（源层双保险）→ null + 遥测', () async {
      final big = Uint8List(64); // > maxBundleBytes=16
      final warns = <String>[];
      final f = _FakeFetcher({burl: big});
      final r = await mk(
        f,
        maxBundleBytes: 16,
        onWarning: warns.add,
      ).fetchBundle(digest);
      expect(r, isNull);
      expect(warns.any((w) => w.contains('超大小上限')), isTrue);
    });
  });

  group('https/userinfo 护栏（红线 #2）', () {
    test('base URL 为 http → fetchCatalog 拒 + 遥测，且不触 fetcher', () async {
      final warns = <String>[];
      final f = _FakeFetcher({});
      final src = mk(
        f,
        baseUrl: Uri.parse('http://dist.example.edu/'),
        onWarning: warns.add,
      );
      expect(await src.fetchCatalog(), isNull);
      expect(f.requested, isEmpty); // 明文降级在触网前就拒
      expect(warns.any((w) => w.contains('非 https')), isTrue);
    });

    test('base URL 为 http → fetchBundle 拒 + 遥测，不触 fetcher', () async {
      final warns = <String>[];
      final f = _FakeFetcher({});
      final r = await mk(
        f,
        baseUrl: Uri.parse('http://dist.example.edu/'),
        onWarning: warns.add,
      ).fetchBundle('a' * 64);
      expect(r, isNull);
      expect(f.requested, isEmpty);
      expect(warns.any((w) => w.contains('非 https')), isTrue);
    });

    test('base URL 含 userinfo → 拒（防凭证入 URL）', () async {
      final warns = <String>[];
      final f = _FakeFetcher({});
      final r = await mk(
        f,
        baseUrl: Uri.parse('https://user:pass@dist.example.edu/'),
        onWarning: warns.add,
      ).fetchBundle('a' * 64);
      expect(r, isNull);
      expect(f.requested, isEmpty);
    });

    test('allowInsecureHttp（仅 DEV 覆盖 base）→ http base 放行；userinfo 仍拒', () async {
      final digest = 'b' * 64;
      final raw = Uint8List.fromList([9, 9]);
      final f = _FakeFetcher({
        'http://127.0.0.1:8080/bundles/$digest.json.gz': raw,
        'http://127.0.0.1:8080/revocation.json': _jsonBytes(signedRevocation.toJson()),
      });
      final src = HttpDistributionSource(
        baseUrl: Uri.parse('http://127.0.0.1:8080/'),
        fetcher: f,
        allowInsecureHttp: true,
      );
      expect(await src.fetchBundle(digest), raw);
      expect((await src.fetchRevocation())?.keyId, 'k-rev');

      final g = _FakeFetcher({});
      final withUser = HttpDistributionSource(
        baseUrl: Uri.parse('http://u:p@127.0.0.1:8080/'),
        fetcher: g,
        allowInsecureHttp: true,
      );
      expect(await withUser.fetchBundle(digest), isNull);
      expect(g.requested, isEmpty);
    });
  });

  test('IoHttpByteFetcher 超时后取消停滞响应', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = HttpClient();
    server.listen((request) {
      request.response.headers.chunkedTransferEncoding = true;
      request.response.add(const [1]);
      // Keep the response open. The client must abort it on timeout.
    });
    try {
      final result = await IoHttpByteFetcher(client: client).getBytes(
        Uri.parse('http://127.0.0.1:${server.port}/stalled'),
        maxBytes: 1024,
        timeout: const Duration(milliseconds: 20),
      );
      expect(result, isNull);
    } finally {
      client.close(force: true);
      await server.close(force: true);
    }
  });
}
