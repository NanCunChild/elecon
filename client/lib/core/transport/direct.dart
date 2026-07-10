/// `direct` 档传输（Gate A · ADR-003 §2.2）—— OS 网络栈直连、无隧道、不终止 TLS。
///
/// 填 broker 的 `Transport` seam（`fetch_proxy.dart`）：把**已注入凭证的真实请求**
/// （ADR-009 §2.1 第 3 步，凭证由 broker 在 HTTP 语义层注入）送达 origin 并回传字节。
/// transport **只搬字节**——不解析、不碰 schema、不持凭证语义（ADR-003 §2.1）。
///
/// 关键约束：
///  - **单跳**：`followRedirects=false`——重定向由核心（B3 `decideRedirect`）逐跳跟随、
///    每跳重做注入决策 + 校验 allow + 捕获 Set-Cookie；transport 绝不自动跟随（否则中间
///    `Location`/Set-Cookie 绕过核心，破红线 #1）。
///  - **不终止 / 不 MITM TLS**（ADR-003 §2.3）：用 OS/Dart TLS 栈正常握手到 origin，
///    **不**关闭证书校验、不注入根证书（ADR-009：TLS 必须校验，禁 verify=False）。
///  - **暴露原始 Set-Cookie / Location**：交回宿主 jar（B4）与重定向逻辑（B3）；
///    响应脱敏（B2 allowlist）由 broker 在交回 adapter 前完成，不在 transport。
///
/// 生命周期（ADR-003 §2.1）对 `direct` 平凡：始终「connected」（无隧道）。仅暴露 `fetch`
/// + `close`（释放底层连接池）。
///
/// 🔒 承载注入凭证的真实请求（红线 #1/#4 路径，最低信任档但仍在凭证路径）：
/// AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'dart:convert';
import 'dart:io';

import '../broker/fetch_proxy.dart'
    show
        Transport,
        TransportBodyLimitException,
        TransportCancelToken,
        TransportRequest,
        TransportResponse;

const int defaultMaxBodyBytes = 8 * 1024 * 1024;

class DirectTransport implements Transport {
  DirectTransport({HttpClient? client, this.maxBodyBytes = defaultMaxBodyBytes})
      : _client = client ?? HttpClient();

  final HttpClient _client;
  final int maxBodyBytes;

  @override
  Future<TransportResponse> fetch(TransportRequest req,
      {TransportCancelToken? cancelToken}) async {
    final request = await _client.openUrl(req.method, Uri.parse(req.url));
    cancelToken?.onCancel(() => request.abort());
    if (cancelToken?.isCancelled ?? false) {
      request.abort();
      throw const HttpException('transport request cancelled');
    }

    // 单跳：核心自跟随重定向（B3），transport 不自动跟随。
    request.followRedirects = false;

    // 设出站头（broker 已注入凭证 + B2 净化）。HttpClient 会自管 host/content-length。
    req.headers.forEach(request.headers.set);

    if (req.body != null) {
      request.add(utf8.encode(req.body!));
    }

    final response = await request.close();
    if (cancelToken?.isCancelled ?? false) {
      throw const HttpException('transport request cancelled');
    }

    // body：按 UTF-8 解析（allowMalformed 防异常）。**已知限制**：非 UTF-8（如 GBK）页面会乱码，
    // 待后续按 Content-Type charset 解码（多数 .do/JSON 端点为 UTF-8）。
    final bytes = await _collectBytes(response, maxBodyBytes, cancelToken);
    final body = utf8.decode(bytes, allowMalformed: true);

    // 原始 Set-Cookie（多条）单独交回——由 B4 jar 捕获，绝不并入普通头、绝不交 adapter。
    final setCookie = <String>[];
    final headers = <String, String>{};
    response.headers.forEach((name, values) {
      if (name.toLowerCase() == 'set-cookie') {
        setCookie.addAll(values);
        return;
      }
      // 多值头折叠为逗号连接（HttpHeaders 已小写化 name；broker 脱敏大小写不敏感）。
      headers[name] = values.join(', ');
    });

    return TransportResponse(
      status: response.statusCode,
      headers: headers,
      setCookie: setCookie,
      location: response.headers.value('location'),
      body: body,
    );
  }

  /// 释放底层连接池。
  void close() => _client.close(force: true);

  static Future<List<int>> _collectBytes(
    HttpClientResponse response,
    int maxBytes,
    TransportCancelToken? cancelToken,
  ) async {
    final declared = response.contentLength;
    if (declared > maxBytes) {
      throw TransportBodyLimitException(maxBytes);
    }
    final chunks = <int>[];
    await for (final chunk in response) {
      if (cancelToken?.isCancelled ?? false) {
        throw const HttpException('transport request cancelled');
      }
      chunks.addAll(chunk);
      if (chunks.length > maxBytes) {
        throw TransportBodyLimitException(maxBytes);
      }
    }
    return chunks;
  }
}
