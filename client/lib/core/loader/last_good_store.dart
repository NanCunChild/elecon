/// 🔒 last-good 清单持久化 —— catalog / revocation 的"上一份已验签"落盘（ADR-018 §2.6，红线 #4）。
///
/// **为何**：拉取失败**绝不**当作"全放行"（ADR-002 §2.4）。客户端把最近一次验过的 [SignedCatalog]
/// 与 [SignedRevocationList] 原样落盘；下次启动 / 拉取失败时读回、**重新验签**后作 last-good 回退，
/// 使离线仍 fail-closed 而非瘫痪。
///
/// **单槽、非内容寻址**：catalog/revocation 由 `sequence` 单调防回滚（见 `pickNewerCatalog` /
/// `pickNewerRevocation`），此处只保留"当前采用的那一份"，覆盖式写。与内容寻址的 [BundleCache]
/// （多版本、按 digest）语义不同，故分开。
///
/// **存的是被签名的原始字节**：[SignedCatalog.catalogJson] / [SignedRevocationList.listJson] 原样
/// 存取（`toJson`/`fromJson` 往返不碰被签名字节），故读回后验签仍成立（字节精确模型）。
///
/// **读回 ≠ 可信**：本 store 只做**格式还原**，任何信任裁定（验签 + sequence 防回滚 + TTL）都由
/// 编排器 `loader.dart`（片 E）在读回后重跑——store 不验签、不比较、不裁定。
///
/// 🔒 改动须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../credential/blob_store.dart' show BlobStore;
import 'catalog.dart' show SignedCatalog, VerifiedCatalog;
import 'revocation.dart' show SignedRevocationList, VerifiedRevocationList;

class LastGoodStore {
  const LastGoodStore(this._store);

  final BlobStore _store;

  static const String _catalogName = 'last-good/catalog.json';
  static const String _revocationName = 'last-good/revocation.json';

  /// 覆盖式落地 last-good catalog（原子，经 [BlobStore]）。
  ///
  /// **只存已验签内容（类型层强制，评审 #4）**：须同时给出不可伪造的 [VerifiedCatalog]（验签证据）
  /// 与要持久化的原始 [SignedCatalog] 签名字节——持有前者才证明后者验过。二者须对应（[keyId] 一致，
  /// 廉价哨兵）；持久化的是 `signed`（含 catalogJson+signature，供下次启动**重新验签**），因为
  /// [VerifiedCatalog] 只带解析后内容、不带签名，无法据以重验。
  Future<void> writeCatalog(VerifiedCatalog verified, SignedCatalog signed) {
    if (signed.keyId != verified.keyId) {
      throw ArgumentError(
        'last-good catalog：SignedCatalog 与 VerifiedCatalog 不对应（keyId ${signed.keyId} ≠ ${verified.keyId}）',
      );
    }
    return _store.write(_catalogName, _encode(signed.toJson()));
  }

  /// 读回 last-good catalog；无 / 损坏 → null（调用方回退 bootstrap 基线）。
  Future<SignedCatalog?> readCatalog() async =>
      _decode(await _store.read(_catalogName), SignedCatalog.fromJson);

  /// 覆盖式落地 last-good revocation（原子）。同 [writeCatalog]：须给出 [VerifiedRevocationList]
  /// 证据 + 原始 [SignedRevocationList] 签名字节，keyId 须一致。
  Future<void> writeRevocation(
      VerifiedRevocationList verified, SignedRevocationList signed) {
    if (signed.keyId != verified.keyId) {
      throw ArgumentError(
        'last-good revocation：SignedRevocationList 与 VerifiedRevocationList 不对应（keyId ${signed.keyId} ≠ ${verified.keyId}）',
      );
    }
    return _store.write(_revocationName, _encode(signed.toJson()));
  }

  /// 读回 last-good revocation；无 / 损坏 → null。
  Future<SignedRevocationList?> readRevocation() async =>
      _decode(await _store.read(_revocationName), SignedRevocationList.fromJson);

  static Uint8List _encode(Map<String, dynamic> json) =>
      Uint8List.fromList(utf8.encode(jsonEncode(json)));

  /// 损坏字节（非法 utf8/JSON、缺字段）一律作 **null**（未命中）而非抛：last-good 缺失/损坏是
  /// 预期路径（首启、磁盘损坏），回退 bootstrap 基线即可，不应 crash 加载链。
  static T? _decode<T>(Uint8List? bytes, T Function(Map<String, dynamic>) parse) {
    if (bytes == null) return null;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) return null;
      return parse(decoded);
    } on FormatException {
      return null;
    }
  }
}
