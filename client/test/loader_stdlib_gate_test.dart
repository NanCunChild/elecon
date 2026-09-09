/// 🔒 stdlibMin 门 —— `readEnvelopeStdlibMin`（权威取值 + fail-closed）+ `stdlibGate` 裁定。
///
/// stdlibGate 只收不可伪造的 [VerifiedBundle]：正例经 golden（Node 签）与在测试内自签两条路
/// 拿到已验签证据，再以 [hostStdlib] 覆盖构造「本端过旧/恰好/够新」三侧。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:elecon/core/loader/bundle.dart';
import 'package:elecon/core/loader/load_grant.dart';
import 'package:elecon/core/loader/revocation.dart';
import 'package:elecon/core/loader/signature.dart';
import 'package:elecon/core/loader/stdlib_gate.dart';
import 'package:elecon/core/loader/trust_anchors.dart';
import 'package:elecon/core/loader/verify.dart';
import 'package:elecon_contract/stdlib_version.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/bundle_fixture.dart';
import 'utils/test_utils.dart';

Map<String, dynamic> _loaderGolden() =>
    readJson(repoPath('contract/golden/bundle/loader.json'));

/// 造一份只含 `manifest.json` 的**已验签** bundle，取其 (envelope, blobs) 供 readEnvelopeStdlibMin 用。
///
/// digest v2 起 manifest 内容在 blob 表里（按内容寻址），故取值需要 envelope + blobs 两者——
/// 这不是"多一个参数"的麻烦，而是"清单与内容分离"在类型上的体现。
Future<({BundleEnvelope env, BlobTable blobs})> _withManifest(
  String manifestJson,
) async {
  final f = await makeBundle(
    {'manifest.json': manifestJson},
    adapterId: 'school-x',
    adapterVersion: '1.0.0',
  );
  final wire = readWire(f.packed);
  return (env: parseEnvelope(wire.envelopeBytes).envelope, blobs: wire.blobs);
}

void main() {
  final golden = _loaderGolden();
  final validOfficial = (golden['cases'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((c) => c['name'] == 'valid_official');


  // 用 golden 的**线上字节**跑生产管线拿 VerifiedBundle（注入 golden 的测试锚）。
  Future<VerifiedBundle> verifiedFromGolden() async {
    final packed = Uint8List.fromList(
      base64.decode(validOfficial['packedBundleBase64'] as String),
    );
    final keyId = readWire(packed).signatureJson['keyId'] as String;
    final r = await openBundleWith(
      packed,
      (id) => id == keyId
          ? TrustAnchor(
              keyId: id,
              publicKeyHex: golden['publicKeyRawHex'] as String,
              active: true,
              note: 'golden 测试锚（仅测试）',
            )
          : null,
    );
    expect(r.ok, isTrue, reason: r.reason);
    return r.value!;
  }

  group('readEnvelopeStdlibMin — 权威取值', () {
    test('golden manifest → 1.0.0（取自已验签产物）', () async {
      final v = await verifiedFromGolden();
      expect(readEnvelopeStdlibMin(v.envelope, v.blobs), '1.0.0');
      expect(v.stdlibMin, '1.0.0', reason: '验签时已捕获，两者须一致');
    });
    test('runtime 空对象（无 stdlibMin）→ null（未声明下限）', () async {
      final b = await _withManifest(
        jsonEncode({
          'adapterId': 'school-x',
          'adapterVersion': '1.0.0',
          'runtime': <String, dynamic>{},
        }),
      );
      expect(readEnvelopeStdlibMin(b.env, b.blobs), isNull);
    });
    test('无 runtime 块 → 拒（fail-closed，对齐 manifest.schema，评审 #2）', () async {
      final b = await _withManifest(
        jsonEncode({'adapterId': 'school-x', 'adapterVersion': '1.0.0'}),
      );
      expect(
        () => readEnvelopeStdlibMin(b.env, b.blobs),
        throwsA(isA<BundleFormatException>()),
      );
    });
    test('runtime 非对象（数组/字符串）→ 拒（fail-closed，评审 #2）', () async {
      for (final bad in <Object>[<dynamic>[], 'x', 42]) {
        final b = await _withManifest(
          jsonEncode({
            'adapterId': 'school-x',
            'adapterVersion': '1.0.0',
            'runtime': bad,
          }),
        );
        expect(
          () => readEnvelopeStdlibMin(b.env, b.blobs),
          throwsA(isA<BundleFormatException>()),
          reason: 'runtime=$bad 应 fail-closed',
        );
      }
    });
    test('stdlibMin 非 x.y.z → BundleFormatException（fail-closed）', () async {
      final b = await _withManifest(
        jsonEncode({
          'adapterId': 'school-x',
          'adapterVersion': '1.0.0',
          'runtime': {'stdlibMin': '1.0'},
        }),
      );
      expect(
        () => readEnvelopeStdlibMin(b.env, b.blobs),
        throwsA(isA<BundleFormatException>()),
      );
    });
  });

  group('stdlibGate — 本端 stdlib 对 bundle 声明下限', () {
    late VerifiedBundle bundle; // stdlibMin = 1.0.0

    setUpAll(() async {
      bundle = await verifiedFromGolden();
      expect(bundle.stdlibMin, '1.0.0'); // 前提：门的输入取自已验签的权威值
    });

    test('本端恰好等于下限 → 放行', () {
      expect(stdlibGate(bundle, hostStdlib: '1.0.0').allowed, isTrue);
    });
    test('本端高于下限 → 放行（append-only 前向兼容）', () {
      expect(stdlibGate(bundle, hostStdlib: '2.0.0').allowed, isTrue);
      expect(stdlibGate(bundle, hostStdlib: '1.0.1').allowed, isTrue);
      expect(stdlibGate(bundle, hostStdlib: '1.10.0').allowed, isTrue);
    });
    test('本端低于下限 → 拒（需升级 app）', () {
      final d = stdlibGate(bundle, hostStdlib: '0.9.0');
      expect(d.allowed, isFalse);
      expect(d.reason, stringContainsInOrder(['升级']));
    });
    test('本端非 x.y.z → fail-closed 拒', () {
      expect(stdlibGate(bundle, hostStdlib: 'weird').allowed, isFalse);
    });
    test('默认 hostStdlib = kHostStdlibVersion，对 golden(1.0.0) 放行', () {
      expect(kHostStdlibVersion, matches(r'^\d+\.\d+\.\d+$'));
      expect(stdlibGate(bundle).allowed, isTrue);
    });
  });

  // 一份已验签的空 revocation（供 mintOfficialGrant 的吊销步放行）。
  Future<VerifiedRevocationList> emptyVerifiedRevocation() async {
    final kp = await Ed25519().newKeyPair();
    final pubHex = _hex((await kp.extractPublicKey()).bytes);
    final json = jsonEncode({
      'sequence': 1,
      'issuedAt': '2026-07-17T00:00:00Z',
      'ttlSeconds': 86400,
      'minVersions': <String, String>{},
      'killSwitch': false,
      'entries': <Map<String, dynamic>>[],
    });
    // 域分隔（ADR-002 §2.3）：签 `elecon.revocation/1 ‖ 0x00 ‖ listJson 字节`。
    final sig = await Ed25519()
        .sign(withContext(kContextTagRevocation, utf8.encode(json)), keyPair: kp);
    final signed = SignedRevocationList(
      listJson: json,
      signature: base64.encode(sig.bytes),
      keyId: 'test-rev',
      algorithm: 'ed25519',
    );
    final r = await verifyRevocationWith(
      signed,
      (kid) => kid == 'test-rev'
          ? TrustAnchor(
              keyId: kid,
              publicKeyHex: pubHex,
              active: true,
              note: '测试锚',
            )
          : null,
    );
    expect(r.ok, isTrue, reason: r.reason);
    return r.value!;
  }

  group('mintOfficialGrant — §2.6 第 5/6 步（hostStdlib 锁定，评审 P1）', () {
    test('生产铸造（固定 kHostStdlibVersion）+ golden bundle → ok grant', () async {
      final bundle = await verifiedFromGolden(); // stdlibMin=1.0.0
      final rev = await emptyVerifiedRevocation();
      final g = mintOfficialGrant(bundle: bundle, revocation: rev);
      expect(g.ok, isTrue, reason: g.reason);
      expect(g.grant!.bundle.digest, bundle.digest);
    });

    // 本端 stdlib 低于 bundle 声明下限 → 拒（原经 loader hostStdlib:'0.9.0' 测；生产 loader 已不
    // 接受该覆盖，故 relocate 到此，用仅测试的 mintOfficialGrantForHost）。
    test('mintOfficialGrantForHost 本端过旧 → deny（stdlibMin）', () async {
      final bundle = await verifiedFromGolden();
      final rev = await emptyVerifiedRevocation();
      final g = mintOfficialGrantForHost(
        bundle: bundle,
        revocation: rev,
        hostStdlib: '0.9.0',
      );
      expect(g.ok, isFalse);
      expect(g.reason, contains('stdlibMin'));
    });
  });

  group('stdlibGate — 未声明下限的 bundle（在测试内自签）', () {
    test('stdlibMin == null → 恒放行（连过旧本端也放）', () async {
      // 整段自签从二十行收到两行——正是 `utils/bundle_fixture.dart` 存在的理由：
      // 每份手拼的 envelope 都是一份可能与生产编码漂移的影子实现。
      final f = await makeBundle({
        'manifest.json': manifestJson(
          adapterId: 'school-nomin',
          stdlibMin: null, // 不声明下限
        ),
      });
      final v = await verifyFixture(f);
      expect(v.stdlibMin, isNull);
      expect(stdlibGate(v, hostStdlib: '0.0.1').allowed, isTrue);
    });
  });
}

String _hex(List<int> b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
