/// 🔒 stdlibMin 门 —— 客户端加载裁定的一环（ADR-018 §2.6 第 6 步，红线 #4）。
///
/// adapter 的 bundle manifest 用 `runtime.stdlibMin` 声明「至少需要 elecon:html stdlib 此版本」；
/// 本端随 app 打包的 stdlib 版本是 [kHostStdlibVersion]（契约单源 `adapters/_stdlib/package.json`，
/// 与 server 双端锁步）。规则：**本端 stdlib < stdlibMin → fail-closed 拒载**（提示需升级 app）。
/// stdlib 走 append-only + semver：高版本恒能跑低版本声明的 adapter，故只需比下限。
///
/// **只收 [VerifiedBundle]**（已验签证据，构造器库私有）：stdlibMin 取自 digest 覆盖的 manifest，
/// 在验签管线里被捕获进 [VerifiedBundle.stdlibMin]，令未验签内容无法进入本裁定。这与
/// `isRevoked` 只收 `VerifiedRevocationList`、`catalogFresh` 只收 `VerifiedCatalog` 同构。
///
/// **allow ≠ 完成加载**：加载还需吊销查询（`isRevoked`）等其余门，由编排器 `loader.dart`（片 E）
/// 串联。本文件只回答「本端 stdlib 是否够新」。
///
/// 🔒 改动须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'package:elecon_contract/stdlib_version.dart' show kHostStdlibVersion;

import 'verify.dart' show VerifiedBundle;

/// x.y.z 形态（镜像 contract manifest.schema 的 `runtime.stdlibMin` pattern）。
final RegExp _reStdlibVersion = RegExp(r'^\d+\.\d+\.\d+$');

/// stdlibMin 门裁定结果。[allowed]=false 时 [reason] 说明原因。
class StdlibGateDecision {
  const StdlibGateDecision.allow() : allowed = true, reason = null;
  const StdlibGateDecision.deny(String this.reason) : allowed = false;
  final bool allowed;
  final String? reason;
}

/// 🔒 stdlibMin 门：本端 stdlib 是否满足 [verified] 声明的最低版本。**fail toward less trust**。
///
/// - `verified.stdlibMin == null`（未声明下限）→ 放行。
/// - 本端 stdlib < stdlibMin → 拒（需升级 app）。
/// - 否则放行。
///
/// [hostStdlib] 默认 [kHostStdlibVersion]（**生产恒用默认值**）；命名可选参数仅供测试构造
/// 「本端过旧 / 恰好 / 够新」三侧场景，生产代码不要传。
StdlibGateDecision stdlibGate(
  VerifiedBundle verified, {
  String hostStdlib = kHostStdlibVersion,
}) {
  final min = verified.stdlibMin;
  if (min == null) return const StdlibGateDecision.allow();
  // 防御：本端版本常量理应恒为 x.y.z（codegen 已从 package.json 校验）；万一被改坏则 fail-closed，
  // 不拿一个无法比较的本端版本去放行。
  if (!_reStdlibVersion.hasMatch(hostStdlib)) {
    return StdlibGateDecision.deny('本端 stdlib 版本 $hostStdlib 非 x.y.z → fail-closed');
  }
  // min 已在验签时（readEnvelopeStdlibMin）校验为 x.y.z，此处直接比较。
  if (_compareSemver(hostStdlib, min) < 0) {
    return StdlibGateDecision.deny(
      '本端 stdlib $hostStdlib 低于 adapter 要求的 $min → 需升级 app（fail-closed）',
    );
  }
  return const StdlibGateDecision.allow();
}

/// 极简 x.y.z 比较（无界十进制段：去前导零 → 比长度 → 等长字典序，不转 int 免溢出）。
/// 与 `revocation.dart` 的 `compareSemver` 同实现——loader 落地（片 E）时抽到共享 validators
/// （评审 #6：现三处镜像，改一处漏一处即客户端契约行为漂移）。
int _compareSemver(String a, String b) {
  final pa = a.split('.');
  final pb = b.split('.');
  for (var i = 0; i < 3; i++) {
    final na = _stripLeadingZeros(pa[i]);
    final nb = _stripLeadingZeros(pb[i]);
    if (na.length != nb.length) return na.length < nb.length ? -1 : 1;
    final c = na.compareTo(nb);
    if (c != 0) return c;
  }
  return 0;
}

String _stripLeadingZeros(String s) {
  var i = 0;
  while (i < s.length - 1 && s.codeUnitAt(i) == 0x30 /* '0' */) {
    i++;
  }
  return s.substring(i);
}
