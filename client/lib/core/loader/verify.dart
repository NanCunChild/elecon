/// 🔒🔒 bundle 验签 —— 客户端信任裁定的**承重路径**（红线 #4：仅官方签名加载）。
///
/// 镜像 `tools/src/bundle/package.ts` 的 `verifyBundleSignature`，并对齐 tools 层
/// `VerifyResult<T>` 约定：**失败恒带 reason；成功携带已验证产物**——调用方只能经
/// 成功分支拿到裁定档位，拿不到未验证的数据。
///
/// **本文件回答的问题**：这份 envelope + 签名，对预埋 pin 公钥是否成立？成立则得什么档位？
/// **本文件不回答**：要不要加载（还差吊销查询 + stdlibMin 门 + 缓存/原子落地，
/// 见 ADR-018 §2.6 的完整 fail-closed 顺序，由上层编排）。
///
/// 校验顺序（**不可重排**，每步都是前一步的前提）：
///   1. **算法** —— 只认 ed25519，不做任何回退/协商（防降级）。
///   2. **envelope 格式** —— bundleFormat 已知。
///   3. **内容寻址 digest** —— 重算 envelope digest 与签名声明比对。
///      先于验签：便宜、且把"验的字节"钉死为"要用的字节"。
///   4. **身份核对** —— 签名声明身份 == envelope 内 manifest.json（ADR-002 §2.2）。
///   5. **公钥** —— keyId 必须命中**预埋且 active** 的信任锚。
///   6. **Ed25519 验签**。
///   7. 全过 → 由**签名**裁定档位（非 manifest 自报）。
///
/// 🔒 改动须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'package:cryptography/cryptography.dart'
    show Ed25519, KeyPairType, Signature, SimplePublicKey;
// visibleForTesting 经 flutter/foundation 重导出——避免为一个注解声明 package:meta。
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'bundle.dart';
import 'signature.dart';
import 'trust_anchors.dart';

/// 验签结果。镜像 tools 的 `VerifyResult<T>`：失败恒带 [reason]，成功才有 [value]。
class VerifyResult<T> {
  const VerifyResult.ok(T this.value) : reason = null;
  const VerifyResult.fail(String this.reason) : value = null;

  final T? value;
  final String? reason;

  bool get ok => reason == null;
}

/// 🔒 **验签通过的证据（un-forgeable capability）** —— 已核对的权威身份 + pin key id + digest。
///
/// **构造器库私有（`._`）**：只有本库（`verify.dart`）能造，且只在完整验签管线全过后造。
/// 故"持有一个 [VerifiedBundle]"在**编译期**即等价于"这份 bundle 对某把预埋 active pin 公钥
/// 验签成立"——任何外部代码（含测试）都无法 `VerifiedBundle(...)` 伪造出来。这正是把
/// `TrustedAdapterContext` 私有构造器的不可伪造性延伸到验签产物上（ADR-002 §2.6：入口安全
/// 不得依赖"调用方不要误用"，而要在类型层面 fail-closed）。
///
/// **持有它 ≠ 可加载**：它只证明"验签成立"。要不要加载还差吊销查询 + `stdlibMin` 门
/// （ADR-018 §2.6 第 5/6 步），由编排器在此之后做——编排器过完门禁才铸造 official 凭据。
///
/// [tier] 不设字段：验签只为 official 服务（sideload/未知在第 7 步即拒），故存在即 official。
class VerifiedBundle {
  const VerifiedBundle._({
    required this.identity,
    required this.keyId,
    required this.digest,
    required this.stdlibMin,
  });

  /// 已核对的权威身份（取自 envelope 内 manifest，非签名自报）。
  final EnvelopeIdentity identity;

  /// 验签命中的预埋 active pin key id。
  final String keyId;

  /// 已核实的内容寻址 digest —— 上层用它做内容寻址缓存 key（ADR-018 §2.6）。
  final String digest;

  /// adapter 声明的 elecon:html stdlib 最低版本（manifest.runtime.stdlibMin，x.y.z）；
  /// `null` = 未声明下限。**在验签时从 digest 覆盖的 manifest 捕获**（权威值，非 catalog 提示），
  /// 供 stdlibMin 门（`stdlib_gate.dart`）裁定，见 ADR-018 §2.6 第 6 步。
  final String? stdlibMin;
}

/// keyId → 信任锚的解析器。生产恒为 [activeAnchorByKeyId]（只认预埋 active 集合）。
typedef AnchorResolver = TrustAnchor? Function(String keyId);

/// 🔒 **生产入口**：对 envelope + detached 签名验签，针对**预埋且 active** 的 pin 公钥。
///
/// 只在**全部**校验通过时返回 [VerifiedBundle]；任一步失败即 [VerifyResult.fail]（fail-closed）。
Future<VerifyResult<VerifiedBundle>> verifyBundleSignature(
  BundleEnvelope env,
  SignatureFile signature,
) =>
    verifyBundleSignatureWith(env, signature, activeAnchorByKeyId);

/// 验签管线本体，公钥来源经 [resolveAnchor] 注入。
///
/// **为何把"解析公钥"做成接缝，而不是直接传公钥**：信任根必须是编译期常量集合
/// （[kTrustAnchors]），不可运行时替换——若本函数收 `publicKey` 参数，任何调用方都能
/// 拿任意公钥验签，pin 就形同虚设。收 resolver 则保留了"keyId 必须命中预埋 active 锚"
/// 这一步语义，生产唯一实参是 [activeAnchorByKeyId]。
///
/// [visibleForTesting]：测试用 golden 的**测试**公钥跑同一条管线（生产预埋集里当然没有它）。
/// **生产代码不得调用本函数**——请用 [verifyBundleSignature]。
@visibleForTesting
Future<VerifyResult<VerifiedBundle>> verifyBundleSignatureWith(
  BundleEnvelope env,
  SignatureFile signature,
  AnchorResolver resolveAnchor,
) async {
  // 1. 算法：只认 ed25519。不做回退，不按"签名文件说什么就用什么"选算法。
  if (signature.algorithm != 'ed25519') {
    return VerifyResult.fail('不支持的签名算法：${signature.algorithm} → fail-closed');
  }

  // 2. envelope 格式。
  if (env.bundleFormat != kBundleFormat) {
    return VerifyResult.fail(
      '未知 bundleFormat：${env.bundleFormat}（期望 $kBundleFormat）→ fail-closed',
    );
  }

  // 3. 内容寻址 digest：重算并比对。这一步把"下面要验的字节"钉死成"上层将要执行的字节"。
  final String digest;
  try {
    digest = envelopeDigest(env);
  } on BundleFormatException catch (e) {
    return VerifyResult.fail('envelope 无法解码：${e.message} → fail-closed');
  }
  if (digest != signature.digest) {
    return VerifyResult.fail(
      'digest 不符：算得 ${_short(digest)} 期望 ${_short(signature.digest)} → fail-closed',
    );
  }

  // 4. 身份核对（ADR-002 §2.2）：digest 只绑定**内容**；签名载荷里的身份是**另一维**。
  //    不核对则「内容 A / 身份 B」的签名可验过，而运行时用的是 envelope 内 manifest
  //    （它决定 allow / credentials 注入范围）→ 身份混淆。
  final EnvelopeIdentity identity;
  try {
    identity = readEnvelopeIdentity(env);
  } on BundleFormatException catch (e) {
    return VerifyResult.fail('${e.message} → fail-closed');
  }
  if (signature.adapterId != identity.adapterId ||
      signature.adapterVersion != identity.adapterVersion) {
    return VerifyResult.fail(
      '签名身份与 envelope 内 manifest 不符'
      '（签名 ${signature.adapterId}@${signature.adapterVersion} vs '
      'manifest ${identity.adapterId}@${identity.adapterVersion}）→ fail-closed（ADR-002 §2.2）',
    );
  }

  // 4b. 捕获权威 stdlibMin（manifest.runtime.stdlibMin，已在 digest 覆盖内）。畸形即拒。
  //     只捕获、不裁定——是否满足下限由 stdlib_gate.dart 在编排器里比对本端 stdlib（ADR-018 §2.6）。
  final String? stdlibMin;
  try {
    stdlibMin = readEnvelopeStdlibMin(env);
  } on BundleFormatException catch (e) {
    return VerifyResult.fail('${e.message} → fail-closed');
  }

  // 5. 公钥：keyId 必须命中**预埋且 active** 的信任锚。
  //    dormant 命中也拒——晋升只能随发版（ADR-002 §2.3 放大信任方向不可热推）。
  final anchor = resolveAnchor(signature.keyId);
  if (anchor == null) {
    return VerifyResult.fail(
      'keyId ${signature.keyId} 不在预埋 active 信任锚集合内（未知或已 dormant/吊销）→ fail-closed',
    );
  }

  // 6. Ed25519 验签。
  final payload = serializeSignaturePayload(
    adapterId: signature.adapterId,
    adapterVersion: signature.adapterVersion,
    tier: signature.tier,
    digest: signature.digest,
  );
  final bool verified;
  try {
    verified = await Ed25519().verify(
      payload,
      signature: Signature(
        signature.signatureBytes(),
        publicKey: SimplePublicKey(anchor.publicKeyBytes(), type: KeyPairType.ed25519),
      ),
    );
  } on FormatException catch (e) {
    // 裸 64B 守卫 / base64 畸形都在这里落地为"拒"，而非把异常抛给上层。
    return VerifyResult.fail('签名字节不合法：${e.message} → fail-closed');
  }
  if (!verified) {
    return VerifyResult.fail('Ed25519 验签失败 → fail-closed');
  }

  // 7. 档位：验签只为 **official** 服务，`tier` 非 official 一律拒。
  //    `sideload` **刻意不接受**——客户端的 dev 侧载只能由 `TrustedAdapterContext.devSideload()`
  //    在 debug build 构造（ADR-002 §2.5）。若在此接受签名里的 `tier: "sideload"`，就等于让
  //    一份远程签名声明自己进 dev 档，把 §2.5 的 debug-only 闸门交给了网络输入。
  //    注意：`tier` 已进签名载荷（第 6 步验过），故这里比的是**已验签**的值，不是可篡改的声明。
  if (signature.tier != kTierOfficial) {
    return VerifyResult.fail('签名档位非 official：${signature.tier} → fail-closed');
  }

  return VerifyResult.ok(
    VerifiedBundle._(
      identity: identity,
      keyId: anchor.keyId,
      digest: digest,
      stdlibMin: stdlibMin,
    ),
  );
}

String _short(String digest) =>
    digest.length <= 12 ? digest : '${digest.substring(0, 12)}…';
