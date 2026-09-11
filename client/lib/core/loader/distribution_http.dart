/// 🔒 片 F —— 公网分发端点 D 的 HTTP [DistributionSource] 实现（ADR-018 §2.6 / 端点 D，红线 #2）。
///
/// 端点 D 是**零凭证、无状态、可退化为静态 CDN** 的公网分发面（ADR-018 §2 表格 D 行）。本实现据此
/// 只做**匿名 GET** 三类静态产物，交回编排器 `loader.dart`（片 E）做全部信任裁定：
///   - `catalog.json.gz`（gzip(JSON) 签名清单）→ [SignedCatalog]；gzip 不在签名范围内；
///   - `revocation.json`（明文 JSON 签名清单）→ [SignedRevocationList]；
///   - `bundles/<digest>.json.gz`（packed bundle，传输封套 `gzip(JSON({envelopeB64,signature,blobs}))`）→ 原始字节
///     （**不在此解 gzip/解包**——loader 的 `openBundle` 带压缩炸弹护栏，本层只搬字节）。
///     路径由 catalog entry 的 digest 拼出、相对**本实现自持的 base URL**——catalog 不描述端点
///     （ADR-018 §2.5.1），同一份签名 dist 可托管在官方端点、镜像或本地冒烟服务器。
///
/// **本层零信任裁定**：返回的 Signed* / 字节**均未验签**；验签 + 防回滚 + 吊销 + stdlibMin 全在
/// loader（每次加载重跑）。本层职责仅「安全地把公网字节取回来」。
///
/// **安全护栏（红线 #2 + DoS）**：
///   - **仅 https、无 userinfo**：拒 `http://` 与 `https://user:pass@…`（凭证绝不上网，且防明文降级）。
///     唯一例外是 [allowInsecureHttp]——**只在 DEV-Sideload profile 用 dart-define 覆盖 base 时**由装配层
///     打开（本地 http 端点冒烟）；DEPLOY 编译期折叠为 false。来源只影响可用性、不影响信任裁定：
///     字节仍须过 loader 的 digest 重算 + Ed25519 验签 + 吊销门。
///   - **digest 形态门**：bundle 路径只接受 64 位小写 hex（防路径穿越 / 任意路径拼接）。
///   - **零凭证**：不带 cookie、不设 Authorization/自定义身份头（端点 D 根本不认凭证）。
///   - **不跟随重定向**：`followRedirects=false`，3xx 视为不可用——静态产物住固定 URL；跟随重定向会把
///     「取哪份字节」交给中间人（内容寻址 + 验签仍兜底，但宁可 fail-closed 不给中间人腾挪空间）。
///   - **不关 TLS 校验**：用 OS/Dart TLS 栈正常校验（ADR-009：禁 verify=False）。
///   - **大小上限 + 超时**：清单 ≤ [kMaxDistributionManifestBytes]、bundle ≤ [kMaxDistributionBundleBytes]
///     （对齐 loader `openBundle` 的 gz 输入上限 512KiB），边下边计数超限即弃；每请求 [timeout] 墙钟。
///
/// **失败即「本源不可用」**：任何网络错误 / 非 2xx / 超限 / 解析失败一律返回 null（记 [_onWarning] 遥测），
/// **绝不抛给 loader**——loader 据此退化到 last-good / bootstrap，永不 fail-open（同 [DistributionSource] 合约）。
///
/// **HTTP 实现经 [HttpByteFetcher] 接缝注入**：真实 = [IoHttpByteFetcher]（`dart:io`）；测试注入假源，
/// 使 https/大小/解析等策略层无需真实 socket 即可测。
///
/// 🔒 红线 #1/#2/#4 承重件：改动须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bundle.dart' show BundleFormatException, boundedGunzip;
import 'catalog.dart' show SignedCatalog;
import 'diagnostics.dart' show AdapterDiagnostic, AdapterDiagnosticKind;
import 'loader.dart' show DistributionSource;
import 'revocation.dart' show SignedRevocationList;

/// 清单（catalog/revocation）字节上限：明文 JSON，1 MiB 足够（对齐 loader 解压载荷上限）。
const int kMaxDistributionManifestBytes = 1024 * 1024;

/// packed bundle 字节上限：对齐 `bundle.dart` 的 `kMaxBundleGzBytes`（512 KiB 压缩输入护栏）。
const int kMaxDistributionBundleBytes = 512 * 1024;

/// 每请求默认墙钟上限。
const Duration kDefaultDistributionTimeout = Duration(seconds: 15);

/// 极薄 HTTP GET 接缝：只把「GET 一个 https url → 有界原始字节 / null」抽象出来，便于策略层可测。
///
/// 约定：**任何**失败（网络 / 非 2xx / 超限 / 超时）→ null，绝不抛。安全护栏（无重定向 / 无凭证 /
/// TLS 校验 / 大小上限 / 超时）由实现落实（见 [IoHttpByteFetcher]）。
abstract interface class HttpByteFetcher {
  Future<Uint8List?> getBytes(
    Uri url, {
    required int maxBytes,
    required Duration timeout,
    void Function(HttpFetchFailure failure)? onFailure,
  });
}

class HttpFetchFailure {
  const HttpFetchFailure({required this.kind, this.statusCode, this.message});

  final AdapterDiagnosticKind kind;
  final int? statusCode;
  final String? message;
}

/// 生产实现：`dart:io` [HttpClient] 匿名 GET，落实全部安全护栏。
///
/// 🔒 承载「决定取哪份公网字节」的网络出口（红线 #2 零凭证面）：thin shim，逻辑最少，人工复核。
class IoHttpByteFetcher implements HttpByteFetcher {
  IoHttpByteFetcher({HttpClient? client}) : _client = client ?? HttpClient() {
    // 端点 D 零凭证：即便某处误置 cookie 也不外带。
    _client.autoUncompress = false; // bundle 是内容级 gzip；清单为明文——一律取原始字节，不让栈自解。
  }

  final HttpClient _client;

  @override
  Future<Uint8List?> getBytes(
    Uri url, {
    required int maxBytes,
    required Duration timeout,
    void Function(HttpFetchFailure failure)? onFailure,
  }) async {
    HttpClientRequest? request;
    var timedOut = false;
    void abortOnTimeout() {
      timedOut = true;
      request?.abort();
    }

    try {
      return await _get(
        url,
        maxBytes,
        timeout: timeout,
        onTimeout: abortOnTimeout,
        onRequest: (value) {
          request = value;
          // getUrl() can finish after the outer timeout callback. Abort the
          // late request as soon as the HttpClient creates it.
          if (timedOut) value.abort();
        },
        onFailure: onFailure,
      ).timeout(
        timeout,
        onTimeout: () {
          abortOnTimeout();
          // Future.timeout does not cancel its source future. Abort the
          // request explicitly, including one created after getUrl() stalls.
          throw TimeoutException('distribution request timed out', timeout);
        },
      );
    } on TimeoutException catch (e) {
      onFailure?.call(
        HttpFetchFailure(kind: AdapterDiagnosticKind.timeout, message: '$e'),
      );
      return null;
    } catch (e) {
      // 网络 / 超时 / 超限一律「本源不可用」（上层退化）；不抛、不泄错误细节。
      onFailure?.call(
        HttpFetchFailure(kind: AdapterDiagnosticKind.network, message: '$e'),
      );
      return null;
    }
  }

  Future<Uint8List?> _get(
    Uri url,
    int maxBytes, {
    required Duration timeout,
    required void Function() onTimeout,
    required void Function(HttpClientRequest request) onRequest,
    required void Function(HttpFetchFailure failure)? onFailure,
  }) async {
    final req = await _client
        .getUrl(url)
        .timeout(
          timeout,
          onTimeout: () {
            onTimeout();
            throw TimeoutException('distribution request timed out', timeout);
          },
        );
    onRequest(req);
    // 单跳、零凭证、不缓存身份：静态产物固定 URL，重定向交回中间人不可取。
    req.followRedirects = false;
    req.cookies.clear();
    final resp = await req.close();
    if (resp.statusCode != HttpStatus.ok) {
      onFailure?.call(
        HttpFetchFailure(
          kind: AdapterDiagnosticKind.httpStatus,
          statusCode: resp.statusCode,
          message: '分发端点返回非 200',
        ),
      );
      await resp.drain<void>(); // 3xx/4xx/5xx 均视为不可用；先排空连接。
      return null;
    }
    final declared = resp.contentLength;
    if (declared > maxBytes) {
      onFailure?.call(
        const HttpFetchFailure(
          kind: AdapterDiagnosticKind.sizeLimit,
          message: '响应 Content-Length 超过上限',
        ),
      );
      await resp.drain<void>();
      return null; // 声明就超限，直接弃（不下载正文）。
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        onFailure?.call(
          const HttpFetchFailure(
            kind: AdapterDiagnosticKind.sizeLimit,
            message: '响应实际大小超过上限',
          ),
        );
        req.abort();
        return null; // 边下边计数超限即弃（防未声明 content-length 的膨胀）。
      }
    }
    return builder.takeBytes();
  }

  /// 释放底层连接池。
  void close() => _client.close(force: true);
}

/// 内容寻址 digest 形态 = 64 位小写 hex（同 catalog.dart / bootstrap.dart）。
final RegExp _reDigest = RegExp(r'^[0-9a-f]{64}$');

/// 端点 D 的 [DistributionSource] 实现。构造注入 base URL（catalog/revocation/bundles 所在目录）+ 取字节接缝。
///
/// 三类产物的路径全部相对 [baseUrl]：`catalog.json.gz`、`revocation.json`、`bundles/<digest>.json.gz`。
class HttpDistributionSource implements DistributionSource {
  HttpDistributionSource({
    required Uri baseUrl,
    required HttpByteFetcher fetcher,
    Duration timeout = kDefaultDistributionTimeout,
    int maxManifestBytes = kMaxDistributionManifestBytes,
    int maxBundleBytes = kMaxDistributionBundleBytes,
    bool allowInsecureHttp = false,
    void Function(String message)? onWarning,
    void Function(AdapterDiagnostic diagnostic)? onDiagnostic,
  }) : _base = baseUrl,
       _fetcher = fetcher,
       _timeout = timeout,
       _maxManifestBytes = maxManifestBytes,
       _maxBundleBytes = maxBundleBytes,
       _allowInsecureHttp = allowInsecureHttp,
       _onWarning = onWarning,
       _onDiagnostic = onDiagnostic;

  final Uri _base;
  final HttpByteFetcher _fetcher;
  /// 见文件头「安全护栏」：仅 DEV 覆盖 base 时为 true。
  final bool _allowInsecureHttp;
  final Duration _timeout;
  final int _maxManifestBytes;
  final int _maxBundleBytes;
  final void Function(String message)? _onWarning;
  final void Function(AdapterDiagnostic diagnostic)? _onDiagnostic;

  void _diagnose(
    AdapterDiagnosticKind kind,
    String stage,
    String message, {
    Uri? uri,
    int? statusCode,
  }) {
    final diagnostic = AdapterDiagnostic(
      kind: kind,
      stage: stage,
      message: message,
      uri: uri,
      statusCode: statusCode,
    );
    _onDiagnostic?.call(diagnostic);
    _onWarning?.call(diagnostic.summary);
  }

  @override
  Future<SignedCatalog?> fetchCatalog() =>
      _fetchManifest('catalog.json.gz', SignedCatalog.fromJson);

  @override
  Future<SignedRevocationList?> fetchRevocation() =>
      _fetchManifest('revocation.json', SignedRevocationList.fromJson);

  @override
  Future<Uint8List?> fetchBundle(String digest) async {
    // digest 形态门：路径的唯一变量就是它，畸形值绝不进 URL（防 `../` 之类拼接）。
    if (!_reDigest.hasMatch(digest)) {
      _diagnose(
        AdapterDiagnosticKind.invalidUrl,
        'bundle',
        'digest 非 64 位小写 hex，拒拉：$digest',
      );
      return null;
    }
    final u = _allowedUri(_base.resolve('bundles/$digest.json.gz').toString());
    if (u == null) {
      _diagnose(
        AdapterDiagnosticKind.invalidUrl,
        'bundle',
        '分发 base URL 非 https 或畸形，拒拉：$_base',
      );
      return null;
    }
    var failed = false;
    final bytes = await _fetcher.getBytes(
      u,
      maxBytes: _maxBundleBytes,
      timeout: _timeout,
      onFailure: (failure) {
        failed = true;
        _diagnose(
          failure.kind,
          'bundle',
          failure.message ?? 'HTTP 请求失败',
          uri: u,
          statusCode: failure.statusCode,
        );
      },
    );
    if (bytes == null) {
      if (!failed) {
        _diagnose(AdapterDiagnosticKind.network, 'bundle', '未收到响应', uri: u);
      }
      return null;
    }
    // 双保险：即便注入的 fetcher 未截断，也在此复核长度（可测护栏）。
    if (bytes.length > _maxBundleBytes) {
      _diagnose(
        AdapterDiagnosticKind.sizeLimit,
        'bundle',
        '响应超大小上限，弃：$digest',
        uri: u,
      );
      return null;
    }
    return bytes;
  }

  /// 取明文 JSON 签名清单（catalog/revocation）并 parse；任何失败 → null（记遥测）。
  Future<T?> _fetchManifest<T>(
    String name,
    T Function(Map<String, dynamic>) parse,
  ) async {
    final u = _allowedUri(_base.resolve(name).toString());
    if (u == null) {
      _diagnose(
        AdapterDiagnosticKind.invalidUrl,
        name,
        '分发 base URL 非 https 或畸形，拒拉：$_base',
      );
      return null;
    }
    var failed = false;
    final bytes = await _fetcher.getBytes(
      u,
      maxBytes: _maxManifestBytes,
      timeout: _timeout,
      onFailure: (failure) {
        failed = true;
        _diagnose(
          failure.kind,
          name,
          failure.message ?? 'HTTP 请求失败',
          uri: u,
          statusCode: failure.statusCode,
        );
      },
    );
    if (bytes == null) {
      if (!failed) {
        _diagnose(AdapterDiagnosticKind.network, name, '未收到响应', uri: u);
      }
      return null;
    }
    if (bytes.length > _maxManifestBytes) {
      _diagnose(AdapterDiagnosticKind.sizeLimit, name, '响应超过大小上限，弃', uri: u);
      return null;
    }
    try {
      // The endpoint may apply HTTP Content-Encoding: gzip. The fetcher keeps
      // raw bytes so bundle payloads are not accidentally decompressed; accept
      // either representation here for catalog/revocation manifests.
      final payload = _isGzip(bytes)
          ? boundedGunzip(
              bytes,
              maxCompressedBytes: _maxManifestBytes,
              maxOutputBytes: _maxManifestBytes,
            )
          : bytes;
      final decoded = jsonDecode(utf8.decode(payload));
      if (decoded is! Map<String, dynamic>) {
        _diagnose(AdapterDiagnosticKind.parse, name, '顶层非 JSON 对象，弃', uri: u);
        return null;
      }
      return parse(decoded);
    } on BundleFormatException catch (e) {
      _diagnose(AdapterDiagnosticKind.decompression, name, '解压失败，弃：$e', uri: u);
      return null;
    } catch (e) {
      // 畸形 utf8/JSON / 缺字段（Signed*.fromJson 抛）→ 本源不可用。
      final kind = name.endsWith('.gz')
          ? AdapterDiagnosticKind.decompression
          : AdapterDiagnosticKind.parse;
      final label = kind == AdapterDiagnosticKind.decompression
          ? '解压失败'
          : '解析失败';
      _diagnose(kind, name, '$label，弃：$e', uri: u);
      return null;
    }
  }

  /// 仅接受 https 且无 userinfo 的 URL（防明文降级 + 防凭证入 URL）。[_allowInsecureHttp] 为 true
  /// 时额外放行 http（仅 DEV 覆盖 base 的本地冒烟；DEPLOY 恒 false）。
  Uri? _allowedUri(String raw) {
    final Uri u;
    try {
      u = Uri.parse(raw);
    } on FormatException {
      return null;
    }
    if (u.scheme != 'https' && !(_allowInsecureHttp && u.scheme == 'http')) {
      return null;
    }
    if (u.userInfo.isNotEmpty) return null;
    if (u.host.isEmpty) return null;
    return u;
  }

  static bool _isGzip(Uint8List bytes) =>
      bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
}
