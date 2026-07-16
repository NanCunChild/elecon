/// bundle envelope 与传输封装 —— **Dart 侧镜像** `tools/src/bundle/{envelope,package}.ts`
/// （ADR-018 §2.9）。
///
/// 本文件是**验签的前置**：它把线上字节还原成 envelope，并算出内容寻址 digest。
/// 算错不会报错，只会让验签静默失败（好情况）或验过不该验的（灾难）——故与 Node 签端
/// **共享 golden 向量**钉死（`contract/golden/bundle/loader.json`，ADR-002 §3 风险 5）。
///
/// **为何 Dart 侧不需要 NFC / 换行规范化**（关键，勿"补全"）：规范化（UTF-8 NFC + LF，
/// ADR-002 §2.3b）发生在**签端从目录构建 envelope 时**；envelope 里存的已是规范化后的字节，
/// `envelopeDigest` 只对这些字节做双层 SHA-256。加载器从不面对目录，只面对 envelope，
/// 故**无需也不得**再做规范化——Dart 无内建 Unicode NFC，若在此引入第三方规范化实现，
/// 反而会制造 ADR-002 §3 风险 5 所警告的跨语言漂移。
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
const String kBundleFormat = 'elecon-bundle/1';

/// envelope 内的一个文件。[content] 依 [encoding] 解码后即**参与 digest 的规范化字节**。
class EnvelopeFile {
  const EnvelopeFile({
    required this.path,
    required this.encoding,
    required this.content,
  });

  /// 相对 adapter 目录的路径。
  final String path;

  /// `utf-8`（文本，规范化后原样）或 `base64`（二进制资产）。
  final String encoding;

  final String content;

  /// 解码回参与 digest 的字节。
  ///
  /// **未知 encoding 一律抛**（不猜、不回退）：镜像 `fileBytes` 的二分支语义，
  /// 但 TS 那侧是 `encoding === 'utf-8' ? utf8 : base64`——若将来签端新增编码而此处
  /// 静默按 base64 解，会得到**错误字节却仍算出某个 digest**。故此处 fail-closed。
  Uint8List bytes() {
    switch (encoding) {
      case 'utf-8':
        return Uint8List.fromList(utf8.encode(content));
      case 'base64':
        // 畸形 base64 必须落地为 BundleFormatException（fail-closed），否则裸 FormatException
        // 会穿透 verify.dart 只 catch BundleFormatException 的各步 → crash 而非拒绝。
        try {
          return Uint8List.fromList(base64.decode(content));
        } on FormatException catch (e) {
          throw BundleFormatException('文件 $path 的 base64 非法：$e（fail-closed）');
        }
      default:
        throw BundleFormatException('未知 envelope 文件编码：$encoding（fail-closed）');
    }
  }

  static EnvelopeFile fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    final encoding = json['encoding'];
    final content = json['content'];
    if (path is! String || encoding is! String || content is! String) {
      throw BundleFormatException('envelope 文件项字段缺失或类型错（fail-closed）');
    }
    return EnvelopeFile(path: path, encoding: encoding, content: content);
  }
}

/// 签名对象本体。**adapterId/version 不在顶层**——权威身份在 `files` 里的 manifest.json
/// （已被 digest 覆盖），不设二源（ADR-002 §2.2，见 [readEnvelopeIdentity]）。
class BundleEnvelope {
  const BundleEnvelope({required this.bundleFormat, required this.files});

  final String bundleFormat;
  final List<EnvelopeFile> files;

  static BundleEnvelope fromJson(Map<String, dynamic> json) {
    final format = json['bundleFormat'];
    final files = json['files'];
    if (format is! String) {
      throw BundleFormatException('envelope 缺 bundleFormat（fail-closed）');
    }
    if (files is! List) {
      throw BundleFormatException('envelope 缺 files（fail-closed）');
    }
    return BundleEnvelope(
      bundleFormat: format,
      files: files.map((f) {
        if (f is! Map) {
          throw const BundleFormatException(
            'envelope files 含非对象项（fail-closed）',
          );
        }
        return EnvelopeFile.fromJson(Map<String, dynamic>.from(f));
      }).toList(growable: false),
    );
  }
}

/// bundle 结构/格式异常。与"验签不通过"分开：前者是**畸形输入**，后者是**信任裁定**。
class BundleFormatException implements Exception {
  const BundleFormatException(this.message);
  final String message;
  @override
  String toString() => 'BundleFormatException: $message';
}

/// adapter 的权威身份（取自 envelope 内 manifest.json）。
class EnvelopeIdentity {
  const EnvelopeIdentity(
      {required this.adapterId, required this.adapterVersion});
  final String adapterId;
  final String adapterVersion;
}

/// 从 envelope 内 `manifest.json` 读**权威身份**——镜像 `readEnvelopeManifest`。
///
/// 这是身份的**唯一来源**。签名载荷里也带 adapterId/version，但那是**待核对的声明**，
/// 不是事实：若采信它，一份「digest 覆盖内容 A、载荷写身份 B」的签名就能验过，而运行时
/// 用的是 bundle 内 manifest（它决定 allow / credentials 注入范围）→ 身份混淆
/// （ADR-002 §2.2）。manifest.json 本身在 digest 覆盖范围内，故身份与内容结构性绑定。
EnvelopeIdentity readEnvelopeIdentity(BundleEnvelope env) {
  EnvelopeFile? manifestFile;
  for (final f in env.files) {
    if (f.path == 'manifest.json') {
      manifestFile = f;
      break;
    }
  }
  if (manifestFile == null) {
    throw const BundleFormatException(
      'envelope 缺 manifest.json → 无法确定权威身份（fail-closed）',
    );
  }
  // manifest 的 utf8/JSON 解码失败也须落地为 BundleFormatException（fail-closed）——
  // 否则裸 FormatException 穿透 verify.dart 的 `on BundleFormatException` → crash。
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(manifestFile.bytes()));
  } on FormatException catch (e) {
    throw BundleFormatException(
        'envelope 内 manifest.json 无法解码：$e（fail-closed）');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const BundleFormatException(
        'envelope 内 manifest.json 不是对象（fail-closed）');
  }
  final id = decoded['adapterId'];
  final version = decoded['adapterVersion'];
  if (id is! String || id.isEmpty || version is! String || version.isEmpty) {
    throw const BundleFormatException(
      'envelope 内 manifest.json 缺 adapterId/adapterVersion（fail-closed）',
    );
  }
  return EnvelopeIdentity(adapterId: id, adapterVersion: version);
}

/// envelope digest = `SHA-256( SHA-256(file1) || SHA-256(file2) || … )`，**按路径字典序**。
///
/// 镜像 `envelopeDigest`（`tools/src/bundle/envelope.ts`）与 signer 的 `computeBundleDigest`。
///
/// **排序**：TS 侧用 `a.path < b.path`（UTF-16 码元序）；Dart [String.compareTo] 同为
/// UTF-16 码元序，故一致。**切勿**改用 locale 敏感的排序——那会在含非 ASCII 路径时静默漂移
/// （ADR-002 §3 风险 5 正是此类）。排序在**本函数内**做，不依赖调用方给的顺序（golden 里
/// 的 files 刻意乱序即为钉死这一点）。
String envelopeDigest(BundleEnvelope env) {
  final sorted = [...env.files]..sort((a, b) => a.path.compareTo(b.path));
  final sha = const DartSha256();
  final parts = BytesBuilder(copy: false);
  for (final f in sorted) {
    parts.add(sha.hashSync(f.bytes()).bytes);
  }
  return _hex(sha.hashSync(parts.takeBytes()).bytes);
}

String _hex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// 拆包结果：envelope + 可选 detached 签名。
class UnpackedBundle {
  const UnpackedBundle({required this.envelope, this.signature});
  final BundleEnvelope envelope;
  final Map<String, dynamic>? signature;
}

/// `gzip(JSON({envelope, signature}))` → 结构化。镜像 `unpackBundle`。
///
/// ⚠ 拆包**不代表可信**：这里只做格式还原，任何信任裁定都在 `verify.dart`。
///   调用方拿到 [UnpackedBundle] 后**不得**直接使用其内容。
UnpackedBundle unpackBundle(Uint8List gz) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(gzip.decode(gz)));
  } on FormatException catch (e) {
    throw BundleFormatException('bundle 解码失败：$e（fail-closed）');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const BundleFormatException('bundle 载荷不是对象（fail-closed）');
  }
  final env = decoded['envelope'];
  if (env is! Map<String, dynamic>) {
    throw const BundleFormatException('bundle 缺 envelope（fail-closed）');
  }
  final sig = decoded['signature'];
  return UnpackedBundle(
    envelope: BundleEnvelope.fromJson(env),
    signature: sig is Map<String, dynamic> ? sig : null,
  );
}
