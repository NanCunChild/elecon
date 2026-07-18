/// 🔒🔒 official 加载许可（load grant）—— 把「验签产物」升格为「可铸 official 凭据」的**唯一闸门**。
///
/// **为何单独一层**：`verify.dart` 产出的 [VerifiedBundle] 只证明「这份 bundle 对预埋 active pin
/// 公钥验签成立、且签名档位为 official」。但 ADR-018 §2.6 的加载裁定在验签之后还有两步：
///   - 第 5 步 **吊销查询**（`isRevoked`：kill-switch / minVersion / digest / 版本区间）；
///   - 第 6 步 **stdlibMin 门**（`stdlibGate`：本端 stdlib 是否满足 adapter 声明的下限）。
/// **只有这两步也全过，才允许铸造 official 运行时凭据。** 本文件把「全过」固化成一个**不可伪造**的
/// [AdapterLoadGrant]（构造器库私有），令 `TrustedAdapterContext.official` 只需接受本类型实例即可
/// 在**编译期**确信「验签 + 吊销 + stdlibMin 全过」——无需信任调用方自觉（ADR-002 §2.6：入口安全
/// 不得依赖调用约定，要在类型层 fail-closed）。这与 `VerifiedBundle`/`VerifiedCatalog` 的不可伪造
/// 手法同构，只是把不可伪造性再向前推一格：从「验签成立」推到「门禁全过、可加载」。
///
/// **为何 grant 而非在 official 工厂里重跑门**：把门禁放在**铸造口**而非 `trusted_context.dart`，
/// 可让信任核心（trust/）不必反向依赖加载器门（revocation/stdlib_gate），避免 import 环；且门禁的
/// 输入（[VerifiedBundle]/[VerifiedRevocationList]）都不可伪造，[AdapterRef] 又**强制取自 bundle 的
/// 权威身份**（非调用方传入），故本层无法被喂入伪造前提。
///
/// 🔒 红线 #1/#4 承重件：改动须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'revocation.dart' show AdapterRef, VerifiedRevocationList, isRevoked;
import 'stdlib_gate.dart' show stdlibGate;
import 'verify.dart' show VerifiedBundle;

import 'package:elecon_contract/stdlib_version.dart' show kHostStdlibVersion;

/// 🔒 **不可伪造的 official 加载许可** —— 持有它即证「验签 + 吊销 + stdlibMin 全过」。
///
/// 构造器库私有（`._`）：只有本库的 [mintOfficialGrant] 能在门禁全过后铸造，外部（含测试）无法
/// `AdapterLoadGrant(...)` 伪造。`TrustedAdapterContext.official` 只接受本类型，故「拿到 grant」在
/// 编译期等价于「这份 bundle 已可加载」。
class AdapterLoadGrant {
  const AdapterLoadGrant._(this.bundle);

  /// 通过全部门禁的验签产物（权威身份 + pin key id + 内容寻址 digest 都在其中）。
  /// 调用方（编排器）据此拿 envelope/身份/digest；档位固定 official（验签已保证）。
  final VerifiedBundle bundle;
}

/// [mintOfficialGrant] 结果：成功携带不可伪造 [grant]；失败恒带 [reason]（门禁拒绝原因）。
class OfficialGrantResult {
  const OfficialGrantResult.ok(AdapterLoadGrant this.grant) : reason = null;
  const OfficialGrantResult.deny(String this.reason) : grant = null;

  final AdapterLoadGrant? grant;
  final String? reason;

  bool get ok => grant != null;
}

/// 🔒 **official 凭据的唯一铸造口** —— 在**不可伪造**的验签产物上跑 ADR-018 §2.6 第 5/6 步。
///
/// 顺序**不可重排**（§2.6）：先吊销、后 stdlibMin。任一步拒即 [OfficialGrantResult.deny]，绝不铸
/// grant（fail-closed）。
///
/// **[AdapterRef] 取自 [bundle] 的权威身份，不接受调用方传入**：吊销判定的 adapterId/version/digest
/// 必须是「已被签名 digest 覆盖的 manifest 身份」（[VerifiedBundle.identity]）+「已验证的内容寻址
/// digest」（[VerifiedBundle.digest]），否则调用方可传一个「假版本号」骗过 minVersion / 版本区间
/// 吊销。这落实 `isRevoked` 文档里「调用方须保证 ref 为 official-tier」的合约——本铸造口即那个
/// 「只对 official 加载路径调用 isRevoked」的强制点（评审 #4 记录的 enforcement 归属）。
///
/// 🔒 **本端 stdlib 版本固定读 [kHostStdlibVersion]（codegen 单源），不接受调用方覆盖**（评审 P1）：
/// 若把 hostStdlib 暴露成生产可传参，持有一份合法 [VerifiedBundle] 的调用方即可传一个伪造高版本
/// 绕过 stdlibMin 门。故生产铸造口无此参数；测试构造「本端过旧/够新」场景请用 [mintOfficialGrantForHost]。
OfficialGrantResult mintOfficialGrant({
  required VerifiedBundle bundle,
  required VerifiedRevocationList revocation,
}) => _mintOfficialGrant(
  bundle: bundle,
  revocation: revocation,
  hostStdlib: kHostStdlibVersion,
);

/// 🔒 **仅测试**：以 [hostStdlib] 覆盖本端版本构造 stdlibMin 门的过旧/够新场景（生产禁用；
/// [visibleForTesting] lint 兜底，生产路径固定走 [mintOfficialGrant]）。
@visibleForTesting
OfficialGrantResult mintOfficialGrantForHost({
  required VerifiedBundle bundle,
  required VerifiedRevocationList revocation,
  required String hostStdlib,
}) => _mintOfficialGrant(
  bundle: bundle,
  revocation: revocation,
  hostStdlib: hostStdlib,
);

OfficialGrantResult _mintOfficialGrant({
  required VerifiedBundle bundle,
  required VerifiedRevocationList revocation,
  required String hostStdlib,
}) {
  // §2.6 第 5 步：吊销查询。ref 一律取自 bundle 权威身份（不可被调用方伪造）。
  final ref = AdapterRef(
    adapterId: bundle.identity.adapterId,
    adapterVersion: bundle.identity.adapterVersion,
    digest: bundle.digest,
  );
  final rev = isRevoked(revocation, ref);
  if (!rev.allowed) {
    return OfficialGrantResult.deny('吊销拒绝：${rev.reason}');
  }

  // §2.6 第 6 步：stdlibMin 门。
  final gate = stdlibGate(bundle, hostStdlib: hostStdlib);
  if (!gate.allowed) {
    return OfficialGrantResult.deny('stdlibMin 门拒绝：${gate.reason}');
  }

  // 全过 → 铸造不可伪造许可。
  return OfficialGrantResult.ok(AdapterLoadGrant._(bundle));
}
