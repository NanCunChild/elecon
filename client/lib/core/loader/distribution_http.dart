/// 🔒 片 F —— 公网分发端点 D 的 HTTP [DistributionSource] 实现（ADR-018 §2.6 / 端点 D，红线 #2）。
///
/// 端点 D 是**零凭证、无状态、可退化为静态 CDN** 的公网分发面（ADR-018 §2 表格 D 行）。本实现据此
/// 只做**匿名 GET** 三类静态产物，交回编排器 `loader.dart`（片 E）做全部信任裁定：
///   - `catalog.json`（明文 JSON 签名清单）→ [SignedCatalog]；
///   - `revocation.json`（明文 JSON 签名清单）→ [SignedRevocationList]；
///   - catalog entry 指定 url 的 packed bundle（`gzip(JSON({envelope,signature}))`，`.json.gz`）→ 原始字节
///     （**不在此解 gzip/解包**——loader 的 `unpackBundle` 带压缩炸弹护栏，本层只搬字节）。
///
/// **本层零信任裁定**：返回的 Signed* / 字节**均未验签**；验签 + 防回滚 + 吊销 + stdlibMin 全在
/// loader（每次加载重跑）。本层职责仅「安全地把公网字节取回来」。
///
/// **安全护栏（红线 #2 + DoS）**：
///   - **仅 https、无 userinfo**：拒 `http://` 与 `https://user:pass@…`（凭证绝不上网，且防明文降级）。
///   - **零凭证**：不带 cookie、不设 Authorization/自定义身份头（端点 D 根本不认凭证）。
///   - **不跟随重定向**：`followRedirects=false`，3xx 视为不可用——静态产物住固定 URL；跟随重定向会把
///     「取哪份字节」交给中间人（内容寻址 + 验签仍兜底，但宁可 fail-closed 不给中间人腾挪空间）。
///   - **不关 TLS 校验**：用 OS/Dart TLS 栈正常校验（ADR-009：禁 verify=False）。
///   - **大小上限 + 超时**：清单 ≤ [kMaxDistributionManifestBytes]、bundle ≤ [kMaxDistributionBundleBytes]
///     （对齐 loader `unpackBundle` 的 gz 输入上限 512KiB），边下边计数超限即弃；每请求 [timeout] 墙钟。
///
/// **失败即「本源不可用」**：任何网络错误 / 非 2xx / 超限 / 解析失败一律返回 null（记 [_onWarning] 遥测），
/// **绝不抛给 loader**——loader 据此退化到 last-good / bootstrap，永不 fail-open（同 [DistributionSource] 合约）。
///
/// **HTTP 实现经 [HttpByteFetcher] 接缝注入**：真实 = [IoHttpByteFetcher]（`dart:io`）；测试注入假源，
/// 使 https/大小/解析等策略层无需真实 socket 即可测。
///
/// 🔒 红线 #1/#2/#4 承重件：改动须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'catalog.dart' show SignedCatalog;
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
  });
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
  }) async {
    try {
      return await _get(url, maxBytes).timeout(timeout);
    } catch (_) {
      // 网络 / 超时 / 超限一律「本源不可用」（上层退化）；不抛、不泄错误细节。
      return null;
    }
  }

  Future<Uint8List?> _get(Uri url, int maxBytes) async {
    final req = await _client.getUrl(url);
    // 单跳、零凭证、不缓存身份：静态产物固定 URL，重定向交回中间人不可取。
    req.followRedirects = false;
    req.cookies.clear();
    final resp = await req.close();
    if (resp.statusCode != HttpStatus.ok) {
      await resp.drain<void>(); // 3xx/4xx/5xx 均视为不可用；先排空连接。
      return null;
    }
    final declared = resp.contentLength;
    if (declared > maxBytes) {
      await resp.drain<void>();
      return null; // 声明就超限，直接弃（不下载正文）。
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        return null; // 边下边计数超限即弃（防未声明 content-length 的膨胀）。
      }
    }
    return builder.takeBytes();
  }

  /// 释放底层连接池。
  void close() => _client.close(force: true);
}

/// 端点 D 的 [DistributionSource] 实现。构造注入 base URL（catalog/revocation 所在目录）+ 取字节接缝。
class HttpDistributionSource implements DistributionSource {
  HttpDistributionSource({
    required Uri baseUrl,
    required HttpByteFetcher fetcher,
    Duration timeout = kDefaultDistributionTimeout,
    int maxManifestBytes = kMaxDistributionManifestBytes,
    int maxBundleBytes = kMaxDistributionBundleBytes,
    void Function(String message)? onWarning,
  }) : _base = baseUrl,
       _fetcher = fetcher,
       _timeout = timeout,
       _maxManifestBytes = maxManifestBytes,
       _maxBundleBytes = maxBundleBytes,
       _onWarning = onWarning;

  final Uri _base;
  final HttpByteFetcher _fetcher;
  final Duration _timeout;
  final int _maxManifestBytes;
  final int _maxBundleBytes;
  final void Function(String message)? _onWarning;

  @override
  Future<SignedCatalog?> fetchCatalog() =>
      _fetchManifest('catalog.json', SignedCatalog.fromJson);

  @override
  Future<SignedRevocationList?> fetchRevocation() =>
      _fetchManifest('revocation.json', SignedRevocationList.fromJson);

  @override
  Future<Uint8List?> fetchBundle(String url) async {
    final u = _httpsUri(url);
    if (u == null) {
      _onWarning?.call('bundle url 非 https 或畸形，拒拉：$url');
      return null;
    }
    final bytes = await _fetcher.getBytes(
      u,
      maxBytes: _maxBundleBytes,
      timeout: _timeout,
    );
    if (bytes == null) return null; // 网络不可用 / 超限（fetcher 已隔离）。
    // 双保险：即便注入的 fetcher 未截断，也在此复核长度（可测护栏）。
    if (bytes.length > _maxBundleBytes) {
      _onWarning?.call('bundle 超大小上限，弃：$url');
      return null;
    }
    return bytes;
  }

  /// 取明文 JSON 签名清单（catalog/revocation）并 parse；任何失败 → null（记遥测）。
  Future<T?> _fetchManifest<T>(
    String name,
    T Function(Map<String, dynamic>) parse,
  ) async {
    final u = _httpsUri(_base.resolve(name).toString());
    if (u == null) {
      _onWarning?.call('分发 base URL 非 https 或畸形，拒拉 $name：$_base');
      return null;
    }
    final bytes = await _fetcher.getBytes(
      u,
      maxBytes: _maxManifestBytes,
      timeout: _timeout,
    );
    if (bytes == null) return null;
    if (bytes.length > _maxManifestBytes) {
      _onWarning?.call('$name 超大小上限，弃');
      return null;
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        _onWarning?.call('$name 顶层非 JSON 对象，弃');
        return null;
      }
      return parse(decoded);
    } catch (e) {
      // 畸形 utf8/JSON / 缺字段（Signed*.fromJson 抛）→ 本源不可用。
      _onWarning?.call('$name 解析失败，弃：$e');
      return null;
    }
  }

  /// 仅接受 https 且无 userinfo 的 URL（同 catalog.dart 对 entry.url 的立场：防明文降级 + 防凭证入 URL）。
  static Uri? _httpsUri(String raw) {
    final Uri u;
    try {
      u = Uri.parse(raw);
    } on FormatException {
      return null;
    }
    if (u.scheme != 'https') return null;
    if (u.userInfo.isNotEmpty) return null;
    if (u.host.isEmpty) return null;
    return u;
  }
}
