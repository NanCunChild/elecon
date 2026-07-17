/// 🔒 分发 catalog 验签 —— 客户端信任裁定承重路径（红线 #4：仅官方签名加载）。
///
/// 镜像 `tools/src/catalog/sign.ts` 的**字节精确**模型：签端把 catalog 序列化恰好一次成
/// [SignedCatalog.catalogJson]，对**这份原始 UTF-8 字节**签名并原样携带；本文件对同一份字节
/// 验签，**验过之后才 parse**（不再实现一份"按字段重新序列化"的规范化——那会把新增字段甩出
/// 签名范围并制造跨语言漂移）。设计理由详见 ADR-018 §2.5 / ADR-002 §2.3。
///
/// **信任边界**：验签 + 结构/语义校验全过后，铸造**不可伪造**的 [VerifiedCatalog]
/// （构造器库私有，仅本文件在管线全过后能造，外部含测试都无法伪造）。防回滚/TTL 原语只收
/// [VerifiedCatalog]，令未验签数据无法进入受信流。
///
/// **持有 [VerifiedCatalog] ≠ 可加载**：它只证明"这份 catalog 已验签且结构合法"。要不要**采用**
/// （sequence 防回滚 / TTL / last-good 回退 / 下载 bundle / 重算 digest / bundle 验签 / 吊销 /
/// stdlibMin / 原子落地）由编排器 `loader.dart`（**待落地**）裁定。**本文件不是可加载判据**，
/// 其它代码不得把 `verifyCatalog` 成功等同于"可加载"。
///
/// 🔒 改动须人工 + 安全清单复核，不得 AI 独自闭环（AGENTS.md §1）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart'
    show Ed25519, KeyPairType, Signature, SimplePublicKey;
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'trust_anchors.dart';
import 'verify.dart' show AnchorResolver, VerifyResult;

const String kCatalogAlgorithm = 'ed25519';

/// TTL 新鲜度判定允许的**未来时钟偏差上限**（默认 5 分钟）。超此上限的 issuedAt 视为不新鲜
/// ——防止被签发成未来时间的 catalog 长期"保鲜"（密钥泄露时会放大恶意 catalog 有效期）。
const int kDefaultMaxFutureSkewMs = 5 * 60 * 1000;

final RegExp _reCatalogVersion = RegExp(r'^\d+\.\d+$');
final RegExp _reAdapterId = RegExp(r'^school-\S+$');
// elecon 版本号形态 = x.y.z，**镜像 contract 的 stdlibMin pattern**（`^\d+\.\d+\.\d+$`，红线 #6
// 契约单源）。刻意不做 prerelease/build 的"近似 semver"——那会与契约漂移且需独立维护。
// catalog schema 未给 adapterVersion 定 pattern 属契约缺口，客户端按同一 x.y.z 校验；若契约
// 改用完整 semver，须走 ADR 并两处 lockstep。注：与契约一致地接受前导零（如 01.02.03）。
final RegExp _reVersion = RegExp(r'^\d+\.\d+\.\d+$');
final RegExp _reDigest = RegExp(r'^[0-9a-f]{64}$');
// 严格 RFC3339：约束月/日/时/分/秒范围（DateTime.parse 会对越界值静默滚动，不能仅靠它）。
final RegExp _reRfc3339 = RegExp(
  r'^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])'
  r'T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(\.\d+)?'
  r'(Z|[+-]([01]\d|2[0-3]):[0-5]\d)$',
);

const Set<String> _catalogKeys = {
  'catalogVersion',
  'sequence',
  'issuedAt',
  'ttlSeconds',
  'entries',
};
const Set<String> _entryKeys = {
  'adapterId',
  'adapterVersion',
  'digest',
  'url',
  'stdlibMin',
  'capabilities',
};

/// 客户端内置的合法 capability 集合 —— 单源为 `contract/capability/registry.json`（红线 #6）。
///
/// **catalog 不得引入新 capability**（ADR-010 §3.3.2(a)）：签名只证"签发者签了这些内容"，
/// 不能替代能力集校验，尤其 catalog 属网络输入、密钥泄露时可借"新能力"提权，或让加载器
/// 收到不认识的能力、UI/schema 映射失败、路由未定义行为。故客户端**独立**复核 ⊆ registry。
///
/// 🔒 须与 registry.json 保持同步；`loader_catalog_test.dart` 有漂移哨兵断言二者相等。
/// 理想由 elecon_contract codegen 产出（当前生成包未导出能力集），未就绪前手工镜像。
const Set<String> kKnownCapabilities = {
  'grades.list',
  'schedule.week',
  'card.balance',
  'card.transactions',
  'library.loans',
  'notice.list',
  'generic.section',
};

/// 线上 `catalog.json.gz` 解压后的**外层签名信封**（与 revocation 的 `SignedRevocationList`
/// 同模式）。被签名的是 [catalogJson] 原始文本；keyId/algorithm/signature 本身不在签名范围内
/// （改动任一都会验签失败或命不中锚，故无需签）。
class SignedCatalog {
  const SignedCatalog({
    required this.catalogJson,
    required this.signature,
    required this.keyId,
    required this.algorithm,
  });

  /// 被签名的 catalog **原始 JSON 文本**（签 / 传 / 验 / parse 同一份字节）。
  final String catalogJson;

  /// Ed25519 签名（base64，裸 64 字节）over `utf8(catalogJson)`。
  final String signature;
  final String keyId;
  final String algorithm;

  static SignedCatalog fromJson(Map<String, dynamic> json) {
    String req(String k) {
      final v = json[k];
      if (v is! String || v.isEmpty) {
        throw const FormatException('SignedCatalog 字段缺失或类型错（fail-closed）');
      }
      return v;
    }

    return SignedCatalog(
      catalogJson: req('catalogJson'),
      signature: req('signature'),
      keyId: req('keyId'),
      algorithm: req('algorithm'),
    );
  }

  /// 裸 64 字节 Ed25519 签名。非 64 字节一律拒（镜像 `SignatureFile.signatureBytes`：
  /// 防签端误取封装格式 packet/DER 而非裸签名）。
  Uint8List signatureBytes() {
    final Uint8List raw;
    try {
      raw = Uint8List.fromList(base64.decode(signature));
    } on FormatException catch (e) {
      throw FormatException('catalog signature 非合法 base64：$e（fail-closed）');
    }
    if (raw.length != 64) {
      throw FormatException(
        'Ed25519 签名须为裸 64 字节，得 ${raw.length}（疑封装格式，fail-closed）',
      );
    }
    return raw;
  }
}

/// catalog list 载荷（被签名的内容）。构造器**库私有**——只能经本文件验签管线解析产出，
/// 外部无法伪造。镜像 `contract/catalog.schema.json`。
class Catalog {
  const Catalog._({
    required this.catalogVersion,
    required this.sequence,
    required this.issuedAt,
    required this.ttlSeconds,
    required this.entries,
  });

  final String catalogVersion;

  /// 单调递增序号，防回滚（见 [pickNewerCatalog]）。
  final int sequence;

  /// 签发时间（RFC3339，已在解析时严格校验格式）。新鲜度见 [catalogFresh]。
  final String issuedAt;

  /// 新鲜度上限（秒）。
  final int ttlSeconds;

  final List<CatalogEntry> entries;
}

/// 一条可加载 adapter 条目。构造器库私有（见 [Catalog]）。以 [digest] 内容寻址。
class CatalogEntry {
  const CatalogEntry._({
    required this.adapterId,
    required this.adapterVersion,
    required this.digest,
    required this.url,
    required this.capabilities,
    this.stdlibMin,
  });

  final String adapterId;
  final String adapterVersion;

  /// bundle envelope 规范化双层 SHA-256（64 位小写 hex）。客户端下载后须重算比对（编排器做）。
  final String digest;

  /// signed bundle（`.json.gz`）下载地址。解析时强制 **https**、无 userinfo（分发边界，红线 #2）。
  final String url;

  /// 该 adapter 依赖的 elecon:html 最低版本（可选，semver）。
  final String? stdlibMin;

  final List<String> capabilities;
}

/// 🔒 **验签通过的证据（un-forgeable capability）** —— 已验签 + 结构合法的 catalog + pin key id。
///
/// 构造器库私有：只有本文件的验签管线全过后能造，外部（含测试）无法 `VerifiedCatalog(...)` 伪造。
/// 未来 `loader.dart` 只接受 [VerifiedCatalog]，令未验签的 [Catalog] 无法进入受信加载流。
class VerifiedCatalog {
  const VerifiedCatalog._({required this.catalog, required this.keyId});

  /// 已验签且结构校验通过的 catalog 载荷。
  final Catalog catalog;

  /// 验签命中的预埋 active pin key id。
  final String keyId;
}

/// 🔒 **生产入口**：对 [SignedCatalog] 验签（预埋 active pin 公钥）+ 结构/语义校验。
///
/// 全过 → [VerifiedCatalog]；任一步失败即 [VerifyResult.fail]（fail-closed）。
Future<VerifyResult<VerifiedCatalog>> verifyCatalog(SignedCatalog signed) =>
    verifyCatalogWith(signed, activeAnchorByKeyId);

/// 验签管线本体，公钥来源经 [resolveAnchor] 注入（同 `verifyBundleSignatureWith` 的接缝理由：
/// 信任根是编译期常量集合，收 resolver 而非裸公钥以保留"keyId 须命中预埋 active 锚"语义）。
/// 生产唯一实参为 [activeAnchorByKeyId]。[visibleForTesting]：测试用测试密钥跑同一条管线。
/// **生产代码不得调用本函数**——请用 [verifyCatalog]。
@visibleForTesting
Future<VerifyResult<VerifiedCatalog>> verifyCatalogWith(
  SignedCatalog signed,
  AnchorResolver resolveAnchor,
) async {
  // 1. 算法：只认 ed25519（防降级）。
  if (signed.algorithm != kCatalogAlgorithm) {
    return VerifyResult.fail('不支持的 catalog 签名算法：${signed.algorithm} → fail-closed');
  }

  // 2. 公钥：keyId 须命中预埋且 active 的信任锚（dormant/未知均拒）。
  final anchor = resolveAnchor(signed.keyId);
  if (anchor == null) {
    return VerifyResult.fail(
      'catalog keyId ${signed.keyId} 不在预埋 active 信任锚集合内 → fail-closed',
    );
  }

  // 3. 签名字节：base64 解码 + 裸 64B 守卫。
  final Uint8List sigBytes;
  try {
    sigBytes = signed.signatureBytes();
  } on FormatException catch (e) {
    return VerifyResult.fail('catalog 签名字节不合法：${e.message} → fail-closed');
  }

  // 4. Ed25519 验签 over utf8(catalogJson)——验的正是要 parse 的字节。
  final bool verified;
  try {
    verified = await Ed25519().verify(
      Uint8List.fromList(utf8.encode(signed.catalogJson)),
      signature: Signature(
        sigBytes,
        publicKey:
            SimplePublicKey(anchor.publicKeyBytes(), type: KeyPairType.ed25519),
      ),
    );
  } on FormatException catch (e) {
    return VerifyResult.fail('catalog 验签输入不合法：${e.message} → fail-closed');
  }
  if (!verified) {
    return VerifyResult.fail('catalog Ed25519 验签失败 → fail-closed');
  }

  // 5. 解析 + 结构/语义校验（验签只证明"签名者签了这些字节"，不能替代结构校验）。
  final Object? decoded;
  try {
    decoded = jsonDecode(signed.catalogJson);
  } on FormatException catch (e) {
    return VerifyResult.fail('catalog JSON 解析失败：$e → fail-closed');
  }
  if (decoded is! Map<String, dynamic>) {
    return VerifyResult.fail('catalog 载荷不是对象 → fail-closed');
  }
  final Catalog catalog;
  try {
    catalog = _parseCatalog(decoded);
  } on FormatException catch (e) {
    return VerifyResult.fail('${e.message} → fail-closed');
  }
  return VerifyResult.ok(VerifiedCatalog._(catalog: catalog, keyId: anchor.keyId));
}

/// 严格解析 + 语义校验 catalog 载荷。任一约束不满足即抛 [FormatException]（由验签管线落地为 fail）。
///
/// 客户端在运行时复核契约约束（不只依赖签发侧 `validate.ts`）：签名只证"签了这些内容"，
/// 结构/语义仍须校验——尤其 digest / URL scheme / 身份 / capability 会被加载器直接使用。
Catalog _parseCatalog(Map<String, dynamic> json) {
  _rejectUnknownKeys(json, _catalogKeys, 'catalog');

  final catalogVersion = json['catalogVersion'];
  if (catalogVersion is! String || !_reCatalogVersion.hasMatch(catalogVersion)) {
    throw const FormatException('catalog.catalogVersion 非法（须 x.y）');
  }
  final sequence = json['sequence'];
  if (sequence is! int || sequence < 0) {
    throw const FormatException('catalog.sequence 须为非负整数');
  }
  final issuedAt = json['issuedAt'];
  if (issuedAt is! String || !_reRfc3339.hasMatch(issuedAt)) {
    throw const FormatException('catalog.issuedAt 非法（须 RFC3339）');
  }
  // 正则只约束数字范围（月 01-12、日 01-31）；真实日历日（2 月 30/31、非闰 2/29、4/31 等）
  // 须 round-trip 校验——DateTime.utc 会把越界日静默归一化，故构造后比对年月日是否不变。
  if (!_isValidCalendarDate(issuedAt)) {
    throw const FormatException('catalog.issuedAt 非法日历日期');
  }
  final ttlSeconds = json['ttlSeconds'];
  if (ttlSeconds is! int || ttlSeconds < 0) {
    throw const FormatException('catalog.ttlSeconds 须为非负整数');
  }
  final entries = json['entries'];
  if (entries is! List) {
    throw const FormatException('catalog.entries 须为数组');
  }

  final parsed = entries.map((e) {
    if (e is! Map) throw const FormatException('catalog.entries 含非对象项');
    return _parseEntry(Map<String, dynamic>.from(e));
  }).toList(growable: false);

  // 重复 adapterId 客户端 fail-closed：避免加载器"取第一条/最后一条"的歧义（可致版本选择漂移）。
  final seen = <String>{};
  for (final e in parsed) {
    if (!seen.add(e.adapterId)) {
      throw FormatException('catalog 含重复 adapterId：${e.adapterId}（fail-closed）');
    }
  }

  return Catalog._(
    catalogVersion: catalogVersion,
    sequence: sequence,
    issuedAt: issuedAt,
    ttlSeconds: ttlSeconds,
    entries: parsed,
  );
}

CatalogEntry _parseEntry(Map<String, dynamic> json) {
  _rejectUnknownKeys(json, _entryKeys, 'catalog entry');

  final adapterId = json['adapterId'];
  if (adapterId is! String || !_reAdapterId.hasMatch(adapterId)) {
    throw const FormatException('catalog entry.adapterId 非法（须 school-*）');
  }
  final adapterVersion = json['adapterVersion'];
  if (adapterVersion is! String || !_reVersion.hasMatch(adapterVersion)) {
    throw const FormatException('catalog entry.adapterVersion 非法（须 x.y.z）');
  }
  final digest = json['digest'];
  if (digest is! String || !_reDigest.hasMatch(digest)) {
    throw const FormatException('catalog entry.digest 非法（须 64 位小写 hex）');
  }
  final url = json['url'];
  if (url is! String || !_isValidBundleUrl(url)) {
    throw const FormatException('catalog entry.url 非法（须 https、无 userinfo、含 host）');
  }
  final stdlibMin = json['stdlibMin'];
  if (stdlibMin != null && (stdlibMin is! String || !_reVersion.hasMatch(stdlibMin))) {
    throw const FormatException('catalog entry.stdlibMin 非法（须 x.y.z）');
  }
  final caps = json['capabilities'];
  if (caps is! List || caps.isEmpty) {
    throw const FormatException('catalog entry.capabilities 须为非空数组');
  }
  final capabilities = caps.map((c) {
    if (c is! String || c.isEmpty) {
      throw const FormatException('catalog entry.capabilities 含非字符串/空项');
    }
    // catalog 不得引入 registry 之外的新 capability（见 [kKnownCapabilities]）。
    if (!kKnownCapabilities.contains(c)) {
      throw FormatException('catalog entry.capabilities 含未知能力：$c（不得引入新 capability，fail-closed）');
    }
    return c;
  }).toList(growable: false);

  return CatalogEntry._(
    adapterId: adapterId,
    adapterVersion: adapterVersion,
    digest: digest,
    url: url,
    stdlibMin: stdlibMin as String?,
    capabilities: capabilities,
  );
}

/// bundle 下载 URL 约束（分发边界，红线 #2）：仅 https、须含 host、禁 userinfo（防
/// `https://user:pass@evil/...` 之类伪装）。
bool _isValidBundleUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return uri.scheme == 'https' && uri.hasAuthority && uri.host.isNotEmpty && uri.userInfo.isEmpty;
}

/// 真实日历日校验：[rfc3339] 已过 [_reRfc3339]（故 YYYY-MM-DD 位置固定）。构造 [DateTime.utc]
/// 后比对年月日——归一化会把 2 月 30 日、非闰 2/29、4 月 31 日等改写，比对不符即判非法。
bool _isValidCalendarDate(String rfc3339) {
  final y = int.parse(rfc3339.substring(0, 4));
  final mo = int.parse(rfc3339.substring(5, 7));
  final d = int.parse(rfc3339.substring(8, 10));
  final dt = DateTime.utc(y, mo, d);
  return dt.year == y && dt.month == mo && dt.day == d;
}

void _rejectUnknownKeys(Map<String, dynamic> json, Set<String> allowed, String what) {
  for (final k in json.keys) {
    if (!allowed.contains(k)) {
      throw FormatException('$what 含未知字段：$k（additionalProperties=false，fail-closed）');
    }
  }
}

/// 防回滚原语（纯函数）：仅在 [incoming] 的 sequence **严格大于** [current] 时取 incoming。
/// 相等亦取 current：拒"同序号替换"，杜绝内容被悄改而序号不变的绕过。
/// **两参必为已验签**——类型即约束（只收 [VerifiedCatalog]）。镜像 revocation 的 `pickNewer`。
VerifiedCatalog pickNewerCatalog(VerifiedCatalog current, VerifiedCatalog incoming) =>
    incoming.catalog.sequence > current.catalog.sequence ? incoming : current;

/// TTL 新鲜度原语（纯函数）：`nowMs <= issuedAt + ttl` 且 issuedAt 未超前 [maxFutureSkewMs]。
///
/// **未来时间上限**：issuedAt 超前 now 超过 [maxFutureSkewMs] → 不新鲜（防未来时间戳"保鲜"，
/// 密钥泄露时限制恶意 catalog 有效期）。issuedAt 已在解析时严格校验为可解析 RFC3339。
///
/// "不新鲜" ≠ "不可信"：它已验签，只是过期/超前；采用与否由编排器裁定，本函数只给判据。
bool catalogFresh(
  VerifiedCatalog verified, {
  required int nowMs,
  int maxFutureSkewMs = kDefaultMaxFutureSkewMs,
}) {
  final c = verified.catalog;
  final issuedMs = DateTime.parse(c.issuedAt).millisecondsSinceEpoch;
  if (issuedMs - nowMs > maxFutureSkewMs) return false; // 超前过多 → 不新鲜
  final expiryMs = issuedMs + c.ttlSeconds * 1000;
  return nowMs <= expiryMs;
}
