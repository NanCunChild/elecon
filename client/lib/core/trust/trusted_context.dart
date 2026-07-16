/// 信任裁定上下文 —— fetch 运行时的强制入场凭据（ADR-002 §2.6 运行时闸门）。
///
/// 立场（#79 P0-1）：`runFetchAdapter` 是凭证注入的入口，其安全性不得依赖
/// 「上层不要误调用」的调用约定，而要在可信核心边界 fail-closed——入口强制
/// 接收本类型实例，而本类型**只能经核心的信任裁定路径构造**：
///
///  - **official**：由核心验签 + 完整加载门禁裁定（ADR-002 §2.3 验签 → §2.4 吊销 →
///    由签名裁定档位；ADR-018 §2.6 还含 `stdlibMin` 门）。**当前仍无 official 构造
///    路径**——`core/loader/verify.dart` 已能验签并产出**不可伪造**的 `VerifiedBundle`
///    （其构造器库私有），但把 `VerifiedBundle` 铸造成 official 凭据的那一步**刻意留到
///    编排器（`core/loader/loader.dart`，待落地）**——因为铸造前必须先过吊销 + `stdlibMin`
///    门（§2.6 第 5/6 步）。**在那套门禁齐备前开放铸造即是 fail-open**，故本轮不开。
///    release 下 fetch 模式因此整体 fail-closed，这正是门禁就位前的正确状态。
///  - **devSideload**：dev 侧载例外（ADR-002 §2.5，红线 #5 dev 例外）。
///    仅 debug build 存在：[kDebugMode] 为编译期常量，release/profile 下
///    工厂首行恒抛、其余代码作为死代码被剔除——「允许侧载注入」的分支在
///    release 二进制里不存在（红线 #4 同构手法）。
///
/// 纵深防御（ADR-002 §2.6：运行时不信任上游）：即便持有本类型实例，
/// `runFetchAdapter` 入口仍以 [fetchTrustPermitted] 复核档位 × build 模式。
///
/// 🔒 红线 #1 凭证路径承重件：改动本文件须人工 + 安全清单复核，不得 AI 独自闭环。
library;

import 'package:flutter/foundation.dart' show kDebugMode;

/// 宿主裁定的 adapter 信任档（ADR-002 §2.1 两档制）。
///
/// 权威档位来自核心对签名的验证，**不信任 manifest 自报**（§2.2）。
enum AdapterTrustTier {
  /// 官方签名 adapter：核心验签通过、未被吊销。唯一可在 release 跑 fetch 的档。
  official,

  /// dev 侧载（无签名）：仅 debug build 可构造/可跑 fetch（§2.5 owner 决策）。
  devSideload,
}

/// 经核心信任裁定后签发的执行凭据。构造器私有——拿到实例即意味着
/// 已走过某条裁定路径（验签 official，或 debug-only 的 dev 侧载确认）。
class TrustedAdapterContext {
  const TrustedAdapterContext._(this.tier);

  /// 宿主裁定的档位（非 adapter 自报）。
  final AdapterTrustTier tier;

  /// dev 侧载裁定（ADR-002 §2.5）：开发者在 debug build 显式确认加载无签名
  /// fetch adapter 后由核心调用。**仅 debug build 存在**——[kDebugMode] 是
  /// 编译期常量，release/profile 下首行恒抛 [StateError]、返回分支被死代码
  /// 剔除；调用方的警告 UI 与本调用同属 debug-only 条件编译。
  factory TrustedAdapterContext.devSideload() {
    if (!kDebugMode) {
      throw StateError(
          'dev 侧载信任上下文仅 debug build 存在（红线 #4/#5，ADR-002 §2.5）');
    }
    return const TrustedAdapterContext._(AdapterTrustTier.devSideload);
  }

  // official 构造路径**尚未开放**（见类文档）：验签器已能产出不可伪造的
  // `VerifiedBundle`，但铸造 official 凭据须先过吊销 + stdlibMin 门（ADR-018 §2.6），
  // 由待落地的编排器承担。在那之前不提供 official 工厂——fail-closed。
  //
  // 🔒 红线 #1：将来新增 official 工厂时，其入参必须是**不可伪造**的验签+门禁产物
  //    （非裸字符串/裸枚举），且须人工 + 安全清单复核。
}

/// fetch 运行时入场判定（纯函数，负例可测）：official 一律放行；
/// devSideload 仅 debug build 放行；其余 fail-closed。
///
/// 生产接线固定为 `debugBuild: kDebugMode`（`runFetchAdapter` 入口），
/// 本函数把判定逻辑与编译期常量解耦，使 release 语义可被单测覆盖。
///
/// **穷尽 switch（不设 default）是刻意的**（2026-07-16 收紧）：原实现
/// `tier == official || debugBuild` 会在 debug 下**放行任何 tier**——将来新增枚举值
/// 会被静默允许。改为逐档裁定后，新增枚举值会让本函数**编译不过**，强制显式决策，
/// 杜绝"默默放行"。对现有两档行为完全不变。
bool fetchTrustPermitted(AdapterTrustTier tier, {required bool debugBuild}) {
  switch (tier) {
    case AdapterTrustTier.official:
      return true; // official 一律放行（唯一可在 release 跑 fetch 的档）
    case AdapterTrustTier.devSideload:
      return debugBuild; // 侧载仅 debug；release/profile 下 fail-closed
  }
}
