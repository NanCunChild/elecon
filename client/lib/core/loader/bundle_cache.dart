/// 🔒 内容寻址 bundle 缓存 —— ADR-018 §2.6（红线 #4：仅官方签名加载）。
///
/// **内容寻址**：以 envelope [digest]（= `SHA-256(envelopeBytes)`，ADR-018 §2.9.1）为 key。
/// 天然抗篡改、去重、支持回滚校验。**绝不"验一次缓存永久信任"**：每次 [read] 都重算 digest
/// 与 key 比对，保证取回的**就是**当初落地的那份字节；不符（磁盘损坏 / 被替换）→ 当未命中处理。
///
/// **原子落地**：写经注入的 [BlobStore]（生产 = [FileBlobStore]，先写 tmp 再 rename），杜绝加载
/// 到半个 bundle。
///
/// ── v2 的简化：**缓存只进出「原始字节」，不再吐结构** ────────────────────────────
///
/// v1 的 [read] 返回 `CachedBundle{envelope, signature}`——一个**已解析但未验签**的对象。
/// 那是个天然的误用陷阱：类型上它和验签后的产物长得一样，全靠文档说"别直接用"。它还迫使
/// 缓存层自己去解析签名字段、判断"缺签名的算不算命中"，把验签管线的一部分逻辑复制到了这里。
///
/// v2 起 [read] 只返回 `Uint8List`（原始 `.json.gz` 字节），调用方**必须**把它交给
/// `verify.dart` 的 `openBundle` 才能得到任何结构。于是：
///  - 缓存层不再有第二份解析实现，也就不会与验签管线漂移；
///  - "未验签的 envelope"这个危险中间态在类型上**根本不存在**；
///  - "缓存是加速与离线，不是信任源"从一句注释变成了 API 形状。
///
/// **信任边界**：[write] 只接受 [VerifiedBundle]（不可伪造，仅验签管线全过后铸造），且落地
/// 字节的内容寻址须与该 [VerifiedBundle.digest] 一致（双重锁死"缓存的就是验过的"）。
///
/// 🔒 改动须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'dart:typed_data';

import '../credential/blob_store.dart' show BlobStore;
import 'bundle.dart';
import 'verify.dart' show VerifiedBundle;

/// digest 形态 = 64 位小写 hex（envelope digest）。防注入路径穿越 / 畸形 key。
final RegExp _reDigest = RegExp(r'^[0-9a-f]{64}$');

class BundleCache {
  const BundleCache(this._store);

  final BlobStore _store;

  /// 缓存文件名：内容寻址（digest 已校验为 64hex，安全作文件名）。
  String _name(String digest) => 'bundles/$digest.bundle';

  /// 🔒 落地一份**已验签** bundle 的原始 packed 字节（传输封套 `.json.gz`）。
  ///
  /// 接受条件（任一不满足即 [BundleFormatException]，fail-closed，绝不缓存可疑字节）：
  ///  - [verified]（不可伪造验签证据）的 digest 为 64hex；
  ///  - packed 字节里的 envelopeBytes 哈希 == [VerifiedBundle.digest]（内容寻址自洽）；
  ///  - packed 携带的签名声明的 `digest` == [VerifiedBundle.digest]（把"验过的内容"与
  ///    "随存的签名"绑定，杜绝"验过内容 A + 无关签名"被存进缓存）。
  ///
  /// **只做这三项**：packed 是否整体可信，[verified] 已经证明了；重跑一遍完整验签既慢也
  /// 无新信息。读回时才需要重新验签——因为磁盘在那之间是不可信的。
  ///
  /// 写入经 [BlobStore] 原子 rename。
  Future<void> write(VerifiedBundle verified, Uint8List packedBytes) async {
    if (!_reDigest.hasMatch(verified.digest)) {
      throw const BundleFormatException('VerifiedBundle.digest 非 64hex（fail-closed）');
    }
    final wire = readWire(packedBytes); // 畸形/超限 → BundleFormatException
    final actual = envelopeDigest(wire.envelopeBytes);
    if (actual != verified.digest) {
      throw BundleFormatException(
        '拒绝缓存：packed 内容寻址 ${_short(actual)} ≠ 验签证据 ${_short(verified.digest)}（fail-closed）',
      );
    }
    if (wire.signatureJson['digest'] != verified.digest) {
      throw const BundleFormatException(
        '拒绝缓存：随存签名声明的 digest 与验签证据不符（fail-closed）',
      );
    }
    await _store.write(_name(verified.digest), packedBytes);
  }

  /// 读回内容寻址校验通过的**原始 packed 字节**；未命中/损坏/不符 → null。
  ///
  /// **未验签**：本方法只保证"返回的就是 key=[digest] 那份字节"。信任裁定（验签 + revocation
  /// + stdlibMin 门）由调用方在此之后用 `openBundle` 重跑（§2.6：每次加载都验）——返回类型是
  /// 裸字节，调用方**除了**交给 `openBundle` 之外做不了别的。
  Future<Uint8List?> read(String digest) async {
    if (!_reDigest.hasMatch(digest)) return null; // 畸形 key 直接未命中，不碰磁盘
    final bytes = await _store.read(_name(digest));
    if (bytes == null) return null;
    try {
      if (envelopeDigest(readWire(bytes).envelopeBytes) != digest) {
        return null; // 内容寻址不符 → 损坏/被替换，当未命中
      }
      return bytes;
    } on BundleFormatException {
      return null; // 损坏/超限的缓存字节 → 未命中（调用方回退下载 / bootstrap）
    }
  }

  /// 是否已缓存且内容寻址自洽。
  Future<bool> has(String digest) async => (await read(digest)) != null;

  /// 驱逐一条缓存（如 revocation 命中后清理）。digest 畸形则 no-op。
  Future<void> evict(String digest) async {
    if (!_reDigest.hasMatch(digest)) return;
    await _store.delete(_name(digest));
  }

  static String _short(String d) => d.length <= 12 ? d : '${d.substring(0, 12)}…';
}
