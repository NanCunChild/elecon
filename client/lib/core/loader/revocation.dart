/// 🔒 吊销清单验签 + 判定 —— 客户端信任裁定承重路径（ADR-002 §2.4，红线 #4）。
///
/// 镜像 `tools/src/signer/revocation.ts`。**字节精确**（同 [catalog.dart]）：签端把 RevocationList
/// 序列化恰好一次成 [SignedRevocationList.listJson]，对该原始 UTF-8 字节签名；本文件对同一份字节
/// 验签、验过才 parse，零规范化、零跨语言漂移。
///
/// **信任边界**：验签 + 结构校验全过后铸造不可伪造的 [VerifiedRevocationList]（构造器库私有）。
/// 判定原语（[isRevoked]/[pickNewerRevocation]/[revocationFresh]）只收 [VerifiedRevocationList]，
/// 令未验签清单无法进入受信裁定。
///
/// **持有 [VerifiedRevocationList] ≠ 完成加载裁定**：它只证"清单已验签且结构合法"。是否**采用**
/// （sequence 防回滚 / TTL / last-good 回退 / bootstrap 初值）由编排器 `loader.dart`（待落地）裁定。
///
/// ⚠ 校验字段的正则/日历/规模护栏**镜像自 catalog.dart**；loader 落地时应抽到共享 validators
/// （reviewer 建议）。改动前须两处对齐。
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

const String kRevocationAlgorithm = 'ed25519';

/// TTL 新鲜度允许的未来时钟偏差上限（默认 5 分钟，同 catalog）。
const int kRevocationMaxFutureSkewMs = 5 * 60 * 1000;

// 规模上限（DoS 护栏，同 catalog.dart 的理由）。
const int kMaxRevocationJsonChars = 1 << 20;
const int kMaxRevocationEntries = 4096;
const int kMaxMinVersions = 4096;
const int kMaxReasonChars = 512;
const int _kMaxAdapterIdChars = 128;

// 镜像 catalog.dart 的字段校验（loader 落地时抽共享）。
final RegExp _reAdapterId = RegExp(r'^school-\S+$');
final RegExp _reSemver = RegExp(r'^\d+\.\d+\.\d+$');
final RegExp _reDigest = RegExp(r'^[0-9a-f]{64}$');
final RegExp _reRfc3339 = RegExp(
  r'^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])'
  r'T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(\.\d+)?'
  r'(Z|[+-]([01]\d|2[0-3]):[0-5]\d)$',
);

const Set<String> _listKeys = {
  'sequence',
  'issuedAt',
  'ttlSeconds',
  'minVersions',
  'killSwitch',
  'entries',
};
const Set<String> _entryKeys = {'adapterId', 'digest', 'versionRange', 'reason'};
const Set<String> _rangeKeys = {'minInclusive', 'maxInclusive'};

/// 线上 `revocation.json` 解压后的外层签名信封（字节精确，同 [SignedCatalog]）。
class SignedRevocationList {
  const SignedRevocationList({
    required this.listJson,
    required this.signature,
    required this.keyId,
    required this.algorithm,
  });

  /// 被签名的 RevocationList **原始 JSON 文本**（签/传/验/parse 同一份字节）。
  final String listJson;

  /// Ed25519 签名（base64，裸 64 字节）over `utf8(listJson)`。
  final String signature;
  final String keyId;
  final String algorithm;

  static SignedRevocationList fromJson(Map<String, dynamic> json) {
    String req(String k) {
      final v = json[k];
      if (v is! String || v.isEmpty) {
        throw const FormatException('SignedRevocationList 字段缺失或类型错（fail-closed）');
      }
      return v;
    }

    return SignedRevocationList(
      listJson: req('listJson'),
      signature: req('signature'),
      keyId: req('keyId'),
      algorithm: req('algorithm'),
    );
  }

  /// 裸 64 字节 Ed25519 签名（非 64B 一律拒；同 catalog/bundle 的守卫）。
  Uint8List signatureBytes() {
    final Uint8List raw;
    try {
      raw = Uint8List.fromList(base64.decode(signature));
    } on FormatException catch (e) {
      throw FormatException('revocation signature 非合法 base64：$e（fail-closed）');
    }
    if (raw.length != 64) {
      throw FormatException(
        'Ed25519 签名须为裸 64 字节，得 ${raw.length}（疑封装格式，fail-closed）',
      );
    }
    return raw;
  }
}

/// 版本区间吊销（闭区间；两端可选）。构造器库私有。
class RevocationVersionRange {
  const RevocationVersionRange._({this.minInclusive, this.maxInclusive});
  final String? minInclusive;
  final String? maxInclusive;
}

/// 单条吊销规则。构造器库私有（仅经验签管线解析产出）。至少命中一种匹配即视为吊销。
class RevocationEntry {
  const RevocationEntry._({
    required this.adapterId,
    required this.reason,
    this.digest,
    this.versionRange,
  });

  final String adapterId;

  /// 精确吊销的 bundle digest（64 位小写 hex）。可选。
  final String? digest;

  /// 版本范围吊销。可选。
  final RevocationVersionRange? versionRange;

  final String reason;
}

/// 吊销清单载荷（被签名内容）。构造器库私有。镜像 `revocation.ts` 的 `RevocationList`。
class RevocationList {
  const RevocationList._({
    required this.sequence,
    required this.issuedAt,
    required this.ttlSeconds,
    required this.minVersions,
    required this.killSwitch,
    required this.entries,
  });

  /// 单调递增序号，防回滚（见 [pickNewerRevocation]）。
  final int sequence;

  /// 签发时间（RFC3339，解析时严格校验）。见 [revocationFresh]。
  final String issuedAt;
  final int ttlSeconds;

  /// 每个 adapterId 的最低可加载版本（强制升级）。
  final Map<String, String> minVersions;

  /// 全局 kill-switch：true 时拒绝加载一切 official adapter（密钥泄露急性事件）。
  final bool killSwitch;

  final List<RevocationEntry> entries;
}

/// 🔒 验签通过的证据（不可伪造）。构造器库私有——仅验签管线全过后铸造。
class VerifiedRevocationList {
  const VerifiedRevocationList._({required this.list, required this.keyId});
  final RevocationList list;
  final String keyId;
}

/// 🔒 **生产入口**：对 [SignedRevocationList] 验签（预埋 active pin 公钥）+ 结构校验。
Future<VerifyResult<VerifiedRevocationList>> verifyRevocation(
  SignedRevocationList signed,
) =>
    verifyRevocationWith(signed, activeAnchorByKeyId);

/// 验签管线本体，公钥来源经 [resolveAnchor] 注入（同 catalog/bundle 的接缝理由）。
/// [visibleForTesting]：测试用测试密钥跑同一条管线。**生产代码请用 [verifyRevocation]。**
@visibleForTesting
Future<VerifyResult<VerifiedRevocationList>> verifyRevocationWith(
  SignedRevocationList signed,
  AnchorResolver resolveAnchor,
) async {
  // 0. 规模护栏：验签前按码元数卡上限（避免超大无效输入拖垮 utf8 编码 + Ed25519）。
  if (signed.listJson.length > kMaxRevocationJsonChars) {
    return VerifyResult.fail(
      'revocation 过大：${signed.listJson.length} 码元 > $kMaxRevocationJsonChars → fail-closed',
    );
  }
  // 1. 算法：只认 ed25519（防降级）。
  if (signed.algorithm != kRevocationAlgorithm) {
    return VerifyResult.fail('不支持的 revocation 签名算法：${signed.algorithm} → fail-closed');
  }
  // 2. 公钥：keyId 须命中预埋且 active 的信任锚。
  final anchor = resolveAnchor(signed.keyId);
  if (anchor == null) {
    return VerifyResult.fail(
      'revocation keyId ${signed.keyId} 不在预埋 active 信任锚集合内 → fail-closed',
    );
  }
  // 3. 签名字节：base64 + 裸 64B 守卫。
  final Uint8List sigBytes;
  try {
    sigBytes = signed.signatureBytes();
  } on FormatException catch (e) {
    return VerifyResult.fail('revocation 签名字节不合法：${e.message} → fail-closed');
  }
  // 4. Ed25519 验签 over utf8(listJson)。
  final bool verified;
  try {
    verified = await Ed25519().verify(
      Uint8List.fromList(utf8.encode(signed.listJson)),
      signature: Signature(
        sigBytes,
        publicKey:
            SimplePublicKey(anchor.publicKeyBytes(), type: KeyPairType.ed25519),
      ),
    );
  } on FormatException catch (e) {
    return VerifyResult.fail('revocation 验签输入不合法：${e.message} → fail-closed');
  }
  if (!verified) {
    return VerifyResult.fail('revocation Ed25519 验签失败 → fail-closed');
  }
  // 5. 解析 + 结构校验。
  final Object? decoded;
  try {
    decoded = jsonDecode(signed.listJson);
  } on FormatException catch (e) {
    return VerifyResult.fail('revocation JSON 解析失败：$e → fail-closed');
  }
  if (decoded is! Map<String, dynamic>) {
    return VerifyResult.fail('revocation 载荷不是对象 → fail-closed');
  }
  final RevocationList list;
  try {
    list = _parseList(decoded);
  } on FormatException catch (e) {
    return VerifyResult.fail('${e.message} → fail-closed');
  }
  return VerifyResult.ok(
    VerifiedRevocationList._(list: list, keyId: anchor.keyId),
  );
}

RevocationList _parseList(Map<String, dynamic> json) {
  _rejectUnknownKeys(json, _listKeys, 'revocation');

  final sequence = json['sequence'];
  if (sequence is! int || sequence < 0) {
    throw const FormatException('revocation.sequence 须为非负整数');
  }
  final issuedAt = json['issuedAt'];
  if (issuedAt is! String || !_reRfc3339.hasMatch(issuedAt) || !_isValidCalendarDate(issuedAt)) {
    throw const FormatException('revocation.issuedAt 非法（须合法 RFC3339 日历日）');
  }
  final ttlSeconds = json['ttlSeconds'];
  if (ttlSeconds is! int || ttlSeconds < 0) {
    throw const FormatException('revocation.ttlSeconds 须为非负整数');
  }
  final killSwitch = json['killSwitch'];
  if (killSwitch is! bool) {
    throw const FormatException('revocation.killSwitch 须为布尔');
  }

  final minVersionsRaw = json['minVersions'];
  if (minVersionsRaw is! Map) {
    throw const FormatException('revocation.minVersions 须为对象');
  }
  if (minVersionsRaw.length > kMaxMinVersions) {
    throw FormatException(
      'revocation.minVersions 过多：${minVersionsRaw.length} > $kMaxMinVersions',
    );
  }
  final minVersions = <String, String>{};
  minVersionsRaw.forEach((k, v) {
    if (k is! String || k.length > _kMaxAdapterIdChars || !_reAdapterId.hasMatch(k)) {
      throw const FormatException('revocation.minVersions 键非法（须 school-*）');
    }
    if (v is! String || !_reSemver.hasMatch(v)) {
      throw const FormatException('revocation.minVersions 值非法（须 x.y.z）');
    }
    minVersions[k] = v;
  });

  final entriesRaw = json['entries'];
  if (entriesRaw is! List) {
    throw const FormatException('revocation.entries 须为数组');
  }
  if (entriesRaw.length > kMaxRevocationEntries) {
    throw FormatException(
      'revocation.entries 过多：${entriesRaw.length} > $kMaxRevocationEntries',
    );
  }
  final entries = entriesRaw.map((e) {
    if (e is! Map) throw const FormatException('revocation.entries 含非对象项');
    return _parseEntry(Map<String, dynamic>.from(e));
  }).toList(growable: false);

  return RevocationList._(
    sequence: sequence,
    issuedAt: issuedAt,
    ttlSeconds: ttlSeconds,
    minVersions: Map<String, String>.unmodifiable(minVersions),
    killSwitch: killSwitch,
    entries: entries,
  );
}

RevocationEntry _parseEntry(Map<String, dynamic> json) {
  _rejectUnknownKeys(json, _entryKeys, 'revocation entry');

  final adapterId = json['adapterId'];
  if (adapterId is! String ||
      adapterId.length > _kMaxAdapterIdChars ||
      !_reAdapterId.hasMatch(adapterId)) {
    throw const FormatException('revocation entry.adapterId 非法（须 school-*）');
  }
  final reason = json['reason'];
  if (reason is! String || reason.isEmpty || reason.length > kMaxReasonChars) {
    throw const FormatException('revocation entry.reason 非法（须非空且不超长）');
  }
  final digest = json['digest'];
  if (digest != null && (digest is! String || !_reDigest.hasMatch(digest))) {
    throw const FormatException('revocation entry.digest 非法（须 64 位小写 hex）');
  }
  final rangeRaw = json['versionRange'];
  RevocationVersionRange? range;
  if (rangeRaw != null) {
    if (rangeRaw is! Map) {
      throw const FormatException('revocation entry.versionRange 须为对象');
    }
    final r = Map<String, dynamic>.from(rangeRaw);
    _rejectUnknownKeys(r, _rangeKeys, 'revocation entry.versionRange');
    final lo = r['minInclusive'];
    final hi = r['maxInclusive'];
    if (lo != null && (lo is! String || !_reSemver.hasMatch(lo))) {
      throw const FormatException('versionRange.minInclusive 非法（须 x.y.z）');
    }
    if (hi != null && (hi is! String || !_reSemver.hasMatch(hi))) {
      throw const FormatException('versionRange.maxInclusive 非法（须 x.y.z）');
    }
    if (lo == null && hi == null) {
      throw const FormatException('versionRange 至少须有一个边界');
    }
    range = RevocationVersionRange._(minInclusive: lo as String?, maxInclusive: hi as String?);
  }
  if (digest == null && range == null) {
    // 一条 entry 至少要有 digest 或 versionRange 之一（否则匹配不到任何东西，属畸形）。
    throw const FormatException('revocation entry 须含 digest 或 versionRange 之一');
  }

  return RevocationEntry._(
    adapterId: adapterId,
    reason: reason,
    digest: digest as String?,
    versionRange: range,
  );
}

// ---- 判定（纯函数；只收已验签 [VerifiedRevocationList]） ----

/// 待判定的 adapter 引用。
class AdapterRef {
  const AdapterRef({
    required this.adapterId,
    required this.adapterVersion,
    required this.digest,
  });
  final String adapterId;
  final String adapterVersion;
  final String digest;
}

/// 吊销判定结果。[allowed]=false 时 [reason] 说明原因。
class RevocationDecision {
  const RevocationDecision.allow() : allowed = true, reason = null;
  const RevocationDecision.deny(String this.reason) : allowed = false;
  final bool allowed;
  final String? reason;
}

/// 极简 semver 比较（仅 `x.y.z`）。镜像 `revocation.ts` 的 `compareSemver`。
/// 前置：两参均为已校验 `x.y.z`（[_reSemver]）。
int compareSemver(String a, String b) {
  final pa = a.split('.');
  final pb = b.split('.');
  for (var i = 0; i < 3; i++) {
    final d = (int.tryParse(pa[i]) ?? 0) - (int.tryParse(pb[i]) ?? 0);
    if (d != 0) return d > 0 ? 1 : -1;
  }
  return 0;
}

/// 判定某 adapter 是否被吊销 / 低于最低版本 / 撞 kill-switch。**fail toward less trust**。
/// 纯函数：不拉取、不验签（清单须已 [verifyRevocation]）。
///
/// **relaxed adapterVersion 处理**：catalog 的 adapterVersion 不强制 x.y.z（契约只声明 string）。
/// 若某规则（minVersion / versionRange）**针对本 adapterId** 而 [ref] 版本非 x.y.z，则无法确认它
/// 是否满足下限/落在区间外 → **fail-closed 拒绝**（宁可误拒也不放过可能被吊销的版本）。
RevocationDecision isRevoked(VerifiedRevocationList verified, AdapterRef ref) {
  final list = verified.list;
  if (list.killSwitch) {
    return const RevocationDecision.deny('kill-switch 生效：拒绝加载全部 official adapter');
  }
  final refIsSemver = _reSemver.hasMatch(ref.adapterVersion);

  final min = list.minVersions[ref.adapterId];
  if (min != null) {
    if (!refIsSemver) {
      return RevocationDecision.deny(
        '版本 ${ref.adapterVersion} 非 x.y.z，无法确认满足最低要求 $min → fail-closed',
      );
    }
    if (compareSemver(ref.adapterVersion, min) < 0) {
      return RevocationDecision.deny('版本 ${ref.adapterVersion} 低于最低要求 $min（强制升级）');
    }
  }

  for (final e in list.entries) {
    if (e.adapterId != ref.adapterId) continue;
    if (e.digest != null && e.digest == ref.digest) {
      return RevocationDecision.deny('bundle 被吊销：${e.reason}');
    }
    final r = e.versionRange;
    if (r != null) {
      if (!refIsSemver) {
        return RevocationDecision.deny(
          '版本 ${ref.adapterVersion} 非 x.y.z，无法排除落在被吊销区间 → fail-closed',
        );
      }
      final geMin = r.minInclusive == null || compareSemver(ref.adapterVersion, r.minInclusive!) >= 0;
      final leMax = r.maxInclusive == null || compareSemver(ref.adapterVersion, r.maxInclusive!) <= 0;
      if (geMin && leMax) {
        return RevocationDecision.deny('版本区间被吊销：${e.reason}');
      }
    }
  }
  return const RevocationDecision.allow();
}

/// 防回滚原语：仅在 [incoming] 的 sequence 严格大于 [current] 时取 incoming（拒同序号替换/回滚）。
/// 两参必为已验签（类型即约束）。镜像 `revocation.ts` 的 `pickNewer`。
VerifiedRevocationList pickNewerRevocation(
  VerifiedRevocationList current,
  VerifiedRevocationList incoming,
) =>
    incoming.list.sequence > current.list.sequence ? incoming : current;

/// TTL 新鲜度原语：`nowMs <= issuedAt + ttl` 且 issuedAt 未超前 [maxFutureSkewMs]。
/// issuedAt 已在解析时严格校验为合法 RFC3339 日历日。"不新鲜" ≠ "不可信"（采用与否由编排器裁定）。
bool revocationFresh(
  VerifiedRevocationList verified, {
  required int nowMs,
  int maxFutureSkewMs = kRevocationMaxFutureSkewMs,
}) {
  final issuedMs = DateTime.parse(verified.list.issuedAt).millisecondsSinceEpoch;
  if (issuedMs - nowMs > maxFutureSkewMs) return false;
  return nowMs <= issuedMs + verified.list.ttlSeconds * 1000;
}

// ---- 共享小工具（镜像 catalog.dart；loader 落地时抽共享） ----

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
