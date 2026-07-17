/// 🔒 内容寻址 bundle 缓存 —— ADR-018 §2.6（红线 #4：仅官方签名加载）。
///
/// **内容寻址**：以 envelope [digest]（ADR-002 §2.3 规范化双层 SHA-256）为 key。天然抗篡改、
/// 去重、支持回滚校验。**绝不"验一次缓存永久信任"**：每次 [read] 都重算 envelope digest 与 key
/// 比对，保证取回的**就是**当初落地的那份字节；不符（磁盘损坏 / 被替换）→ 当未命中处理。
///
/// **原子落地**：写经注入的 [BlobStore]（生产 = [FileBlobStore]，先写 tmp 再 rename），杜绝加载
/// 到半个 bundle。
///
/// **信任边界**：[write] 只接受 [VerifiedBundle]（不可伪造，仅验签管线全过后铸造）——令未验签
/// 内容进不了缓存；且落地字节的内容寻址须与该 [VerifiedBundle.digest] 一致（双重锁死"缓存的
/// 就是验过的"）。[read] 返回的是**未验签的** envelope（只保证"就是 key 那份字节"）：是否采用
/// 由编排器 `loader.dart`（片 E）在 read 后**重跑验签 + 各门**裁定——缓存是加速与离线，不是信任源。
///
/// 🔒 改动须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'dart:typed_data';

import '../credential/blob_store.dart' show BlobStore;
import 'bundle.dart';
import 'signature.dart' show SignatureFile;
import 'verify.dart' show VerifiedBundle;

/// digest 形态 = 64 位小写 hex（envelope digest）。防注入路径穿越 / 畸形 key。
final RegExp _reDigest = RegExp(r'^[0-9a-f]{64}$');

/// 缓存读回的一份 bundle：envelope + **detached 签名**。
///
/// 携签是**能重新验签**的前提——`verifyBundleSignature(envelope, signature)` 两者都要。缓存必带
/// 签名，故加载路径读回后可按 §2.6「每次加载重新验签」走完整信任裁定。仍**未验签**：本对象只保证
/// "就是 key 那份字节 + 携带了一个形状合法的签名"，验签成立与否由调用方（编排器）重跑判定。
class CachedBundle {
  const CachedBundle({required this.envelope, required this.signature});
  final BundleEnvelope envelope;
  final SignatureFile signature;
}

class BundleCache {
  const BundleCache(this._store);

  final BlobStore _store;

  /// 缓存文件名：内容寻址（digest 已校验为 64hex，安全作文件名）。
  String _name(String digest) => 'bundles/$digest.bundle';

  /// 🔒 落地一份**已验签** bundle 的原始 packed 字节（`gzip(JSON({envelope, signature}))`）。
  ///
  /// 接受条件（任一不满足即 [BundleFormatException]，fail-closed，绝不缓存可疑字节）：
  ///  - [verified]（不可伪造验签证据）的 digest 为 64hex；
  ///  - packed 解包后 envelope digest == [VerifiedBundle.digest]（内容寻址自洽）；
  ///  - packed **含 detached 签名**且可解析为 [SignatureFile]（缺签名的 packed 读回后无法重新验签，
  ///    评审 #1/#2）；
  ///  - 该签名声明的 `digest` == [VerifiedBundle.digest]（把"验过的内容"与"随存的签名"绑定，
  ///    杜绝"验过内容 A + 无关签名"被存进缓存）。
  ///
  /// 写入经 [BlobStore] 原子 rename。
  Future<void> write(VerifiedBundle verified, Uint8List packedBytes) async {
    if (!_reDigest.hasMatch(verified.digest)) {
      throw const BundleFormatException('VerifiedBundle.digest 非 64hex（fail-closed）');
    }
    final unpacked = unpackBundle(packedBytes); // 畸形/超限 → BundleFormatException
    final actual = envelopeDigest(unpacked.envelope);
    if (actual != verified.digest) {
      throw BundleFormatException(
        '拒绝缓存：packed 内容寻址 ${_short(actual)} ≠ 验签证据 ${_short(verified.digest)}（fail-closed）',
      );
    }
    final sigJson = unpacked.signature;
    if (sigJson == null) {
      throw const BundleFormatException(
        '拒绝缓存：packed 缺 detached 签名 → 读回后无法重新验签（fail-closed）',
      );
    }
    final SignatureFile sig;
    try {
      sig = SignatureFile.fromJson(sigJson);
    } on FormatException catch (e) {
      throw BundleFormatException('拒绝缓存：签名字段畸形：${e.message}（fail-closed）');
    }
    if (sig.digest != verified.digest) {
      throw const BundleFormatException(
        '拒绝缓存：随存签名声明的 digest 与验签证据不符（fail-closed）',
      );
    }
    await _store.write(_name(verified.digest), packedBytes);
  }

  /// 读回内容寻址校验通过的 [CachedBundle]（envelope + 签名），未命中/损坏/缺签名/不符 → null。
  ///
  /// **未验签**：本方法只保证"返回的就是 key=[digest] 那份字节 + 携带形状合法的签名"（重算 envelope
  /// digest 比对）；**信任裁定（验签 + revocation + stdlibMin 门）由调用方在此之后用返回的
  /// [CachedBundle.signature] 重跑**（§2.6：每次加载都验）。
  Future<CachedBundle?> read(String digest) async {
    if (!_reDigest.hasMatch(digest)) return null; // 畸形 key 直接未命中，不碰磁盘
    final bytes = await _store.read(_name(digest));
    if (bytes == null) return null;
    try {
      final unpacked = unpackBundle(bytes);
      if (envelopeDigest(unpacked.envelope) != digest) return null; // 内容寻址不符 → 损坏/未命中
      final sigJson = unpacked.signature;
      if (sigJson == null) return null; // 缺签名的缓存无法重新验签 → 视为未命中
      return CachedBundle(
        envelope: unpacked.envelope,
        signature: SignatureFile.fromJson(sigJson),
      );
    } on BundleFormatException {
      return null; // 损坏/超限的缓存字节 → 未命中（调用方回退下载 / bootstrap）
    } on FormatException {
      return null; // 签名字段畸形 → 未命中
    }
  }

  /// 是否已缓存且内容寻址自洽（含携带合法签名）。
  Future<bool> has(String digest) async => (await read(digest)) != null;

  /// 驱逐一条缓存（如 revocation 命中后清理）。digest 畸形则 no-op。
  Future<void> evict(String digest) async {
    if (!_reDigest.hasMatch(digest)) return;
    await _store.delete(_name(digest));
  }

  static String _short(String d) => d.length <= 12 ? d : '${d.substring(0, 12)}…';
}
