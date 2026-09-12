/// bundle 信封 v2 与传输封套 —— **Dart 侧镜像** `tools/src/bundle/{envelope,package}.ts`
/// （ADR-018 §2.9.1，digest v2）。
///
/// 本文件是**验签的前置**：它把线上字节还原成可校验的结构，并算出内容寻址 digest。
/// 算错不会报错，只会让验签静默失败（好情况）或验过不该验的（灾难）——故与 Node 签端
/// **共享 golden 向量**钉死（`contract/golden/bundle/loader.json`，ADR-002 §3 风险 5）。
///
///     envelope = { bundleFormat, adapterId, adapterVersion, files:[{path,size,sha256}] }
///     digest   = SHA-256( envelopeBytes )
///     on-wire  = gzip(JSON({ envelopeB64, signature, blobs }))   ← 传输封套，**不是**信封
///
/// **v1 与 v2 的分水岭**：v1 的 envelope 同时当容器（装文件内容）和清单（声明有哪些文件），
/// 唯一没被签的字段恰是 `path` → 保序重命名可让 official 签名背书恶意入口。v2 把容器拆出去，
/// 路径 / 大小 / 顺序 / 文件个数 / 格式标识 / 身份**全都落在那串被哈希的字节里**。
///
/// **本文件只做「还原 + 结构校验」，不做任何信任裁定**——裁定在 `verify.dart`。
/// 尤其：[parseEnvelope] **必须在验签之后**才被调用（纪律 2：验签先于解析）。为此本文件
/// 刻意**不提供**「一步到位从 gz 拿到 envelope」的函数：唯一的组装入口是 `verify.dart`
/// 的 `openBundle`，它把 1–11 步按不可重排的顺序走完。
///
/// **为何 Dart 侧不做 NFC 规范化**（关键，勿"补全"）：Dart 无内建 Unicode NFC，引入第三方
/// 实现反而制造跨语言漂移（ADR-002 §3 风险 5 正是此类）。v2 起改由**收紧字符集**根除该问题：
/// 路径段限定为 `[A-Za-z0-9._-]`（见 [assertPathHygiene]），该集合内不存在非 NFC 形式，
/// 于是"要不要做 NFC"这个问题在两端都不再存在——而不是两端各自给出不同答案。
///
/// **零自研归档解析**（ADR-018 §2.9 修订理由）：on-wire = `gzip(JSON)`，两端都用内建 codec
/// （node:zlib ↔ Dart [GZipCodec]）。当初弃用手写 tar 正是为了让 🔒 加载器不必解析自研归档格式。
///
/// 🔒 红线 #4 承重件（仅官方签名加载）：改动须人工 + 安全清单复核，不得 AI 独自闭环。
library;

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:cryptography/dart.dart' show DartSha256;

/// envelope 格式标识。与 `tools/src/bundle/envelope.ts` 的 `BUNDLE_FORMAT` 同值。
///
/// **严格相等**（非前缀匹配）：宽容会在 v3 出现时变成降级面（纪律 6）。
const String kBundleFormat = 'elecon-bundle/3';

/// 压缩输入上限（粗闸门）：合法 bundle 压缩后远小于此；超限直接拒，不进解压。
const int kMaxBundleGzBytes = 512 * 1024;

/// 解压载荷上限（**压缩炸弹护栏**）。与 TS `MAX_BUNDLE_PAYLOAD_BYTES` 对齐。
const int kMaxBundlePayloadBytes = 1024 * 1024;

/// bundle 结构/格式异常。与"验签不通过"分开：前者是**畸形输入**，后者是**信任裁定**。
class BundleFormatException implements Exception {
  const BundleFormatException(this.message);
  final String message;
  @override
  String toString() => 'BundleFormatException: $message';
}

/// 单个文件在清单里的**描述符**——不含内容，内容由 blob 表按 [sha256] 寻址。
class EnvelopeFileDescriptor {
  const EnvelopeFileDescriptor({
    required this.path,
    required this.size,
    required this.sha256,
  });

  /// 相对 adapter 目录的路径。**在签名范围内**（v2 的核心修复）。
  final String path;

  /// 文件字节数。**先按它界定再解码**，防 endless-data（同 TUF 携带 length 的理由）。
  final int size;

  /// 文件内容的 SHA-256（小写 hex）。blob 表的寻址键。
  final String sha256;
}

/// 解析后的 bundle 信封。
///
/// [adapterId] / [adapterVersion] 是权威身份的**核对副本**——权威值仍在 `manifest.json`
/// （见 [readEnvelopeIdentity]）；此处只用于核对，不用于裁定（ADR-002 §2.2）。
class BundleEnvelope {
  const BundleEnvelope({
    required this.bundleFormat,
    required this.adapterId,
    required this.adapterVersion,
    required this.files,
  });

  final String bundleFormat;
  final String adapterId;
  final String adapterVersion;
  final List<EnvelopeFileDescriptor> files;
}

/// 信封 + 它的**原始字节**。
///
/// 字节是第一性的：digest 与签名都只认这串字节。任何拿到 [ParsedEnvelope] 的代码
/// **都不得**重新序列化 [envelope] 去算 digest——那等于把 canonical JSON 的全部漂移面
/// 请回来（纪律 1）。Dart 侧因此**根本没有** envelope 序列化函数，只有解析。
class ParsedEnvelope {
  const ParsedEnvelope({required this.envelope, required this.bytes});
  final BundleEnvelope envelope;
  final Uint8List bytes;
}

/// blob 表：`sha256`（小写 hex）→ 原始字节。
typedef BlobTable = Map<String, Uint8List>;

/// adapter 的权威身份（取自 envelope 内 manifest.json）。
class EnvelopeIdentity {
  const EnvelopeIdentity({
    required this.adapterId,
    required this.adapterVersion,
  });
  final String adapterId;
  final String adapterVersion;
}

final RegExp _reSha256 = RegExp(r'^[0-9a-f]{64}$');

String _hex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List _sha256(List<int> bytes) =>
    Uint8List.fromList(const DartSha256().hashSync(bytes).bytes);

/// digest v2 = `SHA-256(envelopeBytes)`。
///
/// **只接受字节**——这是纪律 1 的类型级落实：没有接受 [BundleEnvelope] 的重载，
/// 调用方无从"解析成对象再哈希"。
String envelopeDigest(Uint8List envelopeBytes) => _hex(_sha256(envelopeBytes));

// ---- 步骤 1–3：有界 gunzip → 解析传输封套 → 解码 envelopeBytes ----

/// 传输封套拆出来的三件东西。**尚未做任何校验**。
class WireParts {
  const WireParts({
    required this.signatureJson,
    required this.envelopeBytes,
    required this.blobs,
  });

  /// `signature` 字段的原始 JSON（形状校验在 `SignatureFile.fromJson`）。
  final Map<String, dynamic> signatureJson;

  /// base64 解码后的 envelope 字节。**digest 与签名只认这一串。**
  final Uint8List envelopeBytes;

  final BlobTable blobs;
}

/// 有界 gunzip：压缩输入 ≤ [kMaxBundleGzBytes]，解压输出 ≤ [kMaxBundlePayloadBytes]。
/// 解压边解边计数，一超上限即抛，**CPU/内存都封顶**在上限附近（不把整个炸弹解完）。
Uint8List boundedGunzip(
  Uint8List gz, {
  int maxCompressedBytes = kMaxBundleGzBytes,
  int maxOutputBytes = kMaxBundlePayloadBytes,
}) {
  if (gz.length > maxCompressedBytes) {
    throw BundleFormatException(
      'gzip 压缩体过大：${gz.length} > $maxCompressedBytes（fail-closed）',
    );
  }
  final sink = _BoundedByteSink(maxOutputBytes);
  final input = gzip.decoder.startChunkedConversion(sink);
  try {
    input.add(gz);
    input.close();
  } on FormatException catch (e) {
    throw BundleFormatException('gzip 解码失败：$e（fail-closed）');
  }
  return sink.takeBytes();
}

class _BoundedByteSink implements Sink<List<int>> {
  _BoundedByteSink(this._limit);
  final int _limit;
  final BytesBuilder _b = BytesBuilder(copy: false);
  int _total = 0;

  @override
  void add(List<int> chunk) {
    _total += chunk.length;
    if (_total > _limit) {
      throw BundleFormatException('bundle 解压体超上限 $_limit（fail-closed，疑压缩炸弹）');
    }
    _b.add(chunk);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _b.takeBytes();
}

/// 步骤 1–3：有界 gunzip → 解析**传输封套** → base64 解码 envelopeBytes。
///
/// **这是验签之前唯一允许的解析**，故其解析面必须最小：恰三个字段，多一个即拒。
/// 任何「多余字段先忽略着」的宽容，都是攻击者在验签前可以自由投喂的输入。
///
/// ⚠ 拆出来**不代表可信**：这里只做格式还原，任何信任裁定都在 `verify.dart`。
WireParts readWire(Uint8List gz) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(boundedGunzip(gz)));
  } on FormatException catch (e) {
    throw BundleFormatException('传输封套解码失败：$e（fail-closed）');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const BundleFormatException('传输封套不是对象（fail-closed）');
  }
  for (final k in decoded.keys) {
    if (k != 'envelopeB64' && k != 'signature' && k != 'blobs') {
      throw BundleFormatException('传输封套含多余字段 "$k"（fail-closed）');
    }
  }
  final envB64 = decoded['envelopeB64'];
  if (envB64 is! String) {
    throw const BundleFormatException('传输封套缺 envelopeB64（fail-closed）');
  }
  final sig = decoded['signature'];
  if (sig is! Map<String, dynamic>) {
    throw const BundleFormatException('传输封套缺 signature（fail-closed）');
  }
  final rawBlobs = decoded['blobs'];
  if (rawBlobs is! Map<String, dynamic>) {
    throw const BundleFormatException('传输封套缺 blobs（fail-closed）');
  }

  final Uint8List envelopeBytes;
  try {
    envelopeBytes = decodeCanonicalBase64(envB64);
  } on FormatException catch (e) {
    throw BundleFormatException('envelopeB64 非规范 base64：$e（fail-closed）');
  }
  if (envelopeBytes.isEmpty) {
    throw const BundleFormatException('envelopeBytes 为空（fail-closed）');
  }
  if (envelopeBytes.length > kMaxBundlePayloadBytes) {
    throw const BundleFormatException('envelopeBytes 超上限（fail-closed）');
  }

  final blobs = <String, Uint8List>{};
  for (final entry in rawBlobs.entries) {
    final v = entry.value;
    if (v is! String) {
      throw BundleFormatException('blob ${entry.key} 非 base64 字符串（fail-closed）');
    }
    try {
      blobs[entry.key] = decodeCanonicalBase64(v);
    } on FormatException catch (e) {
      throw BundleFormatException('blob ${entry.key} 非规范 base64：$e（fail-closed）');
    }
  }

  return WireParts(
    signatureJson: sig,
    envelopeBytes: envelopeBytes,
    blobs: blobs,
  );
}

// ---- 步骤 7：严格解析 envelope（**验签之后**才允许调用，纪律 2） ----

/// 严格解析 envelope 字节。**验签之后才允许调用。**
///
/// 严格性是防降级面：多余字段、缺字段、错类型、[kBundleFormat] 不等一律拒。
ParsedEnvelope parseEnvelope(Uint8List bytes) {
  final Object? raw;
  try {
    raw = jsonDecode(utf8.decode(bytes));
  } on FormatException catch (e) {
    throw BundleFormatException('envelope 不是合法 JSON：$e（fail-closed）');
  }
  if (raw is! Map<String, dynamic>) {
    throw const BundleFormatException('envelope 不是对象（fail-closed）');
  }
  for (final k in raw.keys) {
    if (k != 'bundleFormat' &&
        k != 'adapterId' &&
        k != 'adapterVersion' &&
        k != 'files') {
      throw BundleFormatException('envelope 含未知字段 "$k"（fail-closed）');
    }
  }
  final format = raw['bundleFormat'];
  if (format != kBundleFormat) {
    throw BundleFormatException(
      'bundleFormat 不符：期望 $kBundleFormat，得 $format（fail-closed）',
    );
  }
  final id = raw['adapterId'];
  if (id is! String || id.isEmpty) {
    throw const BundleFormatException('envelope 缺 adapterId（fail-closed）');
  }
  final version = raw['adapterVersion'];
  if (version is! String || version.isEmpty) {
    throw const BundleFormatException('envelope 缺 adapterVersion（fail-closed）');
  }
  final rawFiles = raw['files'];
  if (rawFiles is! List) {
    throw const BundleFormatException('envelope.files 不是数组（fail-closed）');
  }

  final files = <EnvelopeFileDescriptor>[];
  for (var i = 0; i < rawFiles.length; i++) {
    final entry = rawFiles[i];
    if (entry is! Map<String, dynamic>) {
      throw BundleFormatException('envelope.files[$i] 不是对象（fail-closed）');
    }
    for (final k in entry.keys) {
      if (k != 'path' && k != 'size' && k != 'sha256') {
        throw BundleFormatException('envelope.files[$i] 含未知字段 "$k"（fail-closed）');
      }
    }
    final path = entry['path'];
    if (path is! String) {
      throw BundleFormatException('envelope.files[$i].path 非字符串（fail-closed）');
    }
    final size = entry['size'];
    if (size is! int || size < 0) {
      throw BundleFormatException('envelope.files[$i].size 非非负整数（fail-closed）');
    }
    final hash = entry['sha256'];
    if (hash is! String || !_reSha256.hasMatch(hash)) {
      throw BundleFormatException(
        'envelope.files[$i].sha256 非 64 位小写 hex（fail-closed）',
      );
    }
    files.add(EnvelopeFileDescriptor(path: path, size: size, sha256: hash));
  }

  return ParsedEnvelope(
    envelope: BundleEnvelope(
      bundleFormat: format,
      adapterId: id,
      adapterVersion: version,
      files: files,
    ),
    bytes: bytes,
  );
}

// ---- 步骤 8：路径卫生闸门（验签**之后**、使用**之前**，纪律 3） ----

/// 合法路径段：`[A-Za-z0-9._-]`，至少一字符。
///
/// **为何收紧到 ASCII 子集**：TS 侧靠 `String.normalize("NFC")` 拒非 NFC 路径，而 Dart
/// 无内建 Unicode NFC。若 Dart 略过该检查，两端的卫生闸门就对同一份 bundle 给出**不同**
/// 判定——这正是 ADR-002 §3 风险 5（跨语言实现漂移）的活样本，且方向是 fail-open。
/// 引入第三方 NFC 实现只会把漂移面换个地方。
///
/// 故改从源头消灭：本集合内**不存在**非 NFC 形式，也不存在同形异码（homoglyph）与
/// RTL override 之类的显示欺骗，于是"要不要做 NFC"在两端都不再是问题。代价是 adapter
/// 内文件名不得使用非 ASCII——现有全部 adapter 均已满足，且这是**内部打包路径**，
/// 与任何面向用户的展示文本无关。
final RegExp _reSegment = RegExp(r'^[A-Za-z0-9._-]+$');

/// 路径卫生。**签名只证明发布者确实想要这些路径，不证明路径安全**——
/// 哈希再多字节也不会让 `../../` 变安全。
///
/// **重复路径不是纯纵深防御**：Dart [List.sort] 不保证稳定而 TS `Array.sort` 保证，
/// 同名条目会造成跨语言解析差分（ADR-002 §3 风险 5）。
void assertPathHygiene(BundleEnvelope env) {
  final seen = <String>{};
  for (final f in env.files) {
    final p = f.path;
    if (p.isEmpty) {
      throw const BundleFormatException('路径为空（fail-closed）');
    }
    if (p.startsWith('/')) {
      throw BundleFormatException('绝对路径（POSIX）：$p（fail-closed）');
    }
    if (RegExp(r'^[A-Za-z]:').hasMatch(p)) {
      throw BundleFormatException('绝对路径（Windows 盘符）：$p（fail-closed）');
    }
    if (p.endsWith('/')) {
      throw BundleFormatException('尾随分隔符：$p（fail-closed）');
    }
    for (final seg in p.split('/')) {
      if (seg.isEmpty || seg == '.' || seg == '..') {
        throw BundleFormatException('非法路径段 "$seg" 于 $p（fail-closed）');
      }
      // 反斜杠、NUL、非 ASCII 等全部落在这一条里（字符集白名单，而非逐类黑名单）。
      if (!_reSegment.hasMatch(seg)) {
        throw BundleFormatException(
          '路径段 "$seg" 含 [A-Za-z0-9._-] 之外的字符于 $p（fail-closed）',
        );
      }
    }
    if (!seen.add(p)) {
      throw BundleFormatException('重复路径：$p（fail-closed）');
    }
  }
}

// ---- 步骤 9–10：blob 校验（纪律 4） ----

/// blob 集合**精确相等**：descriptor 的 `sha256` 集合 ↔ blob 键集合一一对应。
///
/// **这是 v2 唯一新增的、可以搞砸的不变量**：少一个会被 [assertBlobsMatchDescriptors]
/// 抓到，**多一个不会**——必须由本函数显式拒绝，否则就是夹带通道。
void assertBlobSetExact(BundleEnvelope env, BlobTable blobs) {
  final want = <String>{for (final f in env.files) f.sha256};
  for (final h in blobs.keys) {
    if (!_reSha256.hasMatch(h)) {
      throw BundleFormatException('blob 键非 64 位小写 hex："$h"（fail-closed）');
    }
    if (!want.contains(h)) {
      throw BundleFormatException(
        'blob 表多出未被引用的条目 ${_short(h)}（夹带通道，fail-closed）',
      );
    }
  }
  for (final h in want) {
    if (!blobs.containsKey(h)) {
      throw BundleFormatException(
        'blob 表缺 ${_short(h)}（descriptor 引用了不存在的 blob，fail-closed）',
      );
    }
  }
}

/// 逐文件：长度**精确等于** `size`，且 SHA-256 命中 descriptor。
void assertBlobsMatchDescriptors(BundleEnvelope env, BlobTable blobs) {
  for (final f in env.files) {
    final blob = blobs[f.sha256];
    if (blob == null) {
      throw BundleFormatException('blob 缺失：${f.path}（fail-closed）');
    }
    if (blob.length != f.size) {
      throw BundleFormatException(
        '${f.path} 长度 ${blob.length} ≠ descriptor.size ${f.size}（fail-closed）',
      );
    }
    final actual = _hex(_sha256(blob));
    if (actual != f.sha256) {
      throw BundleFormatException(
        '${f.path} 内容哈希 ${_short(actual)} ≠ descriptor ${_short(f.sha256)}（fail-closed）',
      );
    }
  }
}

/// 按路径取文件字节（校验通过后使用）。路径不在清单内 → null。
Uint8List? fileBytesByPath(BundleEnvelope env, BlobTable blobs, String path) {
  for (final f in env.files) {
    if (f.path == path) return blobs[f.sha256];
  }
  return null;
}

// ---- 步骤 11：身份三方一致 ----

/// **身份三方一致**（ADR-002 §2.2 加强版）：
/// `签名载荷` ↔ `envelope 顶层` ↔ `manifest.json 内容`，任一不符即 fail-closed。
///
/// `manifest.json` 仍是运行时策略的唯一权威源；envelope 顶层身份**只用于核对，不用于裁定**。
/// 若采信任一单点，一份「digest 覆盖内容 A、身份写 B」的签名就能验过，而运行时用的是
/// bundle 内 manifest（它决定 allow / credentials 注入范围）→ 身份混淆。
void assertIdentityTriple(
  BundleEnvelope env,
  BlobTable blobs,
  EnvelopeIdentity signatureIdentity,
) {
  final fromManifest = readEnvelopeIdentity(env, blobs);
  if (env.adapterId != fromManifest.adapterId ||
      env.adapterVersion != fromManifest.adapterVersion) {
    throw BundleFormatException(
      'envelope 顶层身份 ${env.adapterId}@${env.adapterVersion} ≠ '
      'manifest.json ${fromManifest.adapterId}@${fromManifest.adapterVersion}'
      '（fail-closed，ADR-002 §2.2）',
    );
  }
  if (signatureIdentity.adapterId != env.adapterId ||
      signatureIdentity.adapterVersion != env.adapterVersion) {
    throw BundleFormatException(
      '签名载荷身份 ${signatureIdentity.adapterId}@${signatureIdentity.adapterVersion} ≠ '
      'envelope 顶层 ${env.adapterId}@${env.adapterVersion}（fail-closed，ADR-002 §2.2）',
    );
  }
}

/// 从 envelope 内 `manifest.json` 读**权威身份**。
EnvelopeIdentity readEnvelopeIdentity(BundleEnvelope env, BlobTable blobs) {
  final decoded = readEnvelopeManifestJson(env, blobs);
  final id = decoded['adapterId'];
  final version = decoded['adapterVersion'];
  if (id is! String || id.isEmpty || version is! String || version.isEmpty) {
    throw const BundleFormatException(
      'envelope 内 manifest.json 缺 adapterId/adapterVersion（fail-closed）',
    );
  }
  return EnvelopeIdentity(adapterId: id, adapterVersion: version);
}

/// stdlibMin 版本形态 = x.y.z（逐字镜像 contract manifest.schema 的 `runtime.stdlibMin` pattern）。
final RegExp _reStdlibVersion = RegExp(r'^\d+\.\d+\.\d+$');

/// 从 envelope 内 manifest 读 **adapter 声明的 stdlibMin**（`runtime.stdlibMin`）。
///
/// 这是 stdlibMin 门（`stdlib_gate.dart`）的**权威输入**：stdlibMin 在 manifest 内、已被 digest
/// 覆盖，随 bundle 一起被验签；catalog 里的同名字段只是**预下载提示**，不作数。
///
/// 返回值语义：
///  - `null` = **未声明下限**（contract：`runtime.stdlibMin` 可选，缺省=不设下限）——非错误。
///  - `runtime` 缺失或非对象 → [BundleFormatException]（fail-closed）：manifest.schema 要求
///    `runtime` **必存在且为对象**，故缺失/数组/字符串等皆属畸形已签名内容。不把非对象
///    `runtime` 静默当作"无下限"放行（那是 fail-open 缺口）。
///  - `stdlibMin` 声明了但非 x.y.z → [BundleFormatException]（fail-closed）。
String? readEnvelopeStdlibMin(BundleEnvelope env, BlobTable blobs) {
  final manifest = readEnvelopeManifestJson(env, blobs);
  final runtime = manifest['runtime'];
  if (runtime is! Map) {
    throw const BundleFormatException(
      'manifest.runtime 缺失或非对象（manifest.schema 要求存在且为对象）（fail-closed）',
    );
  }
  final min = runtime['stdlibMin'];
  if (min == null) return null;
  if (min is! String || !_reStdlibVersion.hasMatch(min)) {
    throw const BundleFormatException(
      'manifest.runtime.stdlibMin 非法（须 x.y.z）（fail-closed）',
    );
  }
  return min;
}

/// 读取并解码 envelope 内 `manifest.json` 为原始 JSON map。
///
/// 供接线层（`adapter_launcher.dart`）取权威的 `runtime.entry` / `network.allow` /
/// `credentials` / `capabilities`——它们都在 digest 覆盖范围内（ADR-002 §2.2 权威身份/策略之源，
/// 非 catalog 提示、非 adapter 运行时自报）。缺失 / 非对象 / 畸形 → [BundleFormatException]。
Map<String, dynamic> readEnvelopeManifestJson(
  BundleEnvelope env,
  BlobTable blobs,
) {
  final manifestBytes = fileBytesByPath(env, blobs, 'manifest.json');
  if (manifestBytes == null) {
    throw const BundleFormatException(
      'envelope 缺 manifest.json → 无法确定权威身份/运行时要求（fail-closed）',
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(manifestBytes));
  } on FormatException catch (e) {
    throw BundleFormatException(
      'envelope 内 manifest.json 无法解码：$e（fail-closed）',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw const BundleFormatException(
      'envelope 内 manifest.json 不是对象（fail-closed）',
    );
  }
  return decoded;
}

String _short(String d) => d.length <= 12 ? d : '${d.substring(0, 12)}…';

/// 🔒 严格（规范）base64 解码（ADR-018 §2.9.1 第 3 步「非规范 base64 拒」）。
///
/// Dart 的 [base64.decode] 已拒空白、字母表外字符、错误填充，但**同时接受 URL-safe 字母表**
/// （`-`/`_`）；TS 端 `decodeCanonicalBase64` 只认标准字母表。两端对同一份封套必须同判
/// （ADR-002 §3 风险 5），故此处再要求 re-encode 逐字等于原串——这一条把 URL-safe 与任何
/// 非规范形一并拒掉。
Uint8List decodeCanonicalBase64(String s) {
  final bytes = Uint8List.fromList(base64.decode(s));
  if (base64.encode(bytes) != s) {
    throw const FormatException('re-encode 与原串不等（非规范形）');
  }
  return bytes;
}
