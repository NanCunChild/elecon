/// 🔒 片 G —— `adapter_launcher.dart`：LoadResult → runImperativeAdapter 接线 + source⟷凭据绑定（评审 E#2）。
///
/// 用测试内现签的 Ed25519 bundle（带完整 manifest：runtime.entry / network.allow / credentials /
/// capabilities）跑通编排器 `AdapterLoader` 得到真 official [LoadResult]，再喂 [planLaunch]。
/// planLaunch 是纯函数、承载全部接线安全逻辑（绑定核对 / 权威策略 / 能力门），故负例可穷举。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Ed25519, KeyPair;
// adapter_launcher.dart 是 adapter_runtime.dart 的 part（评审 P0-1）——经宿主库导入其公开面。
import 'package:elecon/core/adapter_runtime.dart';
import 'package:elecon/core/broker/ports.dart';
import 'package:elecon/core/broker/fetch_proxy.dart';
import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/loader/bootstrap.dart';
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

import 'utils/bundle_fixture.dart';

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
  Map<String, dynamic>? credentials,
  List<String> capabilities = const ['notice.list'],

  /// capability id → requestGraph；缺省全部 `imperative`。
  Map<String, String> requestGraphs = const {},

  /// capability id → declarative `requests[]`（可选）。
  Map<String, List<Map<String, dynamic>>> capabilityRequests = const {},
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
          'requestGraph': requestGraphs[id] ?? 'imperative',
          'emits': {'schema': 'elecon.notice.list', 'schemaVersion': '1.0'},
          if (capabilityRequests[id] != null)
            'requests': capabilityRequests[id],
        },
    ],
    'runtime': runtime,
    if (includeNetwork)
      'network': {
        'allow': ['https://x.edu/*'],
      },
    if (includeCredentials)
      'credentials':
          credentials ??
          {
            'x-session': {
              'scope': ['https://x.edu/*'],
              'type': 'cookie',
              'role': 'sso-master',
            },
          },
  };
  final built = buildFixtureEnvelope({
    'index.js': entrySource,
    'manifest.json': jsonEncode(manifest),
  }, adapterId: adapterId, adapterVersion: adapterVersion);
  final payload = serializeSignaturePayload(
    adapterId: adapterId,
    adapterVersion: adapterVersion,
    tier: kTierOfficial,
    digest: built.digest,
  );
  final packed = packWire(built.bytes, {
    'adapterId': adapterId,
    'adapterVersion': adapterVersion,
    'tier': kTierOfficial,
    'digest': built.digest,
    'signature': await bundleSigner.signB64(payload),
    'keyId': 'k-bundle',
    'algorithm': 'ed25519',
  }, built.blobs);
  return _Bundle(packed, built.digest, bundleSigner.publicKeyHex);
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
        'stdlibMin': '1.0.0',
        'capabilities': ['notice.list'],
      },
    ],
  });
  return SignedCatalog(
    catalogJson: json,
    signature: await s.signB64(
      withContext(kContextTagCatalog, utf8.encode(json)),
    ),
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
    signature: await s.signB64(
      withContext(kContextTagRevocation, utf8.encode(json)),
    ),
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
  Future<Uint8List?> fetchBundle(String digest) async => bundle;
}

class _EmptyAssets implements AssetSource {
  @override
  Future<Uint8List?> load(String key) async => null;
}

/// 永不被调用的 session 依赖桩（能力门在触达 runImperativeAdapter 前 fail-closed）。
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
  Future<VerifyResult<VerifiedBundle>> vBundle(Uint8List packed) =>
      openBundleWith(
        packed,
        (kid) => kid == 'k-bundle'
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
        expect(plan.capabilityRequestGraphs['notice.list'], 'imperative');
        expect(plan.capabilityRequests['notice.list'], isEmpty);
        expect(
          plan.capabilityEmits['notice.list']!.schema,
          'elecon.notice.list',
        );
        expect(plan.capabilityEmits['notice.list']!.schemaVersion, '1.0');
      },
    );

    test('无 credentials 的 manifest → view.credentials 空', () async {
      final b = await _mkBundle(bundleSigner, includeCredentials: false);
      final plan = planLaunch(await load(b));
      expect(plan.view.credentials, isEmpty);
      expect(plan.view.allow, ['https://x.edu/*']);
      expect(plan.capabilityRequestGraphs['notice.list'], 'imperative');
    });

    test('已验签 manifest 的命名 header 传入 Broker view', () async {
      final b = await _mkBundle(
        bundleSigner,
        credentials: {
          'x-session': {
            'scope': ['https://x.edu/*'],
            'type': 'header',
            'headerName': 'x-access-token',
          },
        },
      );
      final plan = planLaunch(await load(b));
      final credential = plan.view.credentials['x-session']!;
      expect(credential.type, 'header');
      expect(credential.headerName, 'x-access-token');
    });

    test('混用 cap：official 可 declarative + imperative 并存', () async {
      final b = await _mkBundle(
        bundleSigner,
        capabilities: const ['notice.list', 'grades.list'],
        requestGraphs: const {
          'notice.list': 'declarative',
          'grades.list': 'imperative',
        },
        capabilityRequests: const {
          'notice.list': [
            {
              'key': 'raw',
              'method': 'GET',
              'url': 'https://x.edu/notice',
              'credential': 'x-session',
            },
          ],
        },
      );
      final plan = planLaunch(await load(b));
      expect(plan.capabilityRequestGraphs['notice.list'], 'declarative');
      expect(plan.capabilityRequestGraphs['grades.list'], 'imperative');
      expect(plan.capabilityRequests['notice.list'], hasLength(1));
      expect(plan.capabilityRequests['notice.list']!.single.key, 'raw');
      expect(plan.capabilityRequests['grades.list'], isEmpty);
    });
  });

  group('planLaunch fail-closed', () {
    test('headerName 非字符串时拒绝已验签 manifest', () async {
      final b = await _mkBundle(
        bundleSigner,
        credentials: {
          'x-session': {
            'scope': ['https://x.edu/*'],
            'type': 'header',
            'headerName': 7,
          },
        },
      );
      await expectLater(
        () async => planLaunch(await load(b)),
        throwsA(isA<AdapterLaunchException>()),
      );
    });

    test('失败的 LoadResult → 抛', () {
      expect(
        () => planLaunch(const LoadResult.fail('x')),
        throwsA(isA<AdapterLaunchException>()),
      );
    });

    test('🔒 source⟷凭据 digest 不符（错配 bundle）→ 抛（评审 E#2）', () async {
      // 把 **bundle A 的 official 凭据** 与 **bundle B 的已验签内容** 配在一起：
      // 两者各自都合法，唯独不是同一份东西。这是 digest v2 之后仍然构造得出的错配形态。
      //
      // v1 的这条测试是用一个手拼的 `wrongEnv` 伪造 LoadResult。现在伪造不出来了：
      // `LoadResult.ok` 只收不可伪造的 `VerifiedBundle`，envelope / identity / digest 都从
      // 它派生，"envelope 与 digest 不一致的 LoadResult"在类型上已不存在（见 loader.dart）。
      final a = await _mkBundle(bundleSigner);
      final ra = await load(a);
      expect(ra.ok, isTrue, reason: ra.reason);

      final b = await _mkBundle(bundleSigner, entrySource: '// 另一份内容\n');
      final rb = await load(b);
      expect(rb.ok, isTrue, reason: rb.reason);
      expect(rb.digest, isNot(ra.digest), reason: '前提：两份 bundle 内容不同');

      final crossed = LoadResult.ok(
        trust: ra.trust!, // 凭据绑定 A 的 digest
        verified: rb.verified!, // 内容却是 B
        capabilities: const [],
        catalogIsFresh: true,
        revocationIsFresh: true,
      );
      expect(
        () => planLaunch(crossed),
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

    test('capabilities 缺 requestGraph → 抛（无默认 imperative）', () async {
      // 直接构造畸形 manifest（_mkBundle 默认会写 requestGraph）。
      final built = buildFixtureEnvelope({
        'index.js': 'export const capabilities = {};',
        'manifest.json': jsonEncode({
          'schemaVersion': '1.0',
          'adapterId': 'school-x',
          'adapterVersion': '1.0.0',
          'capabilities': [
            {
              'id': 'notice.list',
              'emits': {
                'schema': 'elecon.notice.list',
                'schemaVersion': '1.0',
              },
            },
          ],
          'runtime': {'stdlibMin': '1.0.0', 'entry': 'index.js'},
          'network': {
            'allow': ['https://x.edu/*'],
          },
        }),
      });
      final digest = built.digest;
      final packed = packWire(built.bytes, {
        'adapterId': 'school-x',
        'adapterVersion': '1.0.0',
        'tier': kTierOfficial,
        'digest': digest,
        'signature': await bundleSigner.signB64(serializeSignaturePayload(
          adapterId: 'school-x',
          adapterVersion: '1.0.0',
          tier: kTierOfficial,
          digest: digest,
        )),
        'keyId': 'k-bundle',
        'algorithm': 'ed25519',
      }, built.blobs);
      final b = _Bundle(packed, digest, bundleSigner.publicKeyHex);
      final r = await load(b);
      expect(r.ok, isTrue, reason: r.reason);
      expect(
        () => planLaunch(r),
        throwsA(
          isA<AdapterLaunchException>().having(
            (e) => e.message,
            'message',
            contains('requestGraph'),
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
