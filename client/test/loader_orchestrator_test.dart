/// 🔒 加载编排器 `loader.dart` —— ADR-018 §2.6 全序端到端。
///
/// bundle 复用 `contract/golden/bundle/loader.json`（school-golden@1.2.3，digest 已知，含真实签名）；
/// catalog / revocation 在测试内用 Dart 现生成的 Ed25519 key 签发（entry.digest 对齐 bundle golden），
/// 三个 verifier 各注入对应测试锚——生产路径用真实 pin，此处走同一条编排逻辑。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Ed25519, KeyPair;
import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/loader/bootstrap.dart';
import 'package:elecon/core/loader/bundle.dart';
import 'package:elecon/core/loader/bundle_cache.dart';
import 'package:elecon/core/loader/catalog.dart';
import 'package:elecon/core/loader/last_good_store.dart';
import 'package:elecon/core/loader/loader.dart';
import 'package:elecon/core/loader/revocation.dart';
import 'package:elecon/core/loader/signature.dart';
import 'package:elecon/core/loader/trust_anchors.dart';
import 'package:elecon/core/loader/verify.dart';
import 'package:elecon/core/trust/trusted_context.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

// ── golden bundle ────────────────────────────────────────────────────────
Map<String, dynamic> _loaderGolden() =>
    readJson(repoPath('contract/golden/bundle/loader.json'));

// ── 测试内签发工具 ───────────────────────────────────────────────────────
String _hex(List<int> b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

class _Signer {
  _Signer(this.keyPair, this.publicKeyHex);
  final KeyPair keyPair;
  final String publicKeyHex;

  static Future<_Signer> generate() async {
    final algo = Ed25519();
    final kp = await algo.newKeyPair();
    final pub = await kp.extractPublicKey();
    return _Signer(kp, _hex(pub.bytes));
  }

  Future<String> signB64(String text) async {
    final sig = await Ed25519().sign(utf8.encode(text), keyPair: keyPair);
    return base64.encode(sig.bytes);
  }
}

const _issuedAt = '2026-07-17T00:00:00Z';
final int _nowMs = DateTime.parse(
  '2026-07-17T01:00:00Z',
).millisecondsSinceEpoch;

Future<SignedCatalog> _mkCatalog(
  _Signer s, {
  required String digest,
  int sequence = 5,
  String adapterId = 'school-golden',
  String adapterVersion = '1.2.3',
}) async {
  final json = jsonEncode({
    'catalogVersion': '1.0',
    'sequence': sequence,
    'issuedAt': _issuedAt,
    'ttlSeconds': 86400,
    'entries': [
      {
        'adapterId': adapterId,
        'adapterVersion': adapterVersion,
        'digest': digest,
        'url': 'https://dist.example.edu/$adapterId.json.gz',
        'stdlibMin': '1.0.0',
        'capabilities': ['notice.list'],
      },
    ],
  });
  return SignedCatalog(
    catalogJson: json,
    signature: await s.signB64(json),
    keyId: 'test-cat-key',
    algorithm: 'ed25519',
  );
}

Future<SignedRevocationList> _mkRevocation(
  _Signer s, {
  int sequence = 3,
  bool killSwitch = false,
  Map<String, String> minVersions = const {},
  List<Map<String, dynamic>> entries = const [],
}) async {
  final json = jsonEncode({
    'sequence': sequence,
    'issuedAt': _issuedAt,
    'ttlSeconds': 86400,
    'minVersions': minVersions,
    'killSwitch': killSwitch,
    'entries': entries,
  });
  return SignedRevocationList(
    listJson: json,
    signature: await s.signB64(json),
    keyId: 'test-rev-key',
    algorithm: 'ed25519',
  );
}

/// 可配置的分发源假替身：任一字段 null → 该源不可用（编排器退化）。
class _FakeSource implements DistributionSource {
  _FakeSource({this.catalog, this.revocation, this.bundle});
  SignedCatalog? catalog;
  SignedRevocationList? revocation;
  Uint8List? bundle;

  @override
  Future<SignedCatalog?> fetchCatalog() async => catalog;
  @override
  Future<SignedRevocationList?> fetchRevocation() async => revocation;
  @override
  Future<Uint8List?> fetchBundle(String url) async => bundle;
}

/// 空 asset 源（无 bootstrap 基线）。
class _EmptyAssets implements AssetSource {
  @override
  Future<Uint8List?> load(String key) async => null;
}

void main() {
  final golden = _loaderGolden();
  final valid = (golden['cases'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((c) => c['name'] == 'valid_official');
  final expectedDigest = golden['expectedDigest'] as String;
  final bundlePubHex = golden['publicKeyRawHex'] as String;
  final packed = Uint8List.fromList(
    base64.decode(golden['packedBundleBase64'] as String),
  );
  final bundleSig = SignatureFile.fromJson(
    valid['signature'] as Map<String, dynamic>,
  );
  final bundleEnv = BundleEnvelope.fromJson(
    valid['envelope'] as Map<String, dynamic>,
  );

  late _Signer catSigner;
  late _Signer revSigner;
  late InMemoryBlobStore cacheStore;
  late InMemoryBlobStore lgStore;
  late BundleCache cache;
  late LastGoodStore lastGood;
  late BootstrapBaseline bootstrap;

  setUp(() async {
    catSigner = await _Signer.generate();
    revSigner = await _Signer.generate();
    cacheStore = InMemoryBlobStore();
    lgStore = InMemoryBlobStore();
    cache = BundleCache(cacheStore);
    lastGood = LastGoodStore(lgStore);
    bootstrap = BootstrapBaseline(_EmptyAssets());
  });

  // 注入的 verifier：各用对应测试锚跑同一条验签管线（生产用真实 pin）。
  Future<VerifyResult<VerifiedCatalog>> vCat(SignedCatalog s) =>
      verifyCatalogWith(
        s,
        (kid) => kid == s.keyId
            ? TrustAnchor(
                keyId: kid,
                publicKeyHex: catSigner.publicKeyHex,
                active: true,
                note: 'test',
              )
            : null,
      );
  Future<VerifyResult<VerifiedRevocationList>> vRev(SignedRevocationList s) =>
      verifyRevocationWith(
        s,
        (kid) => kid == s.keyId
            ? TrustAnchor(
                keyId: kid,
                publicKeyHex: revSigner.publicKeyHex,
                active: true,
                note: 'test',
              )
            : null,
      );
  Future<VerifyResult<VerifiedBundle>> vBundle(
    BundleEnvelope e,
    SignatureFile sig,
  ) => verifyBundleSignatureWith(
    e,
    sig,
    (kid) => kid == sig.keyId
        ? TrustAnchor(
            keyId: kid,
            publicKeyHex: bundlePubHex,
            active: true,
            note: 'test',
          )
        : null,
  );

  AdapterLoader mkLoader({_FakeSource? source}) => AdapterLoader.forTesting(
    cache: cache,
    lastGood: lastGood,
    bootstrap: bootstrap,
    source: source,
    nowMs: () => _nowMs,
    verifyCatalogFn: vCat,
    verifyRevocationFn: vRev,
    verifyBundleFn: vBundle,
  );

  group('happy path（§2.6 全序 → official）', () {
    test('网络三源齐 → ok，铸 official，写缓存 + last-good', () async {
      final src = _FakeSource(
        catalog: await _mkCatalog(catSigner, digest: expectedDigest),
        revocation: await _mkRevocation(revSigner),
        bundle: packed,
      );
      final r = await mkLoader(source: src).loadAdapter('school-golden');

      expect(r.ok, isTrue, reason: r.reason);
      expect(r.trust!.tier, AdapterTrustTier.official);
      // 评审 #2：official 凭据绑定到具体 bundle（不可伪造身份/digest）。
      expect(r.trust!.adapterId, 'school-golden');
      expect(r.trust!.adapterVersion, '1.2.3');
      expect(r.trust!.digest, expectedDigest);
      expect(r.identity!.adapterId, 'school-golden');
      expect(r.identity!.adapterVersion, '1.2.3');
      expect(r.capabilities, ['notice.list']);
      expect(r.digest, expectedDigest);
      expect(r.catalogIsFresh, isTrue);
      expect(r.revocationIsFresh, isTrue);
      // 验签后的 packed 已入缓存，last-good 已持久化。
      expect(await cache.has(expectedDigest), isTrue);
      expect(await lastGood.readCatalog(), isNotNull);
      expect(await lastGood.readRevocation(), isNotNull);
    });

    test('缓存命中路径：bundle 源关掉仍 ok（每次重验）', () async {
      // 先预热缓存（写入已验签 bundle）。
      final vb = (await vBundle(bundleEnv, bundleSig)).value!;
      await cache.write(vb, packed);
      // 源无 bundle（fetchBundle=null），但 catalog/revocation 仍在。
      final src = _FakeSource(
        catalog: await _mkCatalog(catSigner, digest: expectedDigest),
        revocation: await _mkRevocation(revSigner),
        bundle: null,
      );
      final r = await mkLoader(source: src).loadAdapter('school-golden');
      expect(r.ok, isTrue, reason: r.reason);
      expect(r.trust!.tier, AdapterTrustTier.official);
    });

    test('完全离线（无 source）但 bootstrap 提供三源 → ok', () async {
      // 用一个把三 asset 都备好的 bootstrap。
      bootstrap = BootstrapBaseline(
        _FilledAssets(
          catalog: utf8.encode(
            jsonEncode(
              (await _mkCatalog(catSigner, digest: expectedDigest)).toJson(),
            ),
          ),
          revocation: utf8.encode(
            jsonEncode((await _mkRevocation(revSigner)).toJson()),
          ),
          bundleDigest: expectedDigest,
          bundleBytes: packed,
        ),
      );
      final r = await mkLoader(source: null).loadAdapter('school-golden');
      expect(r.ok, isTrue, reason: r.reason);
      expect(r.trust!.tier, AdapterTrustTier.official);
    });
  });

  group('fail-closed', () {
    test('无可信 revocation（缺三源）→ 拒载', () async {
      final src = _FakeSource(
        catalog: await _mkCatalog(catSigner, digest: expectedDigest),
        revocation: null,
        bundle: packed,
      );
      final r = await mkLoader(source: src).loadAdapter('school-golden');
      expect(r.ok, isFalse);
      expect(r.reason, contains('无可信 revocation'));
    });

    test('无可信 catalog → 拒载', () async {
      final src = _FakeSource(
        catalog: null,
        revocation: await _mkRevocation(revSigner),
        bundle: packed,
      );
      final r = await mkLoader(source: src).loadAdapter('school-golden');
      expect(r.ok, isFalse);
      expect(r.reason, contains('无可信 catalog'));
    });

    test('kill-switch 生效 → 拒（吊销）', () async {
      final src = _FakeSource(
        catalog: await _mkCatalog(catSigner, digest: expectedDigest),
        revocation: await _mkRevocation(revSigner, killSwitch: true),
        bundle: packed,
      );
      final r = await mkLoader(source: src).loadAdapter('school-golden');
      expect(r.ok, isFalse);
      expect(r.reason, contains('吊销'));
      expect(await cache.has(expectedDigest), isFalse); // 未落地
    });

    test('minVersion 高于 bundle 版本 → 拒（强制升级）', () async {
      final src = _FakeSource(
        catalog: await _mkCatalog(catSigner, digest: expectedDigest),
        revocation: await _mkRevocation(
          revSigner,
          minVersions: {'school-golden': '2.0.0'},
        ),
        bundle: packed,
      );
      final r = await mkLoader(source: src).loadAdapter('school-golden');
      expect(r.ok, isFalse);
      expect(r.reason, contains('吊销'));
    });

    // 注：「本端 stdlib 低于 stdlibMin → 拒」不再经 loader 测（生产 loader 不接受 hostStdlib 覆盖，
    // 评审 P1）——该场景移到 loader_stdlib_gate_test.dart 用 `mintOfficialGrantForHost`（仅测试）覆盖。

    test('catalog 无此 adapter → 拒', () async {
      final src = _FakeSource(
        catalog: await _mkCatalog(catSigner, digest: expectedDigest),
        revocation: await _mkRevocation(revSigner),
        bundle: packed,
      );
      final r = await mkLoader(source: src).loadAdapter('school-absent');
      expect(r.ok, isFalse);
      expect(r.reason, contains('无此 adapter'));
    });

    test('catalog entry.digest 与 bundle 不符（内容寻址失败）→ 拒', () async {
      const wrongDigest =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final src = _FakeSource(
        catalog: await _mkCatalog(catSigner, digest: wrongDigest),
        revocation: await _mkRevocation(revSigner),
        bundle: packed, // 真 bundle，但 digest 与 catalog 不符
      );
      final r = await mkLoader(source: src).loadAdapter('school-golden');
      expect(r.ok, isFalse);
      expect(r.reason, anyOf(contains('内容寻址'), contains('bundle 字节')));
    });

    test('entry 指向另一 adapter 的合法 bundle（adapterId 不符）→ 拒（评审 #1）', () async {
      // catalog 声称 school-other 住在 expectedDigest，但那份 bundle 权威身份是 school-golden。
      final src = _FakeSource(
        catalog: await _mkCatalog(
          catSigner,
          digest: expectedDigest,
          adapterId: 'school-other',
        ),
        revocation: await _mkRevocation(revSigner),
        bundle: packed,
      );
      final r = await mkLoader(source: src).loadAdapter('school-other');
      expect(r.ok, isFalse);
      expect(r.reason, contains('身份与 bundle 权威身份不符'));
      expect(await cache.has(expectedDigest), isFalse); // 未落地
    });

    test('entry 版本与 bundle 权威版本不符 → 拒（评审 #1）', () async {
      final src = _FakeSource(
        catalog: await _mkCatalog(
          catSigner,
          digest: expectedDigest,
          adapterVersion: '9.9.9',
        ),
        revocation: await _mkRevocation(revSigner),
        bundle: packed,
      );
      final r = await mkLoader(source: src).loadAdapter('school-golden');
      expect(r.ok, isFalse);
      expect(r.reason, contains('身份与 bundle 权威身份不符'));
    });

    test('catalog 验签失败（错锚）→ 无可信 catalog', () async {
      // 用 revSigner 的 key 签 catalog，但 vCat 只认 catSigner → 验不过。
      final bad = await _mkCatalog(revSigner, digest: expectedDigest);
      final src = _FakeSource(
        catalog: bad,
        revocation: await _mkRevocation(revSigner),
        bundle: packed,
      );
      final r = await mkLoader(source: src).loadAdapter('school-golden');
      expect(r.ok, isFalse);
      expect(r.reason, contains('无可信 catalog'));
    });
  });

  group('缓存 best-effort（评审 #3）', () {
    test('缓存写失败（非 BundleFormatException）不阻断加载，仅上报遥测', () async {
      final failing = _FailingWriteStore();
      final warnings = <String>[];
      final loader = AdapterLoader.forTesting(
        cache: BundleCache(failing),
        lastGood: lastGood,
        bootstrap: bootstrap,
        source: _FakeSource(
          catalog: await _mkCatalog(catSigner, digest: expectedDigest),
          revocation: await _mkRevocation(revSigner),
          bundle: packed,
        ),
        nowMs: () => _nowMs,
        verifyCatalogFn: vCat,
        verifyRevocationFn: vRev,
        verifyBundleFn: vBundle,
        onWarning: warnings.add,
      );
      final r = await loader.loadAdapter('school-golden');
      expect(r.ok, isTrue, reason: r.reason); // 已过全部门禁 → 缓存故障不该毁掉
      expect(r.trust!.tier, AdapterTrustTier.official);
      expect(warnings, isNotEmpty);
      expect(warnings.single, contains('缓存写入失败'));
    });
  });

  group('存储故障隔离（评审 P1：异常不打断回退链）', () {
    test('缓存读抛 IOException → 退网络仍 ok，仅遥测', () async {
      final warnings = <String>[];
      final loader = AdapterLoader.forTesting(
        cache: BundleCache(_ThrowingReadStore()),
        lastGood: lastGood,
        bootstrap: bootstrap,
        source: _FakeSource(
          catalog: await _mkCatalog(catSigner, digest: expectedDigest),
          revocation: await _mkRevocation(revSigner),
          bundle: packed,
        ),
        nowMs: () => _nowMs,
        verifyCatalogFn: vCat,
        verifyRevocationFn: vRev,
        verifyBundleFn: vBundle,
        onWarning: warnings.add,
      );
      final r = await loader.loadAdapter('school-golden');
      expect(r.ok, isTrue, reason: r.reason); // 缓存读故障不该掀翻加载
      expect(r.trust!.tier, AdapterTrustTier.official);
      expect(warnings.any((w) => w.contains('bundle 缓存')), isTrue);
    });

    test('last-good 读抛 → 退 bootstrap 仍 ok（离线）', () async {
      bootstrap = BootstrapBaseline(
        _FilledAssets(
          catalog: utf8.encode(
            jsonEncode(
              (await _mkCatalog(catSigner, digest: expectedDigest)).toJson(),
            ),
          ),
          revocation: utf8.encode(
            jsonEncode((await _mkRevocation(revSigner)).toJson()),
          ),
          bundleDigest: expectedDigest,
          bundleBytes: packed,
        ),
      );
      final warnings = <String>[];
      final loader = AdapterLoader.forTesting(
        cache: cache,
        lastGood: LastGoodStore(_ThrowingReadStore()),
        bootstrap: bootstrap,
        source: null,
        nowMs: () => _nowMs,
        verifyCatalogFn: vCat,
        verifyRevocationFn: vRev,
        verifyBundleFn: vBundle,
        onWarning: warnings.add,
      );
      final r = await loader.loadAdapter('school-golden');
      expect(r.ok, isTrue, reason: r.reason); // last-good 读故障退 bootstrap
      expect(warnings.any((w) => w.contains('last-good')), isTrue);
    });

    test('bootstrap asset 读抛 → 退网络仍 ok', () async {
      final warnings = <String>[];
      final loader = AdapterLoader.forTesting(
        cache: cache,
        lastGood: lastGood,
        bootstrap: BootstrapBaseline(_ThrowingAssets()),
        source: _FakeSource(
          catalog: await _mkCatalog(catSigner, digest: expectedDigest),
          revocation: await _mkRevocation(revSigner),
          bundle: packed,
        ),
        nowMs: () => _nowMs,
        verifyCatalogFn: vCat,
        verifyRevocationFn: vRev,
        verifyBundleFn: vBundle,
        onWarning: warnings.add,
      );
      final r = await loader.loadAdapter('school-golden');
      expect(r.ok, isTrue, reason: r.reason); // bootstrap 读故障退网络
      expect(r.trust!.tier, AdapterTrustTier.official);
      expect(warnings.any((w) => w.contains('bootstrap')), isTrue);
    });
  });

  group('防回滚 / last-good 采纳', () {
    test('网络份 sequence ≤ last-good → 不采纳、不覆盖 last-good', () async {
      // 先把 seq=9 的 catalog 落成 last-good。
      final hi = await _mkCatalog(
        catSigner,
        digest: expectedDigest,
        sequence: 9,
      );
      await lastGood.writeCatalog((await vCat(hi)).value!, hi);
      // 网络推来 seq=4（回滚）。
      final src = _FakeSource(
        catalog: await _mkCatalog(
          catSigner,
          digest: expectedDigest,
          sequence: 4,
        ),
        revocation: await _mkRevocation(revSigner),
        bundle: packed,
      );
      final r = await mkLoader(source: src).loadAdapter('school-golden');
      expect(r.ok, isTrue, reason: r.reason); // 仍能用 last-good 加载
      // last-good 未被 seq=4 覆盖（仍是 seq=9）。
      final back = await lastGood.readCatalog();
      expect(back, isNotNull);
      expect((await vCat(back!)).value!.catalog.sequence, 9);
    });
  });
}

/// write 恒抛（模拟磁盘/目录/rename 故障）；read/delete 走内存。
class _FailingWriteStore implements BlobStore {
  final Map<String, Uint8List> _m = {};
  @override
  Future<Uint8List?> read(String name) async => _m[name];
  @override
  Future<void> write(String name, List<int> bytes) async =>
      throw Exception('模拟写盘失败');
  @override
  Future<void> delete(String name) async => _m.remove(name);
}

/// read 恒抛（模拟读盘 IOException / 存储故障）；write/delete 走内存。
class _ThrowingReadStore implements BlobStore {
  final Map<String, Uint8List> _m = {};
  @override
  Future<Uint8List?> read(String name) async => throw Exception('模拟读盘失败');
  @override
  Future<void> write(String name, List<int> bytes) async =>
      _m[name] = Uint8List.fromList(bytes);
  @override
  Future<void> delete(String name) async => _m.remove(name);
}

/// load 恒抛（模拟 asset 存储故障，区别于「缺 asset → null」）。
class _ThrowingAssets implements AssetSource {
  @override
  Future<Uint8List?> load(String key) async => throw Exception('模拟 asset 读失败');
}

/// 备好三 asset 的 bootstrap 源（catalog/revocation/bundle）。
class _FilledAssets implements AssetSource {
  _FilledAssets({
    required this.catalog,
    required this.revocation,
    required this.bundleDigest,
    required this.bundleBytes,
  });
  final List<int> catalog;
  final List<int> revocation;
  final String bundleDigest;
  final Uint8List bundleBytes;

  @override
  Future<Uint8List?> load(String key) async {
    if (key.endsWith('/catalog.json')) return Uint8List.fromList(catalog);
    if (key.endsWith('/revocation.json')) return Uint8List.fromList(revocation);
    if (key.endsWith('/bundles/$bundleDigest.bundle')) return bundleBytes;
    return null;
  }
}
