/// 信任裁定上下文 —— imperative 运行时的强制入场凭据（ADR-002 §2.6 运行时闸门）。
///
/// 立场（#79 P0-1）：`runImperativeAdapter` 是凭证注入的入口，其安全性不得依赖
/// 「上层不要误调用」的调用约定，而要在可信核心边界 fail-closed——入口强制
/// 接收本类型实例，而本类型**只能经核心的信任裁定路径构造**：
///
///  - **official**：由核心验签 + 完整加载门禁裁定（ADR-002 §2.3 验签 → §2.4 吊销 →
///    由签名裁定档位；ADR-018 §2.6 还含 `stdlibMin` 门）。构造路径**已就位**
///    （2026-07-17）：`core/loader/verify.dart` 验签产出不可伪造 `VerifiedBundle` →
///    `core/loader/load_grant.dart` 的 `mintOfficialGrant` 再过吊销 + `stdlibMin` 门
///    （§2.6 第 5/6 步）铸造不可伪造 `AdapterLoadGrant` → 本文件 [TrustedAdapterContext.official]
///    接受该 grant 签发 official 凭据。编排全序在 `core/loader/loader.dart`。
///    **official 凭据携带不可伪造的 adapterId/adapterVersion/digest**（取自 grant 的验签产物），
///    使其**绑定到具体 bundle**而非一张通用 bearer 票——上层运行前须核对将执行的 bundle 与本凭据
///    的 [digest] 一致（评审 #2，见下方字段文档）。
///  - **devSideload**：dev 侧载例外（ADR-002 §2.5，红线 #5 dev 例外）。
///    仅 **DEV 信任 profile** 存在：[kSideloadEnabled] 为编译期常量，DEPLOY 下
///    工厂首行恒抛、其余代码作为死代码被剔除——「允许侧载注入」的分支在
///    DEPLOY 产物里不存在（红线 #4 同构手法）。
///
/// **判别器换位（ADR-024，2026-08-07 落地）**：侧载判别器由 [kDebugMode]（优化等级）
/// 改挂 [kSideloadEnabled]（`--dart-define=ELECON_TRUST_PROFILE=dev-sideload`）。
/// 语义与手法完全同构（编译期常量 + tree-shake），只是把「是否含侧载入口」从
/// 「是否优化」这根正交轴上解绑：社区 adapter 开发者可拿 `--release` 的性能 + 侧载。
///
/// 换位丢掉的自动正确性由 ADR-024 §2.3 四护栏补：① fail-closed 默认 DEPLOY
/// （见 `trust_profile.dart`）；② 编译期剔除而非运行时开关；③ DEV 独立
/// applicationId 后缀 + 启动页水印（`android/app/build.gradle.kts`、
/// `ui/security/dev_sideload_banner.dart`）；④ `tool/check_release_gate.sh` 机械断言。
///
/// **传输底座不受影响**（ADR-024 §2.4）：dev 传输看全部流量，风险量级更高，
/// 恒 [kDebugMode]-only，本次换位不碰。
///
/// 纵深防御（ADR-002 §2.6：运行时不信任上游）：即便持有本类型实例，
/// `runImperativeAdapter` 入口仍以 [fetchTrustPermitted] 复核档位 × 侧载 profile。
///
/// 🔒 红线 #1/#4 凭证与信任判别承重件：改动本文件须人工 + 安全清单复核，不得 AI 独自闭环。
library;

import 'package:flutter/foundation.dart' show kDebugMode;

import '../loader/load_grant.dart' show AdapterLoadGrant;
import 'trust_profile.dart' show kSideloadEnabled, kSideloadEntryMarker;

/// 宿主裁定的 adapter 信任档（ADR-002 §2.1 两档制）。
///
/// 权威档位来自核心对签名的验证，**不信任 manifest 自报**（§2.2）。
enum AdapterTrustTier {
  /// 官方签名 adapter：核心验签通过、未被吊销。唯一可在 release 跑 imperative 的档。
  official,

  /// dev 侧载（无签名）：仅 debug build 可构造/可跑 imperative（§2.5 owner 决策）。
  devSideload,
}

/// 经核心信任裁定后签发的执行凭据。构造器私有——拿到实例即意味着
/// 已走过某条裁定路径（验签 official，或 debug-only 的 dev 侧载确认）。
class TrustedAdapterContext {
  const TrustedAdapterContext._(
    this.tier, {
    this.adapterId,
    this.adapterVersion,
    this.digest,
  });

  /// 宿主裁定的档位（非 adapter 自报）。
  final AdapterTrustTier tier;

  /// 🔒 **本凭据绑定的 adapter 权威身份 / 内容寻址 digest**（评审 #2）。
  ///
  /// **official 恒非空**：取自不可伪造的 [AdapterLoadGrant]（其内 `VerifiedBundle.identity` 来自
  /// 签名覆盖的 manifest、`digest` 为已验证内容寻址），故这三值不可被调用方伪造。它们把 official 凭据
  /// **钉死到某一具体 bundle**，使其不再是「拿到任意 official 票即可跑任意 source」的通用 bearer 票。
  ///
  /// **devSideload 为 null**（无签名 bundle，无权威身份可绑）。
  ///
  /// **上层绑定合约（🔒 必须遵守）**：`runImperativeAdapter` 的调用方（片 G 接线）在运行前须确认「将要执行的
  /// adapter 源码就是本凭据 [digest] 所指的那一份」——例如源码取自同一次 `AdapterLoader.loadAdapter`
  /// 返回的 envelope。把「凭据」与「要跑的字节」的一致性核对留在接线层，因 `runImperativeAdapter` 只收源码
  /// 字符串、拿不到 envelope 无法自算 digest；本字段是那道核对的**数据来源**。
  final String? adapterId;
  final String? adapterVersion;
  final String? digest;

  /// dev 侧载裁定（ADR-002 §2.5 · 判别器见 ADR-024）：开发者在 **DEV profile** 构建里
  /// 显式确认加载无签名 imperative adapter 后由核心调用。**仅 DEV profile 存在**——
  /// [kSideloadEnabled] 是编译期常量，DEPLOY 下首行恒抛 [StateError]、返回分支被死代码
  /// 剔除；调用方的警告 UI 与本调用同属 profile 条件编译。
  ///
  /// 抛出的信息里带 [kSideloadEntryMarker]：DEPLOY 产物中本函数被整体剔除后该字面量
  /// 随之消失，`tool/check_release_gate.sh` 的符号 grep（护栏 4a）据此判「侧载入口
  /// 确实不在产物里」。**不要改写或拼接这个常量**——gate 靠它是字面量才能命中。
  factory TrustedAdapterContext.devSideload() {
    if (!kSideloadEnabled) {
      throw StateError(
        'dev 侧载信任上下文仅 DEV profile 存在（红线 #4/#5，ADR-002 §2.5 / ADR-024）'
        ' [$kSideloadEntryMarker]',
      );
    }
    return const TrustedAdapterContext._(AdapterTrustTier.devSideload);
  }

  /// 🔒 **official 裁定**（ADR-018 §2.6，红线 #1/#4）：核心验签 + 吊销 + stdlibMin 全过后签发。
  ///
  /// **入参是不可伪造的门禁产物**：[AdapterLoadGrant] 的构造器库私有于 `core/loader/load_grant.dart`，
  /// 只有该库的 `mintOfficialGrant` 能在「验签成立（含档位=official）+ 未被吊销 + 本端 stdlib 满足
  /// 下限」**全过**后铸造。故本工厂**只需接受一个 grant 实例**即在编译期确信门禁全过——不重复裁定，
  /// 也不接受裸字符串/裸枚举（§2.6：入口安全不得依赖调用方自觉，要在类型层 fail-closed）。
  ///
  /// **凭据绑定到具体 bundle（评审 #2）**：从 grant 的验签产物取**不可伪造**的
  /// adapterId/adapterVersion/digest 存入凭据（见 [adapterId] 字段文档），使 official 凭据不再是通用
  /// bearer 票。这些值来自 grant.bundle（已验签、已过门），调用方无法伪造。
  ///
  /// **无 build 模式闸门**：official 是唯一可在 release 跑 imperative 的档（见 [fetchTrustPermitted]），
  /// 故此处不设 [kDebugMode] 守卫（与 [devSideload] 相反）。纵深防御仍在 `runImperativeAdapter` 入口
  /// 以 [fetchTrustPermitted] 复核。
  factory TrustedAdapterContext.official(AdapterLoadGrant grant) {
    // grant 不可伪造 → 门禁全过。把其验签产物的权威身份/digest 绑进凭据（评审 #2），
    // 裁定本身已在 mintOfficialGrant 完成（类型即证据）。
    final b = grant.bundle;
    return TrustedAdapterContext._(
      AdapterTrustTier.official,
      adapterId: b.identity.adapterId,
      adapterVersion: b.identity.adapterVersion,
      digest: b.digest,
    );
  }
}

/// imperative 运行时入场判定（纯函数，负例可测）：official 一律放行；
/// devSideload 仅 **DEV 信任 profile** 放行；其余 fail-closed。
///
/// 生产接线固定为 `sideloadEnabled: kSideloadEnabled`（`runImperativeAdapter` 入口），
/// 本函数把判定逻辑与编译期常量解耦，使 DEPLOY 语义可被单测覆盖。
///
/// **参数由 `debugBuild` 改名为 [sideloadEnabled]（ADR-024）**：改名不是修辞——旧名会
/// 诱导调用方继续传 `kDebugMode`，而判别器已换成信任 profile；同名不同义是最容易
/// 悄悄接错的一类改动，故连名字一起换掉。
///
/// **穷尽 switch（不设 default）是刻意的**（2026-07-16 收紧）：原实现
/// `tier == official || debugBuild` 会在 debug 下**放行任何 tier**——将来新增枚举值
/// 会被静默允许。改为逐档裁定后，新增枚举值会让本函数**编译不过**，强制显式决策，
/// 杜绝"默默放行"。对现有两档行为完全不变。
bool fetchTrustPermitted(
  AdapterTrustTier tier, {
  required bool sideloadEnabled,
}) {
  switch (tier) {
    case AdapterTrustTier.official:
      return true; // official 一律放行（唯一可在 DEPLOY 跑 imperative 的档）
    case AdapterTrustTier.devSideload:
      return sideloadEnabled; // 侧载仅 DEV profile；DEPLOY 下 fail-closed
  }
}
