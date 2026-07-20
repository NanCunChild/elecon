/// 🔒 片 G —— `adapter_launcher.dart`：LoadResult → runFetchAdapter 接线 + source⟷凭据绑定（评审 E#2）。
///
/// 用测试内现签的 Ed25519 bundle（带完整 manifest：runtime.entry / network.allow / credentials /
/// capabilities）跑通编排器 `AdapterLoader` 得到真 official [LoadResult]，再喂 [planLaunch]。
/// planLaunch 是纯函数、承载全部接线安全逻辑（绑定核对 / 权威策略 / 能力门），故负例可穷举。
library;

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Ed25519, KeyPair;
// adapter_launcher.dart 是 adapter_runtime.dart 的 part（评审 P0-1）——经宿主库导入其公开面。
import 'package:elecon/core/adapter_runtime.dart';
import 'package:elecon/core/broker/ports.dart';
import 'package:elecon/core/broker/fetch_proxy.dart';
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

// ── Ed25519 测试签发 ─────────────────────────────────────────────────────
String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

class _Signer {
  _Signer(this.keyPair, this.publicKeyHex);
  final KeyPair keyPair;
  final String publicKeyHex;

  static Future<_Signer> generate() async {
    final kp = await Ed25519().newKeyPair();
    final pub = await kp.extractPublicKey();
    return _Signer(kp, _hex(pub.bytes));
  }

  Future<String> signB64(List<int> bytes) async {
    final s = await Ed25519().sign(bytes, keyPair: keyPair);
    return base64.encode(s.bytes);
  }
}

const _issuedAt = '2026-07-17T00:00:00Z';
final int _nowMs = DateTime.parse(
  '2026-07-17T01:00:00Z',
).millisecondsSinceEpoch;

/// 现签一个 bundle：返回 packed 字节 + digest + bundle 公钥 hex。
class _Bundle {
  _Bundle(this.packed, this.digest, this.pubHex);
  final Uint8List packed;
  final String digest;
  final String pubHex;
}

Future<_Bundle> _mkBundle(
  _Signer bundleSigner, {
  String adapterId = 'school-x',
  String adapterVersion = '1.0.0',
  String entrySource = 'export const capabilities = {};',
  bool includeEntry = true,
  bool includeNetwork = true,
  bool includeCredentials = true,
  List<String> capabilities = const ['notice.list'],
}) async {
  final runtime = <String, dynamic>{'stdlibMin': '1.0.0'};
  if (includeEntry) runtime['entry'] = 'index.js';
  final manifest = <String, dynamic>{
    'schemaVersion': '1.0',
    'adapterId': adapterId,
    'adapterVersion': adapterVersion,
    'capabilities': [
      for (final id in capabilities)
        {
          'id': id,
          'emits': {'schema': 'elecon.notice.list', 'schemaVersion': '1.0'},
        },
    ],
    'runtime': runtime,
    if (includeNetwork)
      'network': {
        'allow': ['https://x.edu/*'],
      },
    if (includeCredentials)
      'credentials': {
        'x-session': {
          'scope': ['https://x.edu/*'],
          'type': 'cookie',
          'role': 'sso-master',
        },
      },
  };
  final files = <Map<String, dynamic>>[
    {'path': 'index.js', 'encoding': 'utf-8', 'content': entrySource},
    {
      'path': 'manifest.json',
      'encoding': 'utf-8',
      'content': jsonEncode(manifest),
    },
  ];
  final env = BundleEnvelope.fromJson({
    'bundleFormat': kBundleFormat,
    'files': files,
  });
  final digest = envelopeDigest(env);
  final payload = serializeSignaturePayload(
    adapterId: adapterId,
    adapterVersion: adapterVersion,
    tier: kTierOfficial,
    digest: digest,
  );
  final sigB64 = await bundleSigner.signB64(payload);
  final sig = {
    'adapterId': adapterId,
    'adapterVersion': adapterVersion,
    'tier': kTierOfficial,
    'digest': digest,
    'signature': sigB64,
    'keyId': 'k-bundle',
    'algorithm': 'ed25519',
  };
  final packed = Uint8List.fromList(
    gzip.encode(
      utf8.encode(
        jsonEncode({
          'envelope': {'bundleFormat': kBundleFormat, 'files': files},
          'signature': sig,
        }),
      ),
    ),
  );
  return _Bundle(packed, digest, bundleSigner.publicKeyHex);
}

Future<SignedCatalog> _mkCatalog(
  _Signer s, {
  required String digest,
  String adapterId = 'school-x',
  String adapterVersion = '1.0.0',
}) async {
  final json = jsonEncode({
    'catalogVersion': '1.0',
    'sequence': 5,
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
    signature: await s.signB64(utf8.encode(json)),
    keyId: 'test-cat-key',
    algorithm: 'ed25519',
  );
}

Future<SignedRevocationList> _mkRevocation(_Signer s) async {
  final json = jsonEncode({
    'sequence': 3,
    'issuedAt': _issuedAt,
    'ttlSeconds': 86400,
    'minVersions': <String, String>{},
    'killSwitch': false,
    'entries': <Map<String, dynamic>>[],
  });
  return SignedRevocationList(
    listJson: json,
    signature: await s.signB64(utf8.encode(json)),
    keyId: 'test-rev-key',
    algorithm: 'ed25519',
  );
}

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

class _EmptyAssets implements AssetSource {
  @override
  Future<Uint8List?> load(String key) async => null;
}

/// 永不被调用的 session 依赖桩（能力门在触达 runFetchAdapter 前 fail-closed）。
class _StubResolver implements CredentialResolver {
  @override
  Future<ResolvedCredential?> get(String ref) async =>
      throw StateError('resolver 不应被调用');
}

class _StubTransport implements Transport {
  @override
  Future<TransportResponse> fetch(
    TransportRequest req, {
    TransportCancelToken? cancelToken,
  }) async => throw StateError('transport 不应被调用');
}

void main() {
  late _Signer catSigner;
  late _Signer revSigner;
  late _Signer bundleSigner;

  setUp(() async {
    catSigner = await _Signer.generate();
    revSigner = await _Signer.generate();
    bundleSigner = await _Signer.generate();
  });

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
            publicKeyHex: bundleSigner.publicKeyHex,
            active: true,
            note: 'test',
          )
        : null,
  );

  Future<LoadResult> load(_Bundle b) async {
    final loader = AdapterLoader.forTesting(
      cache: BundleCache(InMemoryBlobStore()),
      lastGood: LastGoodStore(InMemoryBlobStore()),
      bootstrap: BootstrapBaseline(_EmptyAssets()),
      source: _FakeSource(
        catalog: await _mkCatalog(catSigner, digest: b.digest),
        revocation: await _mkRevocation(revSigner),
        bundle: b.packed,
      ),
      nowMs: () => _nowMs,
      verifyCatalogFn: vCat,
      verifyRevocationFn: vRev,
      verifyBundleFn: vBundle,
    );
    return loader.loadAdapter('school-x');
  }

  group('planLaunch happy', () {
    test(
      'official LoadResult → 组装 source/view/capabilities，digest 绑定',
      () async {
        final b = await _mkBundle(bundleSigner);
        final r = await load(b);
        expect(r.ok, isTrue, reason: r.reason);

        final plan = planLaunch(r);
        expect(plan.source, 'export const capabilities = {};');
        expect(plan.trust.tier, AdapterTrustTier.official);
        expect(plan.digest, b.digest);
        expect(plan.trust.digest, b.digest);
        // 权威注入策略取自 bundle manifest（非 catalog）。
        expect(plan.view.allow, ['https://x.edu/*']);
        expect(plan.view.credentials.keys, contains('x-session'));
        expect(plan.view.credentials['x-session']!.type, 'cookie');
        expect(plan.view.credentials['x-session']!.role, 'sso-master');
        expect(plan.capabilities, ['notice.list']);
      },
    );

    test('无 credentials 的 manifest → view.credentials 空', () async {
      final b = await _mkBundle(bundleSigner, includeCredentials: false);
      final plan = planLaunch(await load(b));
      expect(plan.view.credentials, isEmpty);
      expect(plan.view.allow, ['https://x.edu/*']);
    });
  });

  group('planLaunch fail-closed', () {
    test('失败的 LoadResult → 抛', () {
      expect(
        () => planLaunch(const LoadResult.fail('x')),
        throwsA(isA<AdapterLaunchException>()),
      );
    });

    test('🔒 source⟷凭据 digest 不符（错配 envelope）→ 抛（评审 E#2）', () async {
      final b = await _mkBundle(bundleSigner);
      final r = await load(b);
      final realTrust = r.trust!;
      // 另造一份内容不同的 envelope（digest 必不同），与真 official 凭据错配。
      final wrongEnv = BundleEnvelope.fromJson({
        'bundleFormat': kBundleFormat,
        'files': [
          {'path': 'index.js', 'encoding': 'utf-8', 'content': '// 不同内容'},
          {
            'path': 'manifest.json',
            'encoding': 'utf-8',
            'content': jsonEncode({
              'adapterId': 'school-x',
              'adapterVersion': '1.0.0',
              'runtime': {'entry': 'index.js', 'stdlibMin': '1.0.0'},
              'network': {'allow': <String>[]},
              'capabilities': <String>[],
            }),
          },
        ],
      });
      final forged = LoadResult.ok(
        trust: realTrust,
        envelope: wrongEnv,
        identity: const EnvelopeIdentity(
          adapterId: 'school-x',
          adapterVersion: '1.0.0',
        ),
        capabilities: const [],
        digest: realTrust.digest!,
        catalogIsFresh: true,
        revocationIsFresh: true,
      );
      expect(
        () => planLaunch(forged),
        throwsA(
          isA<AdapterLaunchException>().having(
            (e) => e.message,
            'message',
            contains('digest 与凭据绑定 digest 不符'),
          ),
        ),
      );
    });

    test('manifest 缺 runtime.entry → 抛', () async {
      final b = await _mkBundle(bundleSigner, includeEntry: false);
      final r = await load(b);
      expect(r.ok, isTrue, reason: r.reason); // 加载器不需要 entry
      expect(
        () => planLaunch(r),
        throwsA(
          isA<AdapterLaunchException>().having(
            (e) => e.message,
            'message',
            contains('entry'),
          ),
        ),
      );
    });

    test('manifest 缺 network → 抛', () async {
      final b = await _mkBundle(bundleSigner, includeNetwork: false);
      final r = await load(b);
      expect(r.ok, isTrue, reason: r.reason);
      expect(
        () => planLaunch(r),
        throwsA(
          isA<AdapterLaunchException>().having(
            (e) => e.message,
            'message',
            contains('network'),
          ),
        ),
      );
    });
  });

  group('runLoadedAdapter 能力门', () {
    test('请求未声明能力 → 抛，且不触达 resolver/transport', () async {
      final b = await _mkBundle(bundleSigner);
      final r = await load(b);
      expect(
        () => runLoadedAdapter(
          result: r,
          capability: 'grade.list', // manifest 只声明 notice.list
          resolver: _StubResolver(),
          transport: _StubTransport(),
        ),
        throwsA(
          isA<AdapterLaunchException>().having(
            (e) => e.message,
            'message',
            contains('未声明能力'),
          ),
        ),
      );
    });
  });
}
