/// 🔒🔒 bundle 打开与验签 —— 客户端信任裁定的**承重路径**（红线 #4：仅官方签名加载）。
///
/// 镜像 `tools/src/bundle/package.ts` 的 `openBundle`，并对齐 tools 层 `VerifyResult<T>` 约定：
/// **失败恒带 reason；成功携带已验证产物**——调用方只能经成功分支拿到裁定档位与内容，
/// 拿不到未验证的数据。
///
/// **本文件回答的问题**：这串**线上字节**，对预埋 pin 公钥是否成立？成立则得到什么内容？
/// **本文件不回答**：要不要加载（还差吊销查询 + stdlibMin 门 + 缓存/原子落地，
/// 见 ADR-018 §2.6 的完整 fail-closed 顺序，由上层编排）。
///
/// ── v2 的结构性改动：**入口从「已解析的 envelope」改成「原始字节」** ──────────────
///
/// v1 的入口是 `verifyBundleSignature(BundleEnvelope env, SignatureFile sig)`——调用方**先解析、
/// 再拿来验签**。那个签名（signature）本身就违反 digest v2 的纪律 2（验签先于解析）：
/// 一旦 envelope 已经是对象，"验的字节"和"用的字节"就分了家，中间任何重新序列化都是漂移面。
///
/// v2 起唯一入口是 [openBundle]，收 `Uint8List` 线上字节，内部按**不可重排**的顺序走完：
///
///   1. 压缩体上限 → 有界 gunzip           （压缩炸弹护栏）
///   2. 解析**传输封套**（仅三字段，严格）   ← 验签前唯一允许的解析
///   3. base64 解码得 envelopeBytes
///   4. 算法只认 ed25519                    （不按签名文件自述选算法）
///   5. SHA-256(envelopeBytes) 比对 signature.digest   （内容寻址）
///   6. keyId 命中预埋 **active** 信任锚 → Ed25519 验签  ← **到此为止未 parse 过 envelope**
///   7. **才** parseEnvelope；bundleFormat 严格相等
///   8. 路径卫生闸门
///   9. blob 集合精确相等                    ← 多一个 = 夹带通道
///  10. 逐文件 size 界定 → 长度精确 → SHA-256 命中
///  11. 身份三方一致（签名载荷 ↔ envelope 顶层 ↔ manifest.json）
///  12. 档位：只裁定 official
///
/// **与 TS `openBundle` 的两处刻意差异**（非疏漏）：
///  - TS 版**不做**第 6 步的 pin 解析与第 12 步的档位门。TS 的 `openBundle` 服务于台账提取、
///    签发侧自验等**非加载**场景，那里需要"密码学事实"而不需要"加载策略"；把策略塞进去会
///    逼这些调用方接受一个会拒 sideload 的 API。
///  - Dart 版**是加载器**，故这两步都在：信任根必须是编译期常量集合，档位必须只认 official。
///    golden 用例 `valid_signature_sideload_tier` 正是钉这一点：TS 侧 ok + tier=sideload，
///    Dart 侧必须拒（该用例带 `loaderMustRefuse` 标记）。
///
/// 🔒 改动须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'dart:typed_data';

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

/// 🔒 **验签通过的证据（un-forgeable capability）** —— 已核对的权威身份 + pin key id + digest
/// + **已校验的内容本身**。
///
/// **构造器库私有（`._`）**：只有本库（`verify.dart`）能造，且只在完整验签管线全过后造。
/// 故"持有一个 [VerifiedBundle]"在**编译期**即等价于"这份 bundle 对某把预埋 active pin 公钥
/// 验签成立，且走完了卫生闸门与 blob 校验"——任何外部代码（含测试）都无法伪造出来。
///
/// **v2 起它携带内容**（[envelope] + [blobs]）：v1 时调用方自己持有解析好的 envelope，
/// 于是"验过的那份"和"用的那份"在类型上是两个东西，靠约定保持一致。现在两者是同一个对象的
/// 两个字段，**结构上不可能拿错**——这是纪律 1「验的字节 = 要用的字节」在类型层面的落实。
///
/// **持有它 ≠ 可加载**：它只证明"验签成立"。要不要加载还差吊销查询 + `stdlibMin` 门
/// （ADR-018 §2.6 第 5/6 步），由编排器在此之后做——编排器过完门禁才铸造 official 凭据。
///
/// [tier] 不设字段：验签只为 official 服务（第 12 步即拒非 official），故存在即 official。
class VerifiedBundle {
  const VerifiedBundle._({
    required this.identity,
    required this.keyId,
    required this.digest,
    required this.stdlibMin,
    required this.envelope,
    required this.envelopeBytes,
    required this.blobs,
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

  /// 已校验的清单。
  final BundleEnvelope envelope;

  /// 被签名的**原始字节**（`digest == SHA-256(envelopeBytes)`）。
  ///
  /// 携带它是为了让下游（`adapter_launcher.dart` 的 source⟷凭据绑定复核）能重算 digest，
  /// 而**不必**从 [envelope] 重新序列化——后者会把 canonical JSON 的漂移面请回来（纪律 1）。
  final Uint8List envelopeBytes;

  /// 已校验的内容（按 sha256 寻址）。取文件请用 `fileBytesByPath(envelope, blobs, path)`。
  final BlobTable blobs;
}

/// keyId → 信任锚的解析器。生产恒为 [activeAnchorByKeyId]（只认预埋 active 集合）。
typedef AnchorResolver = TrustAnchor? Function(String keyId);

/// 🔒 **生产入口**：打开一份线上 bundle 字节，针对**预埋且 active** 的 pin 公钥验签。
///
/// 只在**全部**校验通过时返回 [VerifiedBundle]；任一步失败即 [VerifyResult.fail]（fail-closed）。
Future<VerifyResult<VerifiedBundle>> openBundle(Uint8List packedBytes) =>
    openBundleWith(packedBytes, activeAnchorByKeyId);

/// 验签管线本体，公钥来源经 [resolveAnchor] 注入。
///
/// **为何把"解析公钥"做成接缝，而不是直接传公钥**：信任根必须是编译期常量集合
/// （[kTrustAnchors]），不可运行时替换——若本函数收 `publicKey` 参数，任何调用方都能
/// 拿任意公钥验签，pin 就形同虚设。收 resolver 则保留了"keyId 必须命中预埋 active 锚"
/// 这一步语义，生产唯一实参是 [activeAnchorByKeyId]。
///
/// [visibleForTesting]：测试用 golden 的**测试**公钥跑同一条管线（生产预埋集里当然没有它）。
/// **生产代码不得调用本函数**——请用 [openBundle]。
@visibleForTesting
Future<VerifyResult<VerifiedBundle>> openBundleWith(
  Uint8List packedBytes,
  AnchorResolver resolveAnchor,
) async {
  // 1–3. 有界 gunzip → 解析传输封套（严格三字段）→ 解码 envelopeBytes。
  //      **这是验签之前唯一允许的解析**，且解析面已被 readWire 收到最小。
  final WireParts wire;
  try {
    wire = readWire(packedBytes);
  } on BundleFormatException catch (e) {
    return VerifyResult.fail('${e.message} → fail-closed');
  }

  final SignatureFile signature;
  try {
    signature = SignatureFile.fromJson(wire.signatureJson);
  } on FormatException catch (e) {
    return VerifyResult.fail('签名字段畸形：${e.message} → fail-closed');
  }

  // 4. 算法：只认 ed25519。不做回退，不按"签名文件说什么就用什么"选算法。
  if (signature.algorithm != 'ed25519') {
    return VerifyResult.fail('不支持的签名算法：${signature.algorithm} → fail-closed');
  }

  // 5. 内容寻址 digest：重算**收到的那串字节**的哈希并比对。
  //    这一步把"下面要验的字节"钉死成"上层将要执行的字节"，且它便宜、在验签之前。
  final digest = envelopeDigest(wire.envelopeBytes);
  if (digest != signature.digest) {
    return VerifyResult.fail(
      'digest 不符：算得 ${_short(digest)} 期望 ${_short(signature.digest)} → fail-closed',
    );
  }

  // 6. 公钥：keyId 必须命中**预埋且 active** 的信任锚。
  //    dormant 命中也拒——晋升只能随发版（ADR-002 §2.3 放大信任方向不可热推）。
  final anchor = resolveAnchor(signature.keyId);
  if (anchor == null) {
    return VerifyResult.fail(
      'keyId ${signature.keyId} 不在预埋 active 信任锚集合内（未知或已 dormant/吊销）→ fail-closed',
    );
  }

  // 6b. Ed25519 验签。签名输入带 `elecon.bundle-payload/2` 域分隔前缀（见 signature.dart）。
  //     **到此为止 envelope 仍是一串未解析的字节。**
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
        publicKey: SimplePublicKey(
          anchor.publicKeyBytes(),
          type: KeyPairType.ed25519,
        ),
      ),
    );
  } on FormatException catch (e) {
    // 裸 64B 守卫 / base64 畸形都在这里落地为"拒"，而非把异常抛给上层。
    return VerifyResult.fail('签名字节不合法：${e.message} → fail-closed');
  }
  if (!verified) {
    return VerifyResult.fail('Ed25519 验签失败 → fail-closed');
  }

  // 7–11. 验签通过，**现在才**允许解析，并逐条走完结构不变量。
  final ParsedEnvelope parsed;
  final String? stdlibMin;
  final EnvelopeIdentity identity;
  try {
    parsed = parseEnvelope(wire.envelopeBytes); // 7（含 bundleFormat 严格相等）
    assertPathHygiene(parsed.envelope); // 8
    assertBlobSetExact(parsed.envelope, wire.blobs); // 9
    assertBlobsMatchDescriptors(parsed.envelope, wire.blobs); // 10
    assertIdentityTriple(
      parsed.envelope,
      wire.blobs,
      EnvelopeIdentity(
        adapterId: signature.adapterId,
        adapterVersion: signature.adapterVersion,
      ),
    ); // 11
    identity = readEnvelopeIdentity(parsed.envelope, wire.blobs);
    // 捕获权威 stdlibMin（manifest.runtime.stdlibMin，已在 digest 覆盖内）。畸形即拒。
    // 只捕获、不裁定——是否满足下限由 stdlib_gate.dart 在编排器里比对（ADR-018 §2.6）。
    stdlibMin = readEnvelopeStdlibMin(parsed.envelope, wire.blobs);
  } on BundleFormatException catch (e) {
    return VerifyResult.fail('${e.message} → fail-closed');
  }

  // 12. 档位：验签只为 **official** 服务，`tier` 非 official 一律拒。
  //     `sideload` **刻意不接受**——客户端的 dev 侧载只能由 `TrustedAdapterContext.devSideload()`
  //     在 debug build 构造（ADR-002 §2.5）。若在此接受签名里的 `tier: "sideload"`，就等于让
  //     一份远程签名声明自己进 dev 档，把 §2.5 的 debug-only 闸门交给了网络输入。
  //     注意：`tier` 已进签名载荷（第 6b 步验过），故这里比的是**已验签**的值，不是可篡改的声明。
  if (signature.tier != kTierOfficial) {
    return VerifyResult.fail('签名档位非 official：${signature.tier} → fail-closed');
  }

  return VerifyResult.ok(
    VerifiedBundle._(
      identity: identity,
      keyId: anchor.keyId,
      digest: digest,
      stdlibMin: stdlibMin,
      envelope: parsed.envelope,
      envelopeBytes: parsed.bytes,
      blobs: wire.blobs,
    ),
  );
}

String _short(String digest) =>
    digest.length <= 12 ? digest : '${digest.substring(0, 12)}…';
