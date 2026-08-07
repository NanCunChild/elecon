/// Broker 重定向核心跟随（Dart 侧，Gate A · B3）—— ADR-009 §2.1 第 3 步 / §2.5。
///
/// 与 TS 侧 `server/src/runtime/broker/redirect.ts` **语义逐字对齐**，`decideRedirect`
/// 由 `contract/golden/broker/redirect.json` 共享向量钉死两端一致（ADR-001 §8）。
///
/// 核心**自行**跟随重定向；adapter 全程**看不到中间跳转**：
///   - **每跳须仍在 `network.allow` 内**，越界即安全拒绝，当前响应不可交付（ADR-009 §2.5；
///     中间 Location 可能含 token，跟随或交付都会扩大数据外泄面，红线 #1）。
///   - **最多 `maxHops` 跳**（默认 5）；超限即安全拒绝。
///   - **中间 Location 绝不外泄**：driver 只返回**最终**响应；`FollowOutcome` 结构上无
///     location 字段。
///
/// `decideRedirect` 纯（golden 双跑）；`followRedirects` 异步驱动，经注入 `RedirectFetcher`
/// （真实发请求属 B6/transport）跟随。
///
/// 🔒 红线 #1 数据外泄面：AI 起草，须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'url_match.dart';

/// 自动跟随的重定向状态码（300/304/305/306 不在内）。
const Set<int> _redirectStatuses = {301, 302, 303, 307, 308};

/// URL 重写的会话矩阵参数 `;jsessionid=…`（ADR-027）。跟随前剥离：
///   1. **红线 #1**：会话令牌在 URL 里 = 数据外泄面（Referer/日志/历史泄漏）；
///   2. **正确性**：带 `;jsessionid=` 跟随会命中 Tomcat URL-rewrite 分支、不下发 cookie
///      会话，导致后续 clean-URL 请求丢会话（ehall jwapp 403）。剥离后落到干净 URL
///      触发 `Set-Cookie`，会话回归 CookieJar（核心持有，adapter 全程不见）。
/// 只匹配矩阵参数形态（分号前缀），不动查询串 `?jsessionid=`。
final RegExp _urlRewrittenSessionParam = RegExp(
  r';jsessionid=[^/?#;]*',
  caseSensitive: false,
);

/// 默认最大跳数（ADR-009 §2.5）。
const int defaultMaxRedirects = 5;

/// `decideRedirect` 入参。
class RedirectInput {
  const RedirectInput({
    required this.status,
    required this.location,
    required this.currentUrl,
    required this.allow,
    required this.hopsSoFar,
    required this.maxHops,
  });

  final int status;

  /// 响应的 Location 头；无则 null。
  final String? location;

  /// 当前请求 URL（用于解析相对 Location）。
  final String currentUrl;
  final List<String> allow;

  /// 已跟随的跳数。
  final int hopsSoFar;
  final int maxHops;
}

/// 单跳重定向决策。`toJson()` 与 golden `expected` 同形，供双跑断言。
sealed class RedirectDecision {
  const RedirectDecision();

  Map<String, Object?> toJson();
}

/// 非重定向 / 无 Location → 当前即最终响应，交付 adapter。
class DeliverDecision extends RedirectDecision {
  const DeliverDecision();

  @override
  Map<String, Object?> toJson() => {'kind': 'deliver'};
}

/// 跟随到 nextUrl（已解析为绝对、已过 allow 校验）。`method` ∈ {`preserve`, `get`}。
class FollowDecision extends RedirectDecision {
  const FollowDecision({required this.nextUrl, required this.method});

  final String nextUrl;
  final String method;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'follow',
    'nextUrl': nextUrl,
    'method': method,
  };
}

/// 想跟随但被安全策略拦截 → 整次 fetch 拒绝，当前响应不可交付。
/// `reason` ∈ {`max_hops`, `outside_allow`, `unresolvable_location`}。
class BlockedDecision extends RedirectDecision {
  const BlockedDecision(this.reason);

  final String reason;

  @override
  Map<String, Object?> toJson() => {'kind': 'blocked', 'reason': reason};
}

/// 单跳重定向决策（纯函数）。
///
/// 顺序：非重定向/Location null 或空→deliver；超跳数→blocked(max_hops)；
/// 非空 Location 不可解析→blocked；解析后越 allow→blocked(outside_allow)；否则 follow。
RedirectDecision decideRedirect(RedirectInput input) {
  final status = input.status;
  final location = input.location;

  if (!_redirectStatuses.contains(status) ||
      location == null ||
      location == '') {
    return const DeliverDecision();
  }
  if (input.hopsSoFar >= input.maxHops) {
    return const BlockedDecision('max_hops');
  }

  final String nextUrl;
  try {
    final resolved = Uri.parse(input.currentUrl).resolve(location);
    if (resolved.scheme.isEmpty || resolved.host.isEmpty) {
      return const BlockedDecision('unresolvable_location');
    }
    // ADR-027：剥离 URL 重写会话参数（在 allow 校验前，使校验作用于干净 URL）。
    nextUrl = resolved.toString().replaceAll(_urlRewrittenSessionParam, '');
  } catch (_) {
    return const BlockedDecision('unresolvable_location');
  }

  if (!urlCoveredByAllow(nextUrl, input.allow)) {
    return const BlockedDecision('outside_allow');
  }

  final method = status == 307 || status == 308 ? 'preserve' : 'get';
  return FollowDecision(nextUrl: nextUrl, method: method);
}

/// 单跳取数结果（driver 内部用；真实实现属 B6/transport）。
class RedirectHop {
  const RedirectHop({required this.status, required this.location});

  final int status;
  final String? location;
}

/// 发一跳请求的 seam。`method`：`initial`=首跳用原方法；`preserve`/`get`=重定向后的方法。
abstract class RedirectFetcher {
  Future<RedirectHop> fetch(String url, String method);
}

/// 跟随结果。blocked 分支在类型上不携带响应 status/body/header/Location，避免未来误交付。
sealed class FollowOutcome {
  const FollowOutcome({required this.hops});

  final int hops;
}

class DeliverFollowOutcome extends FollowOutcome {
  const DeliverFollowOutcome({
    required this.finalUrl,
    required this.status,
    required super.hops,
  });

  final String finalUrl;
  final int status;
}

class BlockedFollowOutcome extends FollowOutcome {
  const BlockedFollowOutcome({required this.reason, required super.hops});

  final String reason;
}

/// 核心自跟随重定向（异步驱动）。只返回**最终**响应的元信息；中间响应/Location 丢弃。
Future<FollowOutcome> followRedirects(
  String startUrl,
  RedirectFetcher fetcher, {
  required List<String> allow,
  int? maxHops,
}) async {
  final mh = maxHops ?? defaultMaxRedirects;
  var url = startUrl;
  var hops = 0;
  var method = 'initial';

  while (true) {
    final hop = await fetcher.fetch(url, method);
    final decision = decideRedirect(
      RedirectInput(
        status: hop.status,
        location: hop.location,
        currentUrl: url,
        allow: allow,
        hopsSoFar: hops,
        maxHops: mh,
      ),
    );

    if (decision is DeliverDecision) {
      return DeliverFollowOutcome(
        finalUrl: url,
        status: hop.status,
        hops: hops,
      );
    }
    if (decision is BlockedDecision) {
      return BlockedFollowOutcome(reason: decision.reason, hops: hops);
    }

    final follow = decision as FollowDecision;
    url = follow.nextUrl;
    method = follow.method;
    hops++;
  }
}
