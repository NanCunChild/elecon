/// 测试用 bundle 夹具 —— 造一份**真实签名**的 digest v2 bundle（ADR-018 §2.9.1）。
///
/// **为何要有这个文件**：digest v2 之前，各测试各自手拼 `BundleEnvelope(...)` 字面量并直接
/// 喂给验签器。v2 之后 bundle 是「envelope 字节 + 内容寻址 blob 表 + 域分隔签名 + gzip 封套」，
/// 手拼一次要写二十行、且**每份手拼都是一份可能与生产实现漂移的影子实现**——正是 ADR-002 §3
/// 风险 5 要防的东西。集中到这里之后：
///  - 测试只描述「这个 bundle 里有哪些文件」，其余全走生产同款编码；
///  - 需要造畸形输入时，从一份**合法**夹具出发做定点破坏，坏在哪里一目了然。
///
/// ⚠ 这里的密钥是**测试夹具**，固定种子派生，不保护任何东西，与生产签名密钥（离线 YubiKey
///   片上生成、永不导出，ADR-002 §2.3）无任何关系。[testAnchorResolver] 造出的信任锚只在
///   测试里注入 `openBundleWith`，**绝不**进 `kTrustAnchors` 预埋集。
library;

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Ed25519, SimpleKeyPair;
import 'package:cryptography/dart.dart' show DartSha256;
import 'package:elecon/core/loader/signature.dart';
import 'package:elecon/core/loader/trust_anchors.dart' show TrustAnchor;
import 'package:elecon/core/loader/verify.dart'
    show AnchorResolver, VerifiedBundle, openBundleWith;

/// 夹具签名所用的 keyId。与生产 keyId 刻意不同名，避免任何混淆。
const String kFixtureKeyId = 'fixture-test-key';

/// 固定种子 → 确定性密钥（Ed25519 本身也是确定性的，RFC 8032）。**仅测试**。
final List<int> _seed = utf8.encode('elecon-test-fixture-seed!!!!!!!!');

SimpleKeyPair? _cachedKeyPair;
String? _cachedPublicHex;

Future<SimpleKeyPair> _keyPair() async =>
    _cachedKeyPair ??= await Ed25519().newKeyPairFromSeed(_seed);

/// 夹具公钥（裸 32 字节 hex）。
Future<String> fixturePublicKeyHex() async {
  if (_cachedPublicHex != null) return _cachedPublicHex!;
  final pub = await (await _keyPair()).extractPublicKey();
  return _cachedPublicHex = _hex(pub.bytes);
}

/// 只认 [kFixtureKeyId] 的信任锚解析器，注入 `openBundleWith` 用。
Future<AnchorResolver> testAnchorResolver() async {
  final hex = await fixturePublicKeyHex();
  return (keyId) => keyId == kFixtureKeyId
      ? TrustAnchor(
          keyId: keyId,
          publicKeyHex: hex,
          active: true,
          note: '测试夹具锚（仅测试）',
        )
      : null;
}

/// 一份造好的 bundle：线上字节 + 造它时用到的中间产物（供定点破坏）。
class BundleFixture {
  const BundleFixture({
    required this.packed,
    required this.envelopeBytes,
    required this.digest,
    required this.signature,
    required this.blobs,
  });

  /// 线上传输字节（`gzip(JSON({envelopeB64, signature, blobs}))`）——喂给 `openBundle`。
  final Uint8List packed;

  /// 被签名的 envelope 字节（`digest == SHA-256(envelopeBytes)`）。
  final Uint8List envelopeBytes;

  final String digest;

  /// 签名对象的 JSON 形态（改一个字段再 [repack] 即可造负例）。
  final Map<String, dynamic> signature;

  /// sha256(hex) → 原始字节。
  final Map<String, Uint8List> blobs;
}

/// 造一份**签名有效**的 bundle。
///
/// [files] 的 key 是 bundle 内路径，value 是文件内容（UTF-8）。必须含 `manifest.json`，
/// 否则身份三方一致（第 11 步）会拒——这正是生产语义，夹具不为测试放宽。
///
/// [adapterId] / [adapterVersion] 缺省从 `manifest.json` 读，与 `buildEnvelope` 同源；
/// 显式传入则用于构造「envelope 顶层身份 ≠ manifest」这类负例。
/// 造 envelope 字节 + blob 表（**不签名**）。
///
/// 需要用**自己的密钥**签名的测试（如 `adapter_launcher_test` 里带完整 catalog/revocation
/// 链路的那些）用这个，然后自行 `serializeSignaturePayload` → 签 → [packWire]。
({Uint8List bytes, Map<String, Uint8List> blobs, String digest})
    buildFixtureEnvelope(
  Map<String, String> files, {
  String adapterId = '',
  String adapterVersion = '',
  String bundleFormat = 'elecon-bundle/2',
}) {
  final blobs = <String, Uint8List>{};
  final descriptors = <Map<String, dynamic>>[];
  for (final entry in files.entries) {
    final raw = Uint8List.fromList(utf8.encode(entry.value));
    final hash = _hex(const DartSha256().hashSync(raw).bytes);
    blobs[hash] = raw;
    descriptors.add({'path': entry.key, 'size': raw.length, 'sha256': hash});
  }
  // 顺序即签名范围的一部分：按路径字典序（与 TS `buildEnvelope` 一致）。
  descriptors
      .sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));

  var id = adapterId;
  var version = adapterVersion;
  final manifestText = files['manifest.json'];
  if (manifestText != null && (id.isEmpty || version.isEmpty)) {
    final m = jsonDecode(manifestText) as Map<String, dynamic>;
    if (id.isEmpty) id = m['adapterId'] as String? ?? '';
    if (version.isEmpty) version = m['adapterVersion'] as String? ?? '';
  }

  // **显式确定性序列化**：固定键序、无空白——镜像 TS `serializeEnvelope`。
  // 不依赖 Dart Map 的插入序"碰巧"与 TS 一致：键序是签名范围的一部分，必须写死。
  final json = '{"bundleFormat":${jsonEncode(bundleFormat)},'
      '"adapterId":${jsonEncode(id)},'
      '"adapterVersion":${jsonEncode(version)},'
      '"files":[${descriptors.map((d) => '{"path":${jsonEncode(d['path'])},'
          '"size":${d['size']},'
          '"sha256":${jsonEncode(d['sha256'])}}').join(',')}]}';
  final bytes = Uint8List.fromList(utf8.encode(json));
  return (
    bytes: bytes,
    blobs: blobs,
    digest: _hex(const DartSha256().hashSync(bytes).bytes),
  );
}

/// 造一份**签名有效**的 bundle（用夹具密钥）。
///
/// [files] 的 key 是 bundle 内路径，value 是文件内容（UTF-8）。通常必须含 `manifest.json`，
/// 否则身份三方一致（第 11 步）会拒——这正是生产语义，夹具不为测试放宽。
///
/// [adapterId] / [adapterVersion] 缺省从 `manifest.json` 读，与 `buildEnvelope` 同源；
/// 显式传入则用于构造「envelope 顶层身份 ≠ manifest」这类负例。
Future<BundleFixture> makeBundle(
  Map<String, String> files, {
  String? adapterId,
  String? adapterVersion,
  String tier = kTierOfficial,
  String bundleFormat = 'elecon-bundle/2',
  String? signAsAdapterId,
  String? signAsAdapterVersion,
}) async {
  final built = buildFixtureEnvelope(
    files,
    adapterId: adapterId ?? '',
    adapterVersion: adapterVersion ?? '',
    bundleFormat: bundleFormat,
  );
  final env = jsonDecode(utf8.decode(built.bytes)) as Map<String, dynamic>;
  final id = env['adapterId'] as String;
  final version = env['adapterVersion'] as String;

  final payload = serializeSignaturePayload(
    adapterId: signAsAdapterId ?? id,
    adapterVersion: signAsAdapterVersion ?? version,
    tier: tier,
    digest: built.digest,
  );
  final sig = await Ed25519().sign(payload, keyPair: await _keyPair());

  final signature = <String, dynamic>{
    'adapterId': signAsAdapterId ?? id,
    'adapterVersion': signAsAdapterVersion ?? version,
    'tier': tier,
    'digest': built.digest,
    'signature': base64.encode(sig.bytes),
    'keyId': kFixtureKeyId,
    'algorithm': 'ed25519',
  };

  return BundleFixture(
    packed: packWire(built.bytes, signature, built.blobs),
    envelopeBytes: built.bytes,
    digest: built.digest,
    signature: signature,
    blobs: built.blobs,
  );
}

/// 打传输封套：`gzip(JSON({envelopeB64, signature, blobs}))`。
///
/// 公开出来是为了让测试能造**定点破坏**的字节（换 blob、改 envelope、加多余字段），
/// 而不必各自复刻一遍编码。
Uint8List packWire(
  Uint8List envelopeBytes,
  Map<String, dynamic> signature,
  Map<String, Uint8List> blobs, {
  Map<String, dynamic> extraWireFields = const {},
}) {
  final wire = <String, dynamic>{
    'envelopeB64': base64.encode(envelopeBytes),
    'signature': signature,
    'blobs': {for (final e in blobs.entries) e.key: base64.encode(e.value)},
    ...extraWireFields,
  };
  return Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(wire))));
}

/// 跑生产验签管线（注入夹具锚），断言通过并返回不可伪造的 [VerifiedBundle]。
Future<VerifiedBundle> verifyFixture(BundleFixture f) async {
  final r = await openBundleWith(f.packed, await testAnchorResolver());
  if (!r.ok) {
    throw StateError('夹具应验过，实际被拒：${r.reason}');
  }
  return r.value!;
}

/// 一份最小可用的 manifest JSON（可覆写任意字段）。
String manifestJson({
  String adapterId = 'school-fixture',
  String adapterVersion = '1.0.0',
  String entry = 'index.js',
  String? stdlibMin = '1.0.0',
  List<String> capabilities = const ['notice.list'],
  Map<String, dynamic> extra = const {},
}) =>
    jsonEncode({
      'schemaVersion': '1.0',
      'adapterId': adapterId,
      'adapterVersion': adapterVersion,
      'capabilities': capabilities,
      'runtime': {'entry': entry, 'stdlibMin': ?stdlibMin},
      ...extra,
    });

String _hex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
