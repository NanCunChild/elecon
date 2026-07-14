/// CAS 静默签票——纯规划 + 判定逻辑 + 执行器接口（ADR-017 §2.2 / PR-3，草案）。
///
/// 「静默签票」= 已握有 CAS 母凭证（CASTGC）后，对目标下游服务静默走一遍
/// `authserver/login?service=<目标>`，跟随 ticket 回跳链收割该服务 session，
/// 免用户重登（ADR-017 §2.1「一次登录、按需换取下游 session」）。
///
/// 🔒 红线 #1：本文件只放**纯逻辑**（规划 mint 请求、判定结果、定义执行器接口）。
/// 真正**驱动换票的执行器**（隐藏/离屏 WebView 或 headless + Broker 注入母凭证 +
/// 跟随 ST 回跳 + 收割）触碰凭证注入与中间票，是**人工主导 PR**（红线 #1，需真机）；
/// AI 只起草接口与纯逻辑，不实现执行体（AGENTS.md §1）。
library;

import '../broker/url_match.dart';
import 'webview_login.dart';

/// 一次静默换票的规划（纯数据）：加载哪个 URL、导航边界、成功检测、承载方式。
class MintPlan {
  const MintPlan({
    required this.targetRef,
    required this.loadUrl,
    required this.navigationAllow,
    required this.successMatches,
    this.via,
  });

  final String targetRef;

  /// authEndpoint 填入目标 service 后的加载起点（母凭证注入端点，ADR-017 §2.4）。
  final String loadUrl;

  final List<String> navigationAllow;
  final List<String> successMatches;

  /// null=内置 GET-redirect；非 null=交 adapter mint 能力构造请求（ADR-017 §2.2）。
  final String? via;
}

/// 据 manifest 为目标 ref 规划一次静默换票；未声明 ssoMint / 无此服务 → null
/// （调用方退化到可见 WebView 登录，ADR-017 §2.6）。
MintPlan? buildMintPlan(LoginManifestView login, String targetRef) {
  final mint = login.ssoMint;
  if (mint == null) return null;
  final svc = mint.services[targetRef];
  if (svc == null) return null;
  final loadUrl = mint.authEndpoint.replaceAll(
    '{service}',
    Uri.encodeComponent(svc.service),
  );
  return MintPlan(
    targetRef: targetRef,
    loadUrl: loadUrl,
    navigationAllow: login.navigationAllow,
    successMatches: svc.success,
    via: svc.via,
  );
}

/// 静默换票结果。非 [success] 一律降级到可见 WebView 登录（ADR-017 §2.2 步 4 / §2.6）。
enum MintOutcome {
  /// 抵达目标服务成功页 → 已收割目标 session。
  success,

  /// 在 navAllow 内但未达成功页——多为 CASTGC 失效弹回登录页（§4.3 母票失效）。
  tgcExpired,

  /// 导航越出 navAllow（异常/被拦）。
  blockedOutsideNav,
}

/// 据换票终点 URL 判定结果（纯）。
MintOutcome classifyMintResult({
  required String finalUrl,
  required MintPlan plan,
}) {
  if (plan.successMatches.any((p) => scopeMatches(finalUrl, p))) {
    return MintOutcome.success;
  }
  if (!urlCoveredByAllow(finalUrl, plan.navigationAllow)) {
    return MintOutcome.blockedOutsideNav;
  }
  return MintOutcome.tgcExpired;
}

/// 静默签票执行器接口（ADR-017 §2.2）。给定目标 ref → 用母凭证驱动换票、收割目标
/// session、返回结果。
///
/// 🔒 实现是**人工主导 PR**（红线 #1，需真机）：隐藏/离屏 WebView 或 headless 加载
/// [MintPlan.loadUrl]、Broker 按 §2.4 只对 CAS 端点注入母凭证、跟随 ST 回跳（中间票只在
/// 核心）、抵达成功页收割目标 session（判据 b）。失败（[MintOutcome.tgcExpired] 等）→
/// 调用方降级可见 WebView 登录。adapter 全程拿不到母凭证值 / ST（红线 #1 等价物条款）。
abstract interface class SsoMinter {
  Future<MintOutcome> mint(String targetRef);
}
