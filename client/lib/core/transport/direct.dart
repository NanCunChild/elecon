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
///  - **证明响应头原始基数（P1-04）**：`HttpHeaders.forEach` 给出折叠前的 `List<String>`，
///    故记录出现 ≥2 次的头名并置 `headerCardinalityAttested=true`；Masker 据此对
///    「两个同名 token 头」fail-closed。服务端 TS 传输在 WHATWG `Headers` 下**无法**证明，
///    恒 `false`（见 `server/src/runtime/transport/direct.ts`）——这是两端的已知能力差。
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
import '../debug/dev_log.dart';

const int defaultMaxBodyBytes = 8 * 1024 * 1024;

class DirectTransport implements Transport {
  DirectTransport({HttpClient? client, this.maxBodyBytes = defaultMaxBodyBytes})
      : _client = client ?? HttpClient();

  final HttpClient _client;
  final int maxBodyBytes;

  @override
  Future<TransportResponse> fetch(TransportRequest req,
      {TransportCancelToken? cancelToken}) async {
    try {
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

      final bytes = await _collectBytes(response, maxBodyBytes, cancelToken);
      final decoded = decodeBodyA3(
        bytes,
        response.headers.contentType?.charset,
      );

      // 原始 Set-Cookie（多条）单独交回——由 B4 jar 捕获，绝不并入普通头、绝不交 adapter。
      final setCookie = <String>[];
      final headers = <String, String>{};
      // **P1-04 原始基数**：`HttpHeaders.forEach` 逐名给出**折叠前**的 `List<String>`，
      // 故客户端能证明「这个头在线上出现了几次」。记下 ≥2 次的名字交给 Masker——
      // 交付前它据此对 header 源规则 `capture_ambiguous` fail-closed，绝不收割合并值。
      final repeatedHeaders = <String>[];
      response.headers.forEach((name, values) {
        if (name.toLowerCase() == 'set-cookie') {
          setCookie.addAll(values);
          return;
        }
        if (values.length > 1) repeatedHeaders.add(name.toLowerCase());
        // 多值头折叠为逗号连接（HttpHeaders 已小写化 name；broker 脱敏大小写不敏感）。
        headers[name] = values.join(', ');
      });

      // 仅无参 URL + 状态码；不记 header/body（红线 #1）。
      DevLog.instance.network(
        method: req.method,
        url: req.logUrl ?? req.url,
        statusCode: response.statusCode,
        ok: true,
      );

      return TransportResponse(
        status: response.statusCode,
        headers: headers,
        setCookie: setCookie,
        location: response.headers.value('location'),
        body: decoded.body,
        decodeOk: decoded.decodeOk,
        repeatedHeaders: repeatedHeaders,
        // 上面的 forEach 走遍了全部头名，故本次基数是**完整可证明**的（P1-04）。
        headerCardinalityAttested: true,
      );
    } catch (e) {
      DevLog.instance.network(
        method: req.method,
        url: req.logUrl ?? req.url,
        ok: false,
        error: e.runtimeType.toString(),
      );
      rethrow;
    }
  }

  /// ADR-026 §2.8 A3：只确认 UTF-8 / ASCII 系；非 UTF-8 charset 不猜测转码，非法字节标失败。
  static ({String body, bool decodeOk}) decodeBodyA3(
    List<int> bytes,
    String? charset,
  ) {
    final normalized = charset?.trim().toLowerCase();
    final isUtf8 =
        normalized == null ||
        normalized == 'utf-8' ||
        normalized == 'utf8' ||
        normalized == 'us-ascii' ||
        normalized == 'ascii';
    if (!isUtf8) {
      return (body: utf8.decode(bytes, allowMalformed: true), decodeOk: false);
    }
    try {
      return (body: utf8.decode(bytes), decodeOk: true);
    } on FormatException {
      return (body: utf8.decode(bytes, allowMalformed: true), decodeOk: false);
    }
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
