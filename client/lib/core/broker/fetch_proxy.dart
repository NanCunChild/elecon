/// 受限 `ctx.fetch` 代理驱动（Gate A · B6b-Dart 的拼装驱动镜像）—— ADR-009 §2.1。
///
/// 与 TS 侧 `server/src/runtime/broker/fetch-proxy.ts` **语义逐字对齐**：把已落地纯零件
/// （B1 decideInjection / resolver / B4 jar.selectForSend / B6a assembleRequest / B3 decideRedirect）
/// 串成一次真正可跑的出站请求 + 核心自跟随重定向。运行时不可纯 golden 化（计划 §2），由
/// `broker_fetch_proxy_test.dart` 用 fake Transport 驱动集成。
///
/// 流程逐跳：① decideInjection（reject→fail-closed / passthrough / inject）② resolver.get + jar.selectForSend
/// ③ assembleRequest（净化→叠 broker 凭证→合流 jar cookie）④ transport.fetch ⑤ jar.captureSetCookie
/// ⑥ decideRedirect 自驱（每跳重做 ①–⑤；中间 Location 绝不外泄）⑦ processResponse 脱敏交回 adapter。
///
/// **复用纯函数 decideRedirect 自驱**而非 followRedirects（后者只回元信息、不带 body、不逐跳重做
/// 决策 + 捕获 Set-Cookie），与 TS 一致。限额计量口径（计划 §8 #3）：每跳各计一次请求（requestCount，
/// 含重定向跳）；单请求 10s（含重定向链）与累计 30s/≤20 的硬执行属运行时（adapter_runtime.dart）。
///
/// 🔒 红线 #1 凭证注入 + 出网承重路径：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'assemble.dart';
import 'cookie_jar.dart';
import 'inject_policy.dart';
import 'ports.dart';
import 'redirect.dart';

/// 统一 transport seam（复用 B3 RedirectFetcher 思路）。真实出网属 ADR-003，另件注入；测试用 fake。
class TransportRequest {
  const TransportRequest({
    required this.url,
    required this.method,
    required this.headers,
    this.body,
  });

  final String url;
  final String method;
  final Map<String, String> headers;
  final String? body;
}

class TransportResponse {
  const TransportResponse({
    required this.status,
    this.headers = const {},
    this.setCookie = const [],
    this.location,
    this.body,
  });

  final int status;
  final Map<String, String> headers;

  /// origin 下发的 `Set-Cookie`（每跳，含重定向）。host 侧捕获，绝不交 adapter。
  final List<String> setCookie;

  /// 响应 `Location` 头（重定向用）；无则 null。绝不外泄给 adapter（脱敏剥除）。
  final String? location;
  final String? body;
}

abstract interface class Transport {
  Future<TransportResponse> fetch(TransportRequest req);
}

/// url 不在 allow → fail-closed 受控错误（绝不附凭证、绝不发请求）。
class BrokerFetchRejected implements Exception {
  const BrokerFetchRejected(this.reason);

  final String reason;

  @override
  String toString() => 'ctx.fetch 被 broker 拒绝（$reason）';
}

/// 驱动依赖（宿主注入；凭证值仅核心可见，红线 #1）。
class FetchProxyDeps {
  const FetchProxyDeps({
    required this.view,
    required this.resolver,
    required this.jar,
    required this.transport,
    this.maxHops,
  });

  final BrokerManifestView view;
  final CredentialResolver resolver;
  final CookieJar jar;
  final Transport transport;

  /// 单请求内最大重定向跳数（默认 5，ADR-009 §2.5）。
  final int? maxHops;
}

/// 一次 ctx.fetch 的脱敏后产出 + 请求计量。
class FetchProxyOutcome {
  const FetchProxyOutcome({
    required this.status,
    required this.headers,
    this.body,
    required this.requestCount,
  });

  final int status;
  final Map<String, String> headers;
  final String? body;

  /// 实际 transport.fetch 调用次数（含重定向跳）；运行时据此累加 ≤20 执行预算（计划 §8 #3）。
  final int requestCount;
}

/// 驱动一次 `ctx.fetch(url, init)`。reject → 抛 [BrokerFetchRejected]（fail-closed）。
/// 重定向由核心自跟随（每跳重做注入决策 + 捕获 Set-Cookie + allow 校验）；交回 adapter 的
/// 响应已脱敏（Set-Cookie/Authorization/Location 剥除），中间跳转对 adapter 全程不可见。
Future<FetchProxyOutcome> proxyFetch(
  String url,
  RequestInit init,
  FetchProxyDeps deps,
) async {
  final maxHops = deps.maxHops ?? defaultMaxRedirects;

  var currentUrl = url;
  var method = (init.method ?? 'GET').toUpperCase();
  String? body = init.body;
  // 仅首跳带 adapter 自设头/body；重定向跳由核心控制，不回灌 adapter 头（防中间态外泄）。
  Map<String, String>? headers = init.headers;
  var hops = 0;
  var requestCount = 0;

  for (;;) {
    // ①–③ 每跳重做注入决策 + 取值 + 选 jar cookie + 拼装（每跳须仍在 allow 内，由 ① 守）。
    final decision = decideInjection(currentUrl, deps.view);
    if (decision is RejectDecision) {
      throw BrokerFetchRejected(decision.reason);
    }
    final resolved =
        decision is InjectDecision ? await deps.resolver.get(decision.ref) : null;
    final jarCookies = deps.jar.selectForSend(currentUrl);
    final assembled = assembleRequest(AssembleRequestInput(
      init: RequestInit(method: method, headers: headers, body: body),
      decision: decision,
      resolved: resolved,
      jarCookies: jarCookies,
    ));
    // 拼装层也可 fail-closed：inject 但 resolver 未命中 → reject(credential_unavailable)。
    // 任一 reject 都转受控错误（绝不发请求、绝不附凭证）。
    if (assembled is RejectResult) {
      throw BrokerFetchRejected(assembled.reason);
    }
    final ok = assembled as OkResult;

    // ④ 出网（seam）+ ⑤ 吃 Set-Cookie。
    final resp = await deps.transport.fetch(TransportRequest(
      url: currentUrl,
      method: ok.method,
      headers: ok.headers,
      body: ok.body,
    ));
    requestCount++;
    deps.jar.captureSetCookie(resp.setCookie, currentUrl);

    // ⑥ 重定向决策（纯，复用 B3）。deliver/stop → 交付当前响应；follow → 续跳。
    final rd = decideRedirect(RedirectInput(
      status: resp.status,
      location: resp.location,
      currentUrl: currentUrl,
      allow: deps.view.allow,
      hopsSoFar: hops,
      maxHops: maxHops,
    ));
    if (rd is DeliverDecision || rd is StopDecision) {
      // ⑦ 脱敏后交回 adapter（含 stop：越界/超跳时交付当前响应，其 Location 由脱敏剥除）。
      final processed = processResponse(
        RawResponse(status: resp.status, headers: resp.headers, body: resp.body),
      );
      return FetchProxyOutcome(
        status: processed.status,
        headers: processed.headers,
        body: processed.body,
        requestCount: requestCount,
      );
    }

    // 续跳：307/308 保留方法+body，余者转 GET 且弃 body；重定向跳不回灌 adapter 头。
    final follow = rd as FollowDecision;
    currentUrl = follow.nextUrl;
    if (follow.method == 'get') {
      method = 'GET';
      body = null;
    }
    headers = null;
    hops++;
  }
}
