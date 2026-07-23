/// 核心代取 declarative 请求（delivery A2）—— ADR-001 §6.2 / 红线 #5 / ADR-022。
///
/// declarative capability **无网络**：宿主据 manifest `capabilities[].requests[]` 出网代取，
/// 经 broker（allow 闸门 / 可选凭证注入 / 重定向自跟随 / 响应脱敏）后，按 `key`
/// 组装 `responses` 喂 declarative 入口。凭证值永不进 adapter（红线 #1）。
///
/// 公开能力（如 `school-xidian` `notice.list`）无 `credential` → passthrough。
/// 文件/API 名可暂留 parser_*（实现语义 = declarative 代取）。
library;

import 'broker/assemble.dart' show RequestInit;
import 'broker/cookie_jar.dart' show CookieJar;
import 'broker/fetch_proxy.dart'
    show
        BrokerFetchRejected,
        FetchProxyDeps,
        FetchRequestLimitExceeded,
        Transport,
        TransportBodyLimitException,
        proxyFetch;
import 'broker/inject_policy.dart'
    show
        BrokerManifestView,
        InjectDecision,
        InjectionDecision,
        decideInjection;
import 'broker/ports.dart' show CredentialResolver;

/// manifest `capabilities[].requests[]` 一项（运行时已 fail-closed 校验形状）。
class ParserRequestDecl {
  const ParserRequestDecl({
    required this.key,
    required this.method,
    required this.url,
    this.credential,
  });

  final String key;
  final String method;
  final String url;
  final String? credential;
}

/// 代取期 fail-closed（URL 展开 / broker 拒绝 / 网络 / 限额）。
class ParserHostException implements Exception {
  const ParserHostException(this.message, {this.limitExceeded = false});

  final String message;
  final bool limitExceeded;

  @override
  String toString() => 'ParserHostException: $message';
}

/// 将 URL 模板中的 `{param}` 替换为 [params] 值（值做 URI 组件编码）。
String expandRequestUrl(String template, Map<String, dynamic> params) {
  return template.replaceAllMapped(RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\}'), (
    m,
  ) {
    final name = m.group(1)!;
    final v = params[name];
    if (v == null) {
      throw FormatException('parser request URL 缺参数 {$name}');
    }
    if (v is! String && v is! num && v is! bool) {
      throw FormatException('parser request URL 参数 {$name} 类型非法');
    }
    return Uri.encodeComponent('$v');
  });
}

/// 对 [requests] 逐条代取，返回 `key → {status, headers, body}`（已脱敏）。
Future<Map<String, dynamic>> fulfillParserRequests({
  required List<ParserRequestDecl> requests,
  required Map<String, dynamic> params,
  required BrokerManifestView view,
  required CredentialResolver resolver,
  required Transport transport,
  CookieJar? jar,
  int maxRequests = 20,
}) async {
  final out = <String, dynamic>{};
  final effectiveJar = jar ?? CookieJar();
  var used = 0;

  for (final req in requests) {
    final String url;
    try {
      url = expandRequestUrl(req.url, params);
    } on FormatException catch (e) {
      throw ParserHostException('parser 代取 URL 展开失败：${e.message}');
    }

    final decision = decideInjection(url, view);
    _assertCredentialPolicy(req, decision);

    if (used >= maxRequests) {
      throw const ParserHostException(
        'parser 代取超过单次执行请求上限',
        limitExceeded: true,
      );
    }

    try {
      final outcome = await proxyFetch(
        url,
        RequestInit(method: req.method),
        FetchProxyDeps(
          view: view,
          resolver: resolver,
          jar: effectiveJar,
          transport: transport,
          tryReserveRequest: () {
            if (used >= maxRequests) return false;
            used++;
            return true;
          },
        ),
      );
      out[req.key] = <String, dynamic>{
        'status': outcome.status,
        'headers': outcome.headers,
        if (outcome.body != null) 'body': outcome.body,
      };
    } on BrokerFetchRejected catch (e) {
      throw ParserHostException('parser 代取被拒绝：${e.reason}');
    } on FetchRequestLimitExceeded {
      throw const ParserHostException(
        'parser 代取超过单次执行请求上限',
        limitExceeded: true,
      );
    } on TransportBodyLimitException catch (e) {
      throw ParserHostException(
        'parser 代取响应体超限（${e.maxBytes} bytes）',
      );
    } catch (e) {
      if (e is ParserHostException) rethrow;
      throw ParserHostException('parser 代取网络失败：$e');
    }
  }

  return out;
}

void _assertCredentialPolicy(
  ParserRequestDecl req,
  InjectionDecision decision,
) {
  final want = req.credential;
  if (want == null || want.isEmpty) {
    // 未声明 credential 的请求：注入决策**不得**命中任何凭证。否则展开后的 URL 恰落在某
    // 凭证 scope 时会被 broker 静默注入，令 `requests[].credential` 字段失去可审计性
    // （审阅者读 manifest 会误判"无字段=不带凭证"）。fail-closed：强制每条带凭证的请求
    // 都在 manifest 里显式声明——`credential` 字段双向权威（红线 #1 可审计面）。
    if (decision is InjectDecision) {
      throw ParserHostException(
        'parser 请求未声明 credential，但 URL 命中凭证注入 ref=${decision.ref}'
        '（须在 requests[].credential 显式声明）→ fail-closed',
      );
    }
    return;
  }
  if (decision is! InjectDecision) {
    throw ParserHostException(
      'parser 请求 credential=$want 但注入决策非 inject（${decision.toJson()}）',
    );
  }
  if (decision.ref != want) {
    throw ParserHostException(
      'parser 请求 credential=$want 与注入决策 ref=${decision.ref} 不符',
    );
  }
}
