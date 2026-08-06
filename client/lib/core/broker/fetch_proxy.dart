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
import 'harvest.dart';
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
    this.logUrl,
  });

  final String url;
  final String method;
  final Map<String, String> headers;
  final String? body;

  /// 核心预先剥除 query credential 的日志专用 URL；不得用于实际出网。
  final String? logUrl;
}

class TransportResponse {
  const TransportResponse({
    required this.status,
    this.headers = const {},
    this.setCookie = const [],
    this.location,
    this.body,
    this.decodeOk,
  });

  final int status;
  final Map<String, String> headers;

  /// origin 下发的 `Set-Cookie`（每跳，含重定向）。host 侧捕获，绝不交 adapter。
  final List<String> setCookie;

  /// 响应 `Location` 头（重定向用）；无则 null。绝不外泄给 adapter（脱敏剥除）。
  final String? location;
  final String? body;

  /// ADR-026 §2.8 A3：传输层是否确认 body 为 UTF-8 明文。生产 transport 必须给出真值；
  /// `false` 的响应只可进入 delivery firewall 并 fail-closed，不得交给 Masker 或 adapter。
  final bool? decodeOk;
}

abstract interface class Transport {
  Future<TransportResponse> fetch(
    TransportRequest req, {
    TransportCancelToken? cancelToken,
  });
}

class TransportCancelToken {
  bool _cancelled = false;
  final List<void Function()> _callbacks = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final callbacks = List<void Function()>.of(_callbacks);
    _callbacks.clear();
    for (final cb in callbacks) {
      cb();
    }
  }

  void onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
      return;
    }
    _callbacks.add(callback);
  }
}

class TransportBodyLimitException implements Exception {
  const TransportBodyLimitException(this.maxBytes);

  final int maxBytes;

  @override
  String toString() =>
      'transport response body exceeds limit ($maxBytes bytes)';
}

/// url 不在 allow → fail-closed 受控错误（绝不附凭证、绝不发请求）。
class BrokerFetchRejected implements Exception {
  const BrokerFetchRejected(this.reason);

  final String reason;

  @override
  String toString() => 'ctx.fetch 被 broker 拒绝（$reason）';
}

/// Raised by the host before a transport call when the execution-wide request
/// budget is exhausted.
class FetchRequestLimitExceeded implements Exception {
  const FetchRequestLimitExceeded();
}

/// 驱动依赖（宿主注入；凭证值仅核心可见，红线 #1）。
class FetchProxyDeps {
  const FetchProxyDeps({
    required this.view,
    required this.resolver,
    required this.jar,
    required this.transport,
    this.maxHops,
    this.cancelToken,
    this.onRedirectSettled,
    this.queryHarvest,
    this.tryReserveRequest,
    this.onRawResponse,
    this.brokerInjectHeaders,
  });

  final BrokerManifestView view;
  final CredentialResolver resolver;
  final CookieJar jar;
  final Transport transport;

  /// 单请求内最大重定向跳数（默认 5，ADR-009 §2.5）。
  final int? maxHops;

  /// 单次 ctx.fetch 的取消信号；运行时在超时/fatal 时主动中止上游。
  final TransportCancelToken? cancelToken;

  /// 🔒 **核心专用**回调：重定向链定型（deliver/stop）时回传**终点 URL**给核心。
  /// 仅宿主（核心）可设 `deps`；adapter 无法构造 [FetchProxyDeps]，故不构成对 adapter 的
  /// URL 外泄（红线 #1「中间跳转对 adapter 不可见」不变——本回调不回传中间跳，只回终点）。
  /// 供 SSO 静默换票（ADR-017 §2.2）判定是否抵达目标服务成功页。缺省 null=普通 ctx.fetch 不回传。
  final void Function(String finalUrl)? onRedirectSettled;

  /// 每个通过 allow 校验、确定跟随的重定向目标由核心收割 query credential（ADR-020 §2.3）。
  final QueryHarvestTarget? queryHarvest;

  /// Host-owned atomic reservation for one transport request.
  final bool Function()? tryReserveRequest;

  /// 🔒 **核心专用**回调：交付响应**脱敏前**回传给核心（status/头/body 原样）。
  /// 供 ADR-023 声明式数据流的 `bind` 抽取——`source: header` 须在 allowlist 脱敏前读，
  /// 否则被丢弃。**只有宿主（核心）能构造 [FetchProxyDeps]，adapter 永远拿不到本回调**，
  /// 故不构成对 adapter 的原始响应外泄（红线 #1 边界不变：交回 adapter 的仍是脱敏后响应）。
  /// 只在链路**定型**（deliver/stop，即将交付）时回传一次，不回传中间跳。缺省 null=不回传。
  final void Function(int status, Map<String, String> headers, String? body)?
  onRawResponse;

  /// 🔒 **核心专用**：broker 置入的注入请求头（ADR-023 声明式数据流 `inject at=header`）。
  /// 在 [assembleRequest] 脱敏**之后**叠加——与凭证注入同侧，故不会被 adapter 头净化剥掉，
  /// 也**不经 adapter**。只在**首跳**应用（重定向跳不回灌，同 adapter 头）。名字受
  /// [_brokerInjectHeaderForbidden] 运行期护栏（纵深防御 validator D16）：凭证头一律 fail-closed。
  /// 缺省 null=无 header 注入。
  final Map<String, String>? brokerInjectHeaders;
}

/// 🔒 broker header 注入的运行期护栏（纵深防御，红线 #1）：凭证头 / 逐跳头不得由数据流注入。
/// 与 validator D16（声明期）+ header_sanitize denylist（出站净化）三重设防；此处任一命中 →
/// fail-closed，不静默丢弃（避免给 adapter 探测护栏边界的信号，与 §2.5 错误不回流一致）。
bool _brokerInjectHeaderForbidden(String lowerName) {
  const forbidden = {
    'cookie',
    'cookie2',
    'set-cookie',
    'set-cookie2',
    'authorization',
    'proxy-authorization',
    'host',
    'content-length',
    'transfer-encoding',
    'connection',
    'keep-alive',
    'upgrade',
    'te',
    'trailer',
    'expect',
  };
  return forbidden.contains(lowerName);
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
    final resolved = decision is InjectDecision
        ? await deps.resolver.get(decision.ref)
        : null;
    final jarCookies = deps.jar.selectForSend(currentUrl);
    final assembled = assembleRequest(
      AssembleRequestInput(
        url: currentUrl,
        init: RequestInit(method: method, headers: headers, body: body),
        decision: decision,
        resolved: resolved,
        jarCookies: jarCookies,
      ),
    );
    // 拼装层也可 fail-closed：inject 但 resolver 未命中 → reject(credential_unavailable)。
    // 任一 reject 都转受控错误（绝不发请求、绝不附凭证）。
    if (assembled is RejectResult) {
      throw BrokerFetchRejected(assembled.reason);
    }
    final ok = assembled as OkResult;

    // 🔒 broker header 注入（ADR-023 inject at=header）：仅**首跳**、脱敏**后**叠加，
    // 与凭证注入同侧（不被 adapter 头净化剥掉、不经 adapter）。重定向跳不回灌。
    var outHeaders = ok.headers;
    if (hops == 0 &&
        deps.brokerInjectHeaders != null &&
        deps.brokerInjectHeaders!.isNotEmpty) {
      outHeaders = Map<String, String>.from(ok.headers);
      deps.brokerInjectHeaders!.forEach((name, value) {
        if (_brokerInjectHeaderForbidden(name.toLowerCase())) {
          // fail-closed：凭证/逐跳头一律拒（纵深防御 validator D16）。
          throw BrokerFetchRejected('inject_header_forbidden');
        }
        outHeaders[name] = value;
      });
    }

    // ④ 出网（seam）+ ⑤ 吃 Set-Cookie。
    if (deps.tryReserveRequest != null && !deps.tryReserveRequest!()) {
      throw const FetchRequestLimitExceeded();
    }
    final resp = await deps.transport.fetch(
      // query credential 即使来自独立 harvest view（SSO passthrough）也必须从日志 URL 剥离。
      TransportRequest(
        url: ok.url ?? currentUrl,
        method: ok.method,
        headers: outHeaders,
        body: ok.body,
        logUrl: _credentialSafeLogUrl(
          ok.url ?? currentUrl,
          decision,
          deps.queryHarvest?.view,
        ),
      ),
      cancelToken: deps.cancelToken,
    );
    requestCount++;
    deps.jar.captureSetCookie(resp.setCookie, currentUrl);

    // ⑥ 重定向决策（纯，复用 B3）。deliver/stop → 交付当前响应；follow → 续跳。
    final rd = decideRedirect(
      RedirectInput(
        status: resp.status,
        location: resp.location,
        currentUrl: currentUrl,
        allow: deps.view.allow,
        hopsSoFar: hops,
        maxHops: maxHops,
      ),
    );
    if (rd is DeliverDecision || rd is StopDecision) {
      // 核心专用：回传终点 URL（仅当宿主设了回调；SSO 换票据此判成功页，ADR-017 §2.2）。
      deps.onRedirectSettled?.call(currentUrl);
      // 🔒 核心专用：脱敏**前**回传原始响应给核心，供数据流 bind 抽取（header 源须在
      // allowlist 脱敏前读）。adapter 拿不到本回调；交回 adapter 的仍是下方脱敏后响应。
      deps.onRawResponse?.call(resp.status, resp.headers, resp.body);
      // ⑦ 脱敏后交回 adapter（含 stop：越界/超跳时交付当前响应，其 Location 由脱敏剥除）。
      final processed = processResponse(
        RawResponse(
          status: resp.status,
          headers: resp.headers,
          body: resp.body,
        ),
      );
      return FetchProxyOutcome(
        status: processed.status,
        headers: processed.headers,
        body: processed.body,
        requestCount: requestCount,
      );
    }

    // 续跳：307/308 保留方法+body，余者转 GET 且弃 body；重定向跳不回灌 adapter 头。
    // nextUrl 已由 decideRedirect 剥离 URL 重写会话参数（`;jsessionid=`，ADR-027）。
    final follow = rd as FollowDecision;
    final queryHarvest = deps.queryHarvest;
    if (queryHarvest != null) {
      harvestQueryUrl(follow.nextUrl, queryHarvest);
    }
    currentUrl = follow.nextUrl;
    if (follow.method == 'get') {
      method = 'GET';
      body = null;
    }
    headers = null;
    hops++;
  }
}

String? _credentialSafeLogUrl(
  String url,
  InjectionDecision decision,
  BrokerManifestView? harvestView,
) {
  var safe = url;
  var changed = false;
  if (decision is InjectDecision && decision.via == 'query') {
    safe = stripQueryParam(safe, decision.queryParam!);
    changed = true;
  }
  for (final decl
      in harvestView?.credentials.values ?? const <CredentialDecl>[]) {
    if (decl.type != 'query' || decl.queryParam == null) continue;
    final stripped = stripQueryParam(safe, decl.queryParam!);
    changed = changed || stripped != safe;
    safe = stripped;
  }
  return changed ? safe : null;
}
