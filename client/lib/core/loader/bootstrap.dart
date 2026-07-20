/// 🔒 预置基线（bootstrap baseline）读取 —— ADR-018 §2.6 / ADR-010 硬要求（红线 #4）。
///
/// app 二进制内打包一组**已签名** baseline adapter + 初始 catalog + 初始 revocation list，令
/// **首启 / 离线**即可走通核心功能；远程拉取只用于"更新 / 新增数据源"。审核员在提交 build 上
/// 即可跑通核心（ADR-010）。
///
/// 本文件只做**读取 + 格式还原**，把 asset 字节还原成 [SignedCatalog] / [SignedRevocationList] /
/// packed bundle 字节。**读到 ≠ 可信**：baseline 与线上产物**同格式、同验签**——虽随官方签名的
/// app 二进制分发，编排器 `loader.dart`（片 E）仍对其**重跑验签 + 各门**后才采用（"预置基线同格式，
/// 在线更新与离线基线一致可验"，§2.6）。
///
/// **asset 源可注入**（[AssetSource]）：生产 = [FlutterAssetSource]（rootBundle）；测试 = 假源。
///
/// 当前已随测试版打包 HelloWorld 的真实签名 catalog、revocation 和 bundle；新增/替换基线时
/// 必须重新走官方签名和发布台账流程，不得用未签名或本地测试锚替代。
///
/// 🔒 改动须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import 'catalog.dart' show SignedCatalog;
import 'revocation.dart' show SignedRevocationList;

/// bootstrap asset 只读源。缺失 → null（不抛：无基线是合法的降级路径）。
abstract interface class AssetSource {
  Future<Uint8List?> load(String key);
}

/// 生产源：Flutter rootBundle。缺 asset 时 rootBundle 抛 [FlutterError]，此处吞成 null。
class FlutterAssetSource implements AssetSource {
  const FlutterAssetSource();

  @override
  Future<Uint8List?> load(String key) async {
    try {
      final data = await rootBundle.load(key);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      // 未打包该 asset 时 rootBundle 抛 FlutterError（属 Error 非 Exception）→ 视为无基线降级。
      // 对可选 bootstrap asset，"任何加载失败即视为缺失"是可接受语义（编排器回退）。
      return null;
    }
  }
}

/// digest 形态 = 64 位小写 hex，作 bundle asset 文件名前先校验（防路径穿越 / 畸形）。
final RegExp _reDigest = RegExp(r'^[0-9a-f]{64}$');

class BootstrapBaseline {
  const BootstrapBaseline(this._assets, {this.assetRoot = 'assets/bootstrap'});

  final AssetSource _assets;
  final String assetRoot;

  /// 初始 catalog（已签名）；未打包 / 损坏 → null。
  Future<SignedCatalog?> catalog() =>
      _readSigned('$assetRoot/catalog.json', SignedCatalog.fromJson);

  /// 初始 revocation list（已签名）；未打包 / 损坏 → null。
  Future<SignedRevocationList?> revocation() =>
      _readSigned('$assetRoot/revocation.json', SignedRevocationList.fromJson);

  /// 按 envelope digest 取 baseline bundle 的 packed 字节（`gzip(JSON)`）；无 → null。
  /// 返回字节**未验签**：调用方内容寻址 + 验签后才可用（同 [BundleCache.read] 的边界）。
  Future<Uint8List?> bundleByDigest(String digest) {
    if (!_reDigest.hasMatch(digest)) return Future.value(null);
    return _assets.load('$assetRoot/bundles/$digest.bundle');
  }

  /// 损坏 / 缺失 → null（bootstrap 缺位是合法降级；信任裁定在验签，不在此）。
  Future<T?> _readSigned<T>(
    String key,
    T Function(Map<String, dynamic>) parse,
  ) async {
    final bytes = await _assets.load(key);
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
