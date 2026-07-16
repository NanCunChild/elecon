/// 预埋信任锚 —— **多公钥预埋 + 分批启用**（ADR-002 §2.3）。
///
/// 这里是 elecon 客户端信任的**根**：一组编译进二进制的裸 32 字节 Ed25519 公钥。
///
/// **关键不变量**（ADR-002 §2.3）：可被启用的公钥**只能来自本文件的预埋集合**——
/// 任何下发信号（catalog / 吊销清单 / 服务端应答）都**无法引入不在二进制里的新公钥**。
/// 这把「更新通道变成新信任根入口」这一风险（§3.2）**封死在预埋集合内**。
/// 故：**增删本集合、以及把 dormant 晋升为 active，一律随 App 发版**，不做热推启用声明
/// （与 ADR-010「信任根变更只能随发版」同构，钉在应用商店审核之后）。
///
/// **方向不对称**（安全要点）：
///  - **收窄信任**（停用 / 吊销一把公钥）→ 可半热生效，走吊销通道（§2.4）。
///  - **放大信任**（晋升 dormant → active）→ **一律随发版**。
///
/// **不放证书**：信任锚是裸 32B 公钥，不是 X.509（ADR-002 §2.3，2026-07-16 决策）。
/// 加载器不做任何 ASN.1 解析 / 证书链构建 / 有效期校验——那会把红线 #4「加载器最小化」
/// 撑破，且证书过期会成为验签的隐性失效源。
///
/// 🔒 红线 #4 承重件——**本文件即信任根**。任何改动（增/删/晋升）须人工 + 安全清单复核，
///    不得 AI 独自闭环；且须与发布台账（ADR-002 §2.3）对账。
library;

import 'dart:typed_data';

/// 一把预埋公钥。
class TrustAnchor {
  const TrustAnchor({
    required this.keyId,
    required this.publicKeyHex,
    required this.active,
    required this.note,
  });

  /// 与签名文件 `signature.json` 的 `keyId` 对应。
  final String keyId;

  /// 裸 32 字节 Ed25519 公钥（hex）。
  final String publicKeyHex;

  /// 是否为当前启用档。**dormant（false）的公钥不参与验签**——它只是"已下发、待晋升"。
  final bool active;

  /// 出处备注（哪把 token / 何时 ceremony），便于与发布台账对账。
  final String note;

  Uint8List publicKeyBytes() {
    final bytes = _decodeHex(publicKeyHex);
    if (bytes.length != 32) {
      throw StateError('信任锚 $keyId 的公钥须为裸 32 字节，得 ${bytes.length}（fail-closed）');
    }
    return bytes;
  }
}

/// 预埋集合。
///
/// **现状（2026-07-16）**：只有 1 把 active、0 把 dormant。
/// ⚠ ADR-002 §3 风险 2(c) 要求 **≥2 把 token（各自独立密钥、公钥全部预埋）**——
/// 第二把就位前，active 私钥若丢失/损毁将**无 dormant 可晋升**，只能靠 kill-switch +
/// 吊销兜底并等一次发版。**这是已知缺口，非设计终态。**
const List<TrustAnchor> kTrustAnchors = <TrustAnchor>[
  TrustAnchor(
    keyId: 'elecon-official-ncc-1',
    publicKeyHex:
        'd09437aa36da1561cf64f1f856243a4bc48d86a2777e0b79046b48351d782687',
    active: true,
    note: 'YubiKey 5C NFC #36415367 / PIV 9c / 片上生成 / PIN+触碰 ALWAYS；'
        '2026-07-16 ceremony，见 docs/reference/signing_ceremony.md',
  ),
];

/// 按 keyId 取**当前启用**的信任锚；不存在或已 dormant → null（调用方须 fail-closed）。
///
/// **只按 active 查**：签名声明的 keyId 若指向一把 dormant 公钥，必须验不过——
/// 否则"晋升随发版"的约束就被签名文件自己绕过了（放大信任方向必须由二进制说了算）。
TrustAnchor? activeAnchorByKeyId(String keyId) {
  for (final a in kTrustAnchors) {
    if (a.keyId == keyId && a.active) return a;
  }
  return null;
}

Uint8List _decodeHex(String hex) {
  if (hex.length.isOdd) {
    throw StateError('hex 长度须为偶数，得 ${hex.length}');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) throw StateError('非法 hex：${hex.substring(i * 2, i * 2 + 2)}');
    out[i] = byte;
  }
  return out;
}
