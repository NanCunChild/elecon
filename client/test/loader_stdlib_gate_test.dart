/// 🔒 stdlibMin 门 —— `readEnvelopeStdlibMin`（权威取值 + fail-closed）+ `stdlibGate` 裁定。
///
/// stdlibGate 只收不可伪造的 [VerifiedBundle]：正例经 golden（Node 签）与在测试内自签两条路
/// 拿到已验签证据，再以 [hostStdlib] 覆盖构造「本端过旧/恰好/够新」三侧。
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:elecon/core/loader/bundle.dart';
import 'package:elecon/core/loader/signature.dart';
import 'package:elecon/core/loader/stdlib_gate.dart';
import 'package:elecon/core/loader/trust_anchors.dart';
import 'package:elecon/core/loader/verify.dart';
import 'package:elecon_contract/stdlib_version.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

Map<String, dynamic> _loaderGolden() =>
    readJson(repoPath('contract/golden/bundle/loader.json'));

BundleEnvelope _envWithManifest(String manifestJson) => BundleEnvelope(
      bundleFormat: kBundleFormat,
      files: [
        EnvelopeFile(
            path: 'manifest.json', encoding: 'utf-8', content: manifestJson),
      ],
    );

void main() {
  final golden = _loaderGolden();
  final validOfficial = (golden['cases'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((c) => c['name'] == 'valid_official');
  BundleEnvelope goldenEnv() => BundleEnvelope.fromJson(
      validOfficial['envelope'] as Map<String, dynamic>);

  // 用 golden 的**测试**公钥跑生产管线拿 VerifiedBundle（生产预埋集里当然没有它）。
  Future<VerifiedBundle> verifiedFromGolden() async {
    final sig = SignatureFile.fromJson(
        validOfficial['signature'] as Map<String, dynamic>);
    final r = await verifyBundleSignatureWith(
      goldenEnv(),
      sig,
      (keyId) => keyId == sig.keyId
          ? TrustAnchor(
              keyId: keyId,
              publicKeyHex: golden['publicKeyRawHex'] as String,
              active: true,
              note: 'golden 测试锚（仅测试）')
          : null,
    );
    expect(r.ok, isTrue, reason: r.reason);
    return r.value!;
  }

  group('readEnvelopeStdlibMin — 权威取值', () {
    test('golden manifest → 1.0.0', () {
      expect(readEnvelopeStdlibMin(goldenEnv()), '1.0.0');
    });
    test('runtime 空对象（无 stdlibMin）→ null（未声明下限）', () {
      final env = _envWithManifest(jsonEncode({
        'adapterId': 'school-x',
        'adapterVersion': '1.0.0',
        'runtime': <String, dynamic>{},
      }));
      expect(readEnvelopeStdlibMin(env), isNull);
    });
    test('无 runtime 块 → 拒（fail-closed，对齐 manifest.schema，评审 #2）', () {
      final env = _envWithManifest(
          jsonEncode({'adapterId': 'school-x', 'adapterVersion': '1.0.0'}));
      expect(() => readEnvelopeStdlibMin(env),
          throwsA(isA<BundleFormatException>()));
    });
    test('runtime 非对象（数组/字符串）→ 拒（fail-closed，评审 #2）', () {
      for (final bad in <Object>[
        <dynamic>[],
        'x',
        42,
      ]) {
        final env = _envWithManifest(jsonEncode({
          'adapterId': 'school-x',
          'adapterVersion': '1.0.0',
          'runtime': bad,
        }));
        expect(() => readEnvelopeStdlibMin(env),
            throwsA(isA<BundleFormatException>()),
            reason: 'runtime=$bad 应 fail-closed');
      }
    });
    test('stdlibMin 非 x.y.z → BundleFormatException（fail-closed）', () {
      final env = _envWithManifest(jsonEncode({
        'adapterId': 'school-x',
        'adapterVersion': '1.0.0',
        'runtime': {'stdlibMin': '1.0'},
      }));
      expect(() => readEnvelopeStdlibMin(env),
          throwsA(isA<BundleFormatException>()));
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

  group('stdlibGate — 未声明下限的 bundle（在测试内自签）', () {
    test('stdlibMin == null → 恒放行（连过旧本端也放）', () async {
      final kp = await Ed25519().newKeyPair();
      final pubHex = _hex((await kp.extractPublicKey()).bytes);
      final manifestJson = jsonEncode({
        'adapterId': 'school-nomin',
        'adapterVersion': '1.0.0',
        'runtime': <String, dynamic>{}, // 不声明 stdlibMin
      });
      final env = _envWithManifest(manifestJson);
      final digest = envelopeDigest(env);
      final payload = serializeSignaturePayload(
        adapterId: 'school-nomin',
        adapterVersion: '1.0.0',
        tier: kTierOfficial,
        digest: digest,
      );
      final sig = await Ed25519().sign(payload, keyPair: kp);
      final r = await verifyBundleSignatureWith(
        env,
        SignatureFile(
          adapterId: 'school-nomin',
          adapterVersion: '1.0.0',
          tier: kTierOfficial,
          digest: digest,
          signature: base64.encode(sig.bytes),
          keyId: 'test-bundle-key',
          algorithm: 'ed25519',
        ),
        (keyId) => keyId == 'test-bundle-key'
            ? TrustAnchor(
                keyId: keyId, publicKeyHex: pubHex, active: true, note: '测试锚')
            : null,
      );
      expect(r.ok, isTrue, reason: r.reason);
      expect(r.value!.stdlibMin, isNull);
      expect(stdlibGate(r.value!, hostStdlib: '0.0.1').allowed, isTrue);
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
