/// 🔒 生产装配层 `adapter_service.dart` + `SessionController.runCapability` 接线。
///
/// 用测试内现签的 bundle（完整 manifest + 一个**不发 fetch** 的 capability）过 `AdapterLoader.forTesting`
/// 得真 official LoadResult，再经 [AdapterService.run] 触真实 QuickJS 引擎执行；transport/resolver 用
/// 抛错桩（该 capability 不触网、不取凭证，故不应被调用）。生产 `AdapterService.production` 走 dart:io/
/// path_provider，不在此单测（属 wiring shim，人工复核）。
library;

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Ed25519, KeyPair;
import 'package:elecon/core/adapter_service.dart';
import 'package:elecon/core/adapter_runtime.dart' show AdapterFailureReason;
import 'package:elecon/core/broker/fetch_proxy.dart';
import 'package:elecon/core/broker/ports.dart';
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
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/school_fixture.dart';

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

  Future<String> signB64(List<int> bytes) async =>
      base64.encode((await Ed25519().sign(bytes, keyPair: keyPair)).bytes);
}

const _issuedAt = '2026-07-18T00:00:00Z';
final int _nowMs = DateTime.parse(
  '2026-07-18T01:00:00Z',
).millisecondsSinceEpoch;

class _Bundle {
  _Bundle(this.packed, this.digest);
  final Uint8List packed;
  final String digest;
}

/// 现签一个跑得起来的 bundle：capability `notice.list` 直接返回常量（不发 ctx.fetch）。
Future<_Bundle> _mkBundle(
  _Signer bundleSigner, {
  required String adapterId,
  String adapterVersion = '1.0.0',
  String capability = 'notice.list',
  String requestGraph = 'imperative',
  String emitsSchema = 'elecon.notice.list',
  String emitsSchemaVersion = '1.1',
  Object? output = const {
    'items': [
      {
        'id': 'notice-1',
        'title': 'Test notice',
        'category': 'unknown',
        'source': 'Test source',
      },
    ],
  },
}) async {
  final asyncKeyword = requestGraph == 'imperative' ? 'async ' : '';
  final source =
      "export const capabilities = { '$capability': $asyncKeyword(ctx) => { "
      "ctx.log('info', 'HelloWorld'); return ${jsonEncode(output)}; } };";
  final manifest = {
    'schemaVersion': '1.0',
    'adapterId': adapterId,
    'adapterVersion': adapterVersion,
    'capabilities': [
      {
        'id': capability,
        'requestGraph': requestGraph,
        'emits': {'schema': emitsSchema, 'schemaVersion': emitsSchemaVersion},
      },
    ],
    'runtime': {'entry': 'index.js', 'stdlibMin': '1.0.0'},
    'network': {
      'allow': ['https://x.edu/*'],
    },
  };
  final files = <Map<String, dynamic>>[
    {'path': 'index.js', 'encoding': 'utf-8', 'content': source},
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
  final sigB64 = await bundleSigner.signB64(
    serializeSignaturePayload(
      adapterId: adapterId,
      adapterVersion: adapterVersion,
      tier: kTierOfficial,
      digest: digest,
    ),
  );
  final packed = Uint8List.fromList(
    gzip.encode(
      utf8.encode(
        jsonEncode({
          'envelope': {'bundleFormat': kBundleFormat, 'files': files},
          'signature': {
            'adapterId': adapterId,
            'adapterVersion': adapterVersion,
            'tier': kTierOfficial,
            'digest': digest,
            'signature': sigB64,
            'keyId': 'k-bundle',
            'algorithm': 'ed25519',
          },
        }),
      ),
    ),
  );
  return _Bundle(packed, digest);
}

Future<SignedCatalog> _mkCatalog(
  _Signer s, {
  required String digest,
  required String adapterId,
  List<String> capabilities = const ['notice.list'],
}) async {
  final json = jsonEncode({
    'catalogVersion': '1.0',
    'sequence': 5,
    'issuedAt': _issuedAt,
    'ttlSeconds': 86400,
    'entries': [
      {
        'adapterId': adapterId,
        'adapterVersion': '1.0.0',
        'digest': digest,
        'url': 'https://dist.example.edu/$adapterId.json.gz',
        'stdlibMin': '1.0.0',
        'capabilities': capabilities,
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

/// 不应被调用（该 capability 不发 fetch / 不取凭证）。
class _ThrowingResolver implements CredentialResolver {
  @override
  Future<ResolvedCredential?> get(String ref) async =>
      throw StateError('resolver 不应被调用');
}

class _ThrowingTransport implements Transport {
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

  // 用现签 bundle 装一个测试 AdapterService（forTesting 加载器 + 抛错 transport）。
  Future<AdapterService> serviceFor(
    _Bundle b, {
    required String adapterId,
    SignedCatalog? catalogOverride,
  }) async {
    final loader = AdapterLoader.forTesting(
      cache: BundleCache(InMemoryBlobStore()),
      lastGood: LastGoodStore(InMemoryBlobStore()),
      bootstrap: BootstrapBaseline(_EmptyAssets()),
      source: _FakeSource(
        catalog:
            catalogOverride ??
            await _mkCatalog(catSigner, digest: b.digest, adapterId: adapterId),
        revocation: await _mkRevocation(revSigner),
        bundle: b.packed,
      ),
      nowMs: () => _nowMs,
      verifyCatalogFn: vCat,
      verifyRevocationFn: vRev,
      verifyBundleFn: vBundle,
    );
    return AdapterService(loader: loader, transport: _ThrowingTransport());
  }

  group('AdapterService.run', () {
    test('happy：加载 + 执行 → ok，携产出（不触 transport/resolver）', () async {
      final b = await _mkBundle(bundleSigner, adapterId: 'school-x');
      final svc = await serviceFor(b, adapterId: 'school-x');
      final logs = <String>[];
      final r = await svc.run(
        adapterId: 'school-x',
        capability: 'notice.list',
        resolver: _ThrowingResolver(),
        onLog: (level, message) => logs.add('$level:$message'),
      );
      expect(r.ok, isTrue, reason: r.reason);
      expect((r.data as Map)['items'], hasLength(1));
      expect(r.supportedCapabilities, {'notice.list'});
      expect(logs, ['info:HelloWorld']);
    });

    test('加载失败（无 catalog）→ failed(load)', () async {
      final b = await _mkBundle(bundleSigner, adapterId: 'school-x');
      final loader = AdapterLoader.forTesting(
        cache: BundleCache(InMemoryBlobStore()),
        lastGood: LastGoodStore(InMemoryBlobStore()),
        bootstrap: BootstrapBaseline(_EmptyAssets()),
        source: _FakeSource(
          catalog: null,
          revocation: await _mkRevocation(revSigner),
          bundle: b.packed,
        ),
        nowMs: () => _nowMs,
        verifyCatalogFn: vCat,
        verifyRevocationFn: vRev,
        verifyBundleFn: vBundle,
      );
      final svc = AdapterService(
        loader: loader,
        transport: _ThrowingTransport(),
      );
      final r = await svc.run(
        adapterId: 'school-x',
        capability: 'notice.list',
        resolver: _ThrowingResolver(),
      );
      expect(r.ok, isFalse);
      expect(r.failureKind, CapabilityFailureKind.load);
      expect(r.supportedCapabilities, isEmpty);
    });

    test('UI 能力元数据取 bundle manifest 权威集合而非 catalog 展示集合', () async {
      final b = await _mkBundle(bundleSigner, adapterId: 'school-x');
      final svc = await serviceFor(
        b,
        adapterId: 'school-x',
        catalogOverride: await _mkCatalog(
          catSigner,
          digest: b.digest,
          adapterId: 'school-x',
          capabilities: const ['grades.list'],
        ),
      );
      final r = await svc.run(
        adapterId: 'school-x',
        capability: 'notice.list',
        resolver: _ThrowingResolver(),
      );
      expect(r.ok, isTrue, reason: r.reason);
      expect(r.supportedCapabilities, {'notice.list'});
    });

    test('declarative output 经过同一 schema boundary 后成功', () async {
      final b = await _mkBundle(
        bundleSigner,
        adapterId: 'school-x',
        requestGraph: 'declarative',
      );
      final svc = await serviceFor(b, adapterId: 'school-x');
      final r = await svc.run(
        adapterId: 'school-x',
        capability: 'notice.list',
        resolver: _ThrowingResolver(),
      );
      expect(r.ok, isTrue, reason: r.reason);
      expect((r.data as Map)['items'], hasLength(1));
    });

    for (final invalid in <String, Object?>{
      'missing required field': const {},
      'wrong root field type': const {'items': 'not-a-list'},
      'malformed nested item': const {
        'items': [
          {'id': 'payload-must-not-appear'},
        ],
      },
    }.entries) {
      test(
        'imperative output rejects entire payload: ${invalid.key}',
        () async {
          final b = await _mkBundle(
            bundleSigner,
            adapterId: 'school-x',
            output: invalid.value,
          );
          final svc = await serviceFor(b, adapterId: 'school-x');
          final r = await svc.run(
            adapterId: 'school-x',
            capability: 'notice.list',
            resolver: _ThrowingResolver(),
          );
          expect(r.ok, isFalse);
          expect(r.failureKind, CapabilityFailureKind.run);
          expect(r.runReason, AdapterFailureReason.badResult);
          expect(r.data, isNull);
          expect(r.reason, isNot(contains('payload-must-not-appear')));
        },
      );
    }

    test('declarative malformed nested item rejects entire payload', () async {
      final b = await _mkBundle(
        bundleSigner,
        adapterId: 'school-x',
        requestGraph: 'declarative',
        output: const {
          'items': [
            {
              'id': 'valid',
              'title': 'Valid',
              'category': 'unknown',
              'source': 'Test',
            },
            {'id': 'nested-secret'},
          ],
        },
      );
      final svc = await serviceFor(b, adapterId: 'school-x');
      final r = await svc.run(
        adapterId: 'school-x',
        capability: 'notice.list',
        resolver: _ThrowingResolver(),
      );
      expect(r.failureKind, CapabilityFailureKind.run);
      expect(r.runReason, AdapterFailureReason.badResult);
      expect(r.reason, isNot(contains('nested-secret')));
    });

    for (final emits in <({String schema, String version})>[
      (schema: 'elecon.notice.list', version: '1.0'),
      (schema: 'elecon.unknown', version: '1.1'),
    ]) {
      test(
        'signed unknown emits rejects: ${emits.schema}@${emits.version}',
        () async {
          final b = await _mkBundle(
            bundleSigner,
            adapterId: 'school-x',
            emitsSchema: emits.schema,
            emitsSchemaVersion: emits.version,
          );
          final svc = await serviceFor(b, adapterId: 'school-x');
          final r = await svc.run(
            adapterId: 'school-x',
            capability: 'notice.list',
            resolver: _ThrowingResolver(),
          );
          expect(r.failureKind, CapabilityFailureKind.run);
          expect(r.runReason, AdapterFailureReason.badResult);
          expect(r.data, isNull);
        },
      );
    }

    test('能力越权（请求未声明能力）→ failed(launch)', () async {
      final b = await _mkBundle(bundleSigner, adapterId: 'school-x');
      final svc = await serviceFor(b, adapterId: 'school-x');
      final r = await svc.run(
        adapterId: 'school-x',
        capability: 'grade.list', // manifest 只声明 notice.list
        resolver: _ThrowingResolver(),
      );
      expect(r.ok, isFalse);
      expect(r.failureKind, CapabilityFailureKind.launch);
    });
  });

  group('SessionController.runCapability 接线', () {
    test('已选校（有 adapterId）→ 经注入 service 跑通', () async {
      // defaultSchool = XIDIAN，adapterId = school-xidian。
      final b = await _mkBundle(bundleSigner, adapterId: 'school-xidian');
      final svc = await serviceFor(b, adapterId: 'school-xidian');
      final session = SessionController(
        adapterServiceProvider: () async => svc,
      );
      session.selectSchool(testSchool());
      final logs = <String>[];
      final r = await session.runCapability(
        'notice.list',
        onLog: (level, message) => logs.add('$level:$message'),
      );
      expect(r.ok, isTrue, reason: r.reason);
      expect((r.data as Map)['items'], hasLength(1));
      expect(r.supportedCapabilities, {'notice.list'});
      expect(logs, ['info:HelloWorld']);
    });

    test('未选校 → failed(load)，不触 service', () async {
      final session = SessionController(
        adapterServiceProvider: () async => throw StateError('provider 不应被调用'),
      );
      final r = await session.runCapability('notice.list');
      expect(r.ok, isFalse);
      expect(r.failureKind, CapabilityFailureKind.load);
      expect(r.reason, contains('未选校'));
    });

    test('无 adapterServiceProvider（未装配）→ failed(load)', () async {
      final session = SessionController();
      session.selectSchool(testSchool());
      final r = await session.runCapability('notice.list');
      expect(r.ok, isFalse);
      expect(r.failureKind, CapabilityFailureKind.load);
      expect(r.reason, contains('未装配'));
    });

    test('能力需凭证且 store 空 → failed(auth)，不触 service', () async {
      final session = SessionController(
        adapterServiceProvider: () async => throw StateError('provider 不应被调用'),
      );
      session.selectSchool(testSchool());
      final r = await session.runCapability('grades.list');
      expect(r.ok, isFalse);
      expect(r.failureKind, CapabilityFailureKind.auth);
      expect(r.reason, isNotNull);
    });
  });
}
