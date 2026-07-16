/// detached 签名文件与**待签载荷序列化** —— Dart 侧镜像 `tools/src/signer/index.ts`。
///
/// 🔒 红线 #4 承重件：改动须人工 + 安全清单复核，不得 AI 独自闭环。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 宿主裁定档位在签名里的线上取值。与 `TrustTier`（TS）同值。
///
/// **档位是签名流程注入的裁定结果，不是 manifest 自报**（ADR-002 §2.2）。
const String kTierOfficial = 'official';
const String kTierSideload = 'sideload';

/// 线上 `signature.json` 的结构。
///
/// 其中 [adapterId] / [adapterVersion] 是**待核对的声明**，不是权威身份——
/// 权威身份在 envelope 内 manifest.json（见 `bundle.dart` 的 `readEnvelopeIdentity`）。
class SignatureFile {
  const SignatureFile({
    required this.adapterId,
    required this.adapterVersion,
    required this.tier,
    required this.digest,
    required this.signature,
    required this.keyId,
    required this.algorithm,
  });

  final String adapterId;
  final String adapterVersion;
  final String tier;

  /// bundle 规范化摘要（hex）。
  final String digest;

  /// Ed25519 签名（base64，裸 64 字节）。
  final String signature;

  /// 签名所用公钥标识——对应预埋 pin 的 key id。
  final String keyId;

  /// 签名算法。**只接受 `ed25519`**，见 `verify.dart`。
  final String algorithm;

  static SignatureFile fromJson(Map<String, dynamic> json) {
    String req(String k) {
      final v = json[k];
      if (v is! String || v.isEmpty) {
        throw FormatException('signature.$k 缺失或类型错（fail-closed）');
      }
      return v;
    }

    return SignatureFile(
      adapterId: req('adapterId'),
      adapterVersion: req('adapterVersion'),
      tier: req('tier'),
      digest: req('digest'),
      signature: req('signature'),
      keyId: req('keyId'),
      algorithm: req('algorithm'),
    );
  }

  /// 裸 64 字节 Ed25519 签名。
  ///
  /// **非 64 字节一律拒**：真实误用是签端取到了封装格式（OpenPGP packet / DER 包裹）而非裸
  /// 签名（ADR-002 §4 实现注意）。签端 `YubiKeySignBackend` 与 `YubiKeyPkcs11Signer` 各有一道
  /// 64B 守卫，此处是验端的第三道——纵深防御。
  Uint8List signatureBytes() {
    final Uint8List raw;
    try {
      raw = Uint8List.fromList(base64.decode(signature));
    } on FormatException catch (e) {
      throw FormatException('signature 非合法 base64：$e（fail-closed）');
    }
    if (raw.length != 64) {
      throw FormatException(
        'Ed25519 签名须为裸 64 字节，得 ${raw.length}（疑为 packet/DER 封装，fail-closed）',
      );
    }
    return raw;
  }
}

/// 待签字节 —— 镜像 `serializePayload`（`tools/src/signer/index.ts`）。
///
/// **键序固定为 `adapterId, adapterVersion, digest, tier`**，与 TS 侧 `JSON.stringify` 的
/// 字面量键序逐字节一致。此处依赖 Dart [Map] 的**插入序**（LinkedHashMap 语义）+ [jsonEncode]，
/// 与 TS 的 `JSON.stringify` 对同一组值产出相同字节：两者都只转义 `"` `\` 与控制字符，
/// 非 ASCII 均直出 UTF-8。
///
/// **这是跨语言签名兼容的窄腰**——键序或转义任一处漂移，两端就再也验不通对方的签名。
/// 由 `contract/golden/bundle/loader.json` 的 `expectedPayloadUtf8` 逐字节钉死
/// （ADR-002 §3 风险 5）。**改动此函数必须同步重跑 golden 生成器并复核 diff。**
Uint8List serializeSignaturePayload({
  required String adapterId,
  required String adapterVersion,
  required String tier,
  required String digest,
}) {
  final canonical = jsonEncode(<String, String>{
    'adapterId': adapterId,
    'adapterVersion': adapterVersion,
    'digest': digest,
    'tier': tier,
  });
  return Uint8List.fromList(utf8.encode(canonical));
}
