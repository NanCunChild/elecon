/// CAS 静默换票的 **headless 执行体**（ADR-017 §2.2 路线 b · PR-3，草案）。
///
/// 「印发」= 已握有 CAS 母凭证（CASTGC）后，对目标下游服务静默走一遍
/// `authserver/login?service=<目标>`，核心在 CAS 端点注入母凭证、跟随 `?ticket=ST` 回跳链，
/// 让下游服务签发并 `Set-Cookie` 一份新 session；「存储」= 抵达成功页后把该 session 收割入
/// 核心库（判据 b），免用户重登（ADR-017 §2.1「一次登录、按需换取下游 session」）。
///
/// **不重写注入循环**：复用已审核的 broker 出网驱动 [proxyFetch]（逐跳 `decideInjection` +
/// 自跟随重定向 + 捕获 `Set-Cookie`），保持凭证注入的**单一审计面**。母凭证经 [CredentialResolver]
/// 从核心库注入（不经 jar），ST 等中间票只在核心，adapter 全程拿不到母凭证值 / ST / Set-Cookie /
/// 带票 URL（红线 #1 等价物条款，ADR-017 §2.4）。
///
/// 注入边界（§2.4）由**声明面**保证、非本执行体自律：母凭证 ref（`role: sso-master`）的
/// scope 只覆盖 CAS 认证域，`decideInjection` 最长前缀匹配天然不会把它注入下游数据域；
/// 校验器 M4 静态拦 scope 重叠。本执行体只把 `brokerView` 原样喂给 [proxyFetch]。
///
/// 🔒 **红线 #1 最高风险面（母凭证换票）+ 协议模拟合规灰度（ADR-017 §4.1/§4.2）。**
/// 本文件由 AI 起草，**不得 AI 独自闭环**：须人工主导 + 安全清单 + ≥1 人工审后方可合并，
/// 且落地前须过合规评估（headless 属协议模拟，§2.2(b)）。**不得直接进发版二进制。**
/// （AGENTS.md §1 + ADR-017 §4.9）
library;

import '../broker/assemble.dart' show RequestInit;
import '../broker/cookie_jar.dart';
import '../broker/fetch_proxy.dart';
import '../broker/harvest.dart';
import '../broker/inject_policy.dart' show BrokerManifestView;
import '../broker/ports.dart' show CredentialResolver;
import '../credential/types.dart';
import 'sso_mint.dart';
import 'webview_login.dart' show LoginManifestView;

/// headless 静默签票执行器（ADR-017 §2.2 路线 b）。
///
/// 一个实例服务一个学校会话；每次 [mint] 用**全新** [CookieJar]（母凭证不入 jar，jar 只捕获
/// 本次下游 session → 收割视图天然只含目标 session）。
class HeadlessSsoMinter implements SsoMinter {
  HeadlessSsoMinter({
    required this.login,
    required this.brokerView,
    required this.resolver,
    required this.transport,
    required this.putCredential,
    required this.schoolId,
    this.jarFactory,
    int Function()? now,
    this.maxHops,
  }) : now = now ?? _nowMs;

  /// 登录声明面（含 `ssoMint`）：[buildMintPlan] 据此规划换票 URL / 成功检测。
  final LoginManifestView login;

  /// broker 注入 / 重定向 / 收割共享的 manifest 视图（`allow` + `credentials`，含母凭证 ref
  /// 与目标下游 ref）。**须**覆盖整条换票链（authEndpoint + service 回跳 + 成功页域）。
  final BrokerManifestView brokerView;

  /// 从核心库取母凭证值（`ids-cas` 等）；缺失/失效返回 null → [proxyFetch] fail-closed。
  final CredentialResolver resolver;

  /// 出网 seam（ADR-003）；测试注入 fake。
  final Transport transport;

  /// 把印发的下游 session 写入核心库（薄桥接到 CredentialStore.put）。
  final void Function(CredentialEntry entry) putCredential;

  final String schoolId;

  /// 单次换票的 jar 工厂（默认新建空 [CookieJar]）；测试可注入以断言捕获结果。
  final CookieJar Function()? jarFactory;

  final int Function() now;

  /// 单请求内最大重定向跳数（透传 [FetchProxyDeps.maxHops]）。
  final int? maxHops;

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// 对 [targetRef] 静默换票。返回 [MintOutcome]；非 [MintOutcome.success] 一律由**调用方**
  /// 降级到可见 WebView 登录（ADR-017 §2.2 步 4 / §2.6）。
  ///
  /// 调用方应先 `buildMintPlan(login, targetRef) != null` 才调本方法（未声明 ssoMint / 无此
  /// 服务时应直接走可见登录）；误调传入无计划的 ref → [ArgumentError]。
  /// `via != null`（adapter mint 能力：POST/body/签名，§2.2）本草案未实现 → [UnimplementedError]，
  /// 由上层显式降级，绝不静默走错路径。
  @override
  Future<MintOutcome> mint(String targetRef) async {
    final plan = buildMintPlan(login, targetRef);
    if (plan == null) {
      throw ArgumentError.value(
        targetRef,
        'targetRef',
        '无 ssoMint 声明或目标不在 services 内；调用方应先 buildMintPlan 判定并走可见登录',
      );
    }
    if (plan.via != null) {
      throw UnimplementedError(
        'adapter mint 能力（via=${plan.via}，POST/body/签名）尚未实现；请降级可见 WebView 登录',
      );
    }

    final jar = (jarFactory ?? CookieJar.new)();

    // 换票**注入视图**：只保留母凭证（`role: sso-master`）。换票链跳到下游目标域时该 session
    // 尚未印发，若沿用完整视图，`decideInjection` 会命中目标 ref 并试注入不存在的凭证 →
    // `assembleRequest` fail-closed → 换票失败。目标域须 **passthrough**（由 `?ticket=ST` 建立
    // session）。这也更紧地落实 §2.4「母凭证只注入 CAS 端点」——换票链除 CAS 域外一律不注入。
    // 收割用完整 [brokerView]（含目标 ref）以路由新 session（见下）。
    final injectView = BrokerManifestView(
      allow: brokerView.allow,
      credentials: {
        for (final e in brokerView.credentials.entries)
          if (e.value.role == 'sso-master') e.key: e.value,
      },
    );

    String? finalUrl;
    try {
      await proxyFetch(
        plan.loadUrl,
        const RequestInit(method: 'GET'),
        FetchProxyDeps(
          view: injectView,
          resolver: resolver,
          jar: jar,
          transport: transport,
          maxHops: maxHops,
          onRedirectSettled: (u) => finalUrl = u,
          queryHarvest: QueryHarvestTarget(
            view: brokerView,
            put: putCredential,
            schoolId: schoolId,
            now: now,
          ),
        ),
      );
    } on BrokerFetchRejected catch (e) {
      // 母凭证缺失/失效（credential_unavailable）→ 按母票失效处理，调用方降级可见登录；
      // 其余（outside_allow / ambiguous_scope）→ 视作越界异常边界。
      return e.reason == 'credential_unavailable'
          ? MintOutcome.tgcExpired
          : MintOutcome.blockedOutsideNav;
    }

    final outcome = classifyMintResult(
      finalUrl: finalUrl ?? plan.loadUrl,
      plan: plan,
    );
    if (outcome != MintOutcome.success) return outcome;

    // 印发成功 → 存储：把新签发的下游 session 收割入核心库（判据 b，复用 B5 桥接）。
    // 全新 jar 只含本次下游 session（母凭证不入 jar），故收割计划天然聚焦目标 session；
    // 若 CAS 期间刷新了母票（ids 域 Set-Cookie），亦一并刷新母凭证 ref（幂等、无害）。
    final harvestPlan = decideHarvest(jar.harvestView(), brokerView);
    harvestInto(
      harvestPlan,
      brokerView,
      putCredential,
      schoolId: schoolId,
      now: now,
    );
    return MintOutcome.success;
  }
}
