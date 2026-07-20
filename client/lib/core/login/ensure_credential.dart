/// 能力执行前的凭证就绪闸门（ADR-017 / mint 闭环 §4.2–4.3）。
///
/// 在 `SessionController.runCapability` 调 adapter **之前**串行 ensure 所需 ref：
///   1. store 已有 active → ready；
///   2. 有 `ssoMint` 计划 + 母票 + [SsoMinter] → 静默 mint，成功后再校验 has；
///   3. 否则 / mint 失败 → 可见登录回调；仍缺 → needVisibleLogin / failed。
///
/// 🔒 本文件**不接触凭证值**：只调 hasActive / hasSsoMaster（元数据）与 [SsoMinter.mint]
/// （执行体内闭包取值，红线 #1）。AI 起草编排，mint 执行体与 store 写路径须人工审。
library;

import 'sso_mint.dart';
import 'webview_login.dart';

/// 单 ref 的纯决策（无 I/O），便于单测与日志。
enum EnsureAction {
  /// store 已有 active 目标 ref。
  alreadyReady,

  /// 有 mint 计划且有母票 → 尝试静默换票。
  tryMint,

  /// 缺目标且无可用静默路径 → 可见登录。
  visibleLogin,
}

/// 据「是否已有目标 / 是否有 mint 声明 / 是否有母票」裁定动作（纯）。
EnsureAction decideEnsureAction({
  required bool hasTarget,
  required bool hasMintPlan,
  required bool hasMaster,
}) {
  if (hasTarget) return EnsureAction.alreadyReady;
  if (hasMintPlan && hasMaster) return EnsureAction.tryMint;
  return EnsureAction.visibleLogin;
}

enum EnsureCredentialStatus {
  /// 所需 ref 均已 active，可继续 runCapability。
  ready,

  /// 需要用户可见登录（无回调或回调后仍缺凭证）；UI 应引导重登。
  needVisibleLogin,

  /// 用户取消 / 登录失败 / 其它不可恢复错误。
  failed,
}

/// 一次 ensure 结果。
class EnsureCredentialResult {
  const EnsureCredentialResult.ready()
      : status = EnsureCredentialStatus.ready,
        reason = null,
        targetRef = null;

  const EnsureCredentialResult.needVisibleLogin({
    this.reason = '需要登录',
    this.targetRef,
  }) : status = EnsureCredentialStatus.needVisibleLogin;

  const EnsureCredentialResult.failed(this.reason, {this.targetRef})
      : status = EnsureCredentialStatus.failed;

  final EnsureCredentialStatus status;
  final String? reason;

  /// 触发闸门的目标 ref（便于 UI / 诊断）。
  final String? targetRef;

  bool get isReady => status == EnsureCredentialStatus.ready;
}

/// 可见登录请求（**无凭证值**）。[serviceUrl] 可选，来自 mint 声明的目标 service。
class VisibleLoginRequest {
  const VisibleLoginRequest({
    required this.schoolId,
    required this.reason,
    this.targetRef,
    this.serviceUrl,
  });

  final String schoolId;
  final String reason;
  final String? targetRef;

  /// 目标服务 URL（mint 声明的 service）；可见登录可深链，缺省用学校默认 login.url。
  final String? serviceUrl;
}

/// 对单个 [ref] 执行 ensure 阶梯（mint 闭环 §4.2 伪码）。
///
/// [hasActive] / [hasSsoMaster] 为 store 侧元数据查询闭包；[minter] 缺省 = 跳过 L1；
/// [onVisibleLogin] 缺省 = 直接返回 needVisibleLogin（由 UI 层另启登录）。
Future<EnsureCredentialResult> ensureCredential({
  required String schoolId,
  required String ref,
  required bool Function(String schoolId, String ref) hasActive,
  required bool Function(String schoolId) hasSsoMaster,
  required LoginManifestView login,
  SsoMinter? minter,
  Future<bool> Function(VisibleLoginRequest request)? onVisibleLogin,
}) async {
  if (hasActive(schoolId, ref)) {
    return const EnsureCredentialResult.ready();
  }

  final plan = buildMintPlan(login, ref);
  final serviceUrl = login.ssoMint?.services[ref]?.service;
  final action = decideEnsureAction(
    hasTarget: false,
    hasMintPlan: plan != null,
    hasMaster: hasSsoMaster(schoolId),
  );

  if (action == EnsureAction.tryMint && minter != null) {
    final outcome = await minter.mint(ref);
    if (outcome == MintOutcome.success && hasActive(schoolId, ref)) {
      return const EnsureCredentialResult.ready();
    }
    final mintReason = switch (outcome) {
      MintOutcome.success => '换票完成但未收割到 $ref',
      MintOutcome.tgcExpired => '母凭证失效，请重新登录',
      MintOutcome.blockedOutsideNav => '换票被拦截，请重新登录',
    };
    return _visibleLoginStep(
      schoolId: schoolId,
      ref: ref,
      hasActive: hasActive,
      reason: mintReason,
      serviceUrl: serviceUrl,
      onVisibleLogin: onVisibleLogin,
    );
  }

  final reason = plan == null
      ? '需要登录以获取 $ref'
      : (minter == null
          ? '静默换票未装配，需要登录'
          : '需要登录以获取 $ref');
  return _visibleLoginStep(
    schoolId: schoolId,
    ref: ref,
    hasActive: hasActive,
    reason: reason,
    serviceUrl: serviceUrl,
    onVisibleLogin: onVisibleLogin,
  );
}

Future<EnsureCredentialResult> _visibleLoginStep({
  required String schoolId,
  required String ref,
  required bool Function(String schoolId, String ref) hasActive,
  required String reason,
  required String? serviceUrl,
  required Future<bool> Function(VisibleLoginRequest request)? onVisibleLogin,
}) async {
  if (onVisibleLogin == null) {
    return EnsureCredentialResult.needVisibleLogin(
      reason: reason,
      targetRef: ref,
    );
  }
  final ok = await onVisibleLogin(
    VisibleLoginRequest(
      schoolId: schoolId,
      reason: reason,
      targetRef: ref,
      serviceUrl: serviceUrl,
    ),
  );
  if (!ok) {
    return EnsureCredentialResult.failed('登录取消或失败', targetRef: ref);
  }
  if (hasActive(schoolId, ref)) {
    return const EnsureCredentialResult.ready();
  }
  return EnsureCredentialResult.needVisibleLogin(
    reason: '登录后仍缺少 $ref',
    targetRef: ref,
  );
}

/// 串行 ensure 一组 refs；任一非 ready 即短路返回（mint 闭环 §4.3）。
Future<EnsureCredentialResult> ensureCredentials({
  required String schoolId,
  required List<String> refs,
  required bool Function(String schoolId, String ref) hasActive,
  required bool Function(String schoolId) hasSsoMaster,
  required LoginManifestView login,
  SsoMinter? minter,
  Future<bool> Function(VisibleLoginRequest request)? onVisibleLogin,
}) async {
  for (final ref in refs) {
    final r = await ensureCredential(
      schoolId: schoolId,
      ref: ref,
      hasActive: hasActive,
      hasSsoMaster: hasSsoMaster,
      login: login,
      minter: minter,
      onVisibleLogin: onVisibleLogin,
    );
    if (!r.isReady) return r;
  }
  return const EnsureCredentialResult.ready();
}
