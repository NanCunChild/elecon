/// 🔒 加载器验签 —— 与 Node 签端**共享 golden**（`contract/golden/bundle/loader.json`）。
///
/// 落实 ADR-002 §3 风险 5：规范化规格已钉死，残余风险在**跨平台实现一致性**。
/// 本测试让 Dart 侧照 Node 生成的真实 Ed25519 向量跑——digest 拼接/排序、payload 键序、
/// utf-8/base64 解码、身份核对任一处漂移即红。
///
/// golden 由 `tools/src/bundle/make-loader-golden.ts` 确定性生成；改签端行为须重跑它并复核 diff。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:elecon/core/loader/bundle.dart';
import 'package:elecon/core/loader/signature.dart';
import 'package:elecon/core/loader/trust_anchors.dart';
import 'package:elecon/core/loader/verify.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

Map<String, dynamic> _readLoaderGolden() =>
    readJson(repoPath('contract/golden/bundle/loader.json'));

BundleEnvelope _env(Map<String, dynamic> json) =>
    BundleEnvelope.fromJson(json['envelope'] as Map<String, dynamic>);

SignatureFile _sig(Map<String, dynamic> json) =>
    SignatureFile.fromJson(json['signature'] as Map<String, dynamic>);

/// 把 golden 里的测试公钥装进信任锚位置——生产预埋集里当然没有它。
/// 通过替换 keyId 让 `activeAnchorByKeyId` 命中真实预埋锚是**错的**（那会用错公钥），
/// 故这里直接对 golden 的 publicKeyRawHex 做低层验签比对，见 `_verifyWithKey`。
void main() {
  final golden = _readLoaderGolden();

  group('loader golden（Dart × Node 跨语言钉死）', () {
    test('golden 非空且自洽', () {
      expect((golden['cases'] as List), isNotEmpty);
      expect(golden['publicKeyRawHex'], isA<String>());
      expect(golden['expectedDigest'], isA<String>());
    });

    // ---- envelopeDigest：与 Node 逐字节一致 ----
    test('envelopeDigest 与 Node 一致（且内部排序，不依赖输入顺序）', () {
      final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();
      final valid = cases.firstWhere((c) => c['name'] == 'valid_official');
      final env = _env(valid);
      expect(envelopeDigest(env), golden['expectedDigest']);

      // golden 里 files 刻意乱序；打乱后 digest 必须不变（排序在函数内做）。
      final shuffled = BundleEnvelope(
        bundleFormat: env.bundleFormat,
        files: env.files.reversed.toList(),
      );
      expect(envelopeDigest(shuffled), golden['expectedDigest'],
          reason: 'digest 不得依赖 files 的输入顺序');
    });

    // ---- serializeSignaturePayload：跨语言的窄腰 ----
    test('serializeSignaturePayload 与 Node 逐字节一致（键序 + UTF-8）', () {
      final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();
      final valid = cases.firstWhere((c) => c['name'] == 'valid_official');
      final sig = _sig(valid);
      final payload = serializeSignaturePayload(
        adapterId: sig.adapterId,
        adapterVersion: sig.adapterVersion,
        tier: sig.tier,
        digest: sig.digest,
      );
      expect(utf8.decode(payload), golden['expectedPayloadUtf8']);
    });

    // ---- gzip-JSON 拆包：与 Node packBundle 互通 ----
    test('unpackBundle 能拆 Node 的 gzip-JSON 产物', () {
      final packed = base64.decode(golden['packedBundleBase64'] as String);
      final un = unpackBundle(Uint8List.fromList(packed));
      expect(un.envelope.bundleFormat, kBundleFormat);
      expect(envelopeDigest(un.envelope), golden['expectedDigest'],
          reason: '往返后 digest 必须稳定');
      expect(un.signature, isNotNull);
    });

    // ---- 身份：权威来源是 envelope 内 manifest ----
    test('readEnvelopeIdentity 取自 envelope 内 manifest.json', () {
      final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();
      final valid = cases.firstWhere((c) => c['name'] == 'valid_official');
      final identity = readEnvelopeIdentity(_env(valid));
      expect(identity.adapterId, 'school-golden');
      expect(identity.adapterVersion, '1.2.3');
    });

    // ---- 逐案跑完整验签管线 ----
    for (final c in (golden['cases'] as List).cast<Map<String, dynamic>>()) {
      final name = c['name'] as String;
      final expected = c['expect'] as Map<String, dynamic>;
      test('case: $name — ${c['_why']}', () async {
        final result = await _verifyWithKey(
          c,
          keyHex: c['publicKeyRawHex'] as String,
        );
        if (expected['ok'] == true) {
          expect(result.ok, isTrue, reason: '应验过，实际：${result.reason}');
          expect(result.value!.digest, golden['expectedDigest']);
          expect(result.value!.keyId, _sig(c).keyId);
          // 权威身份来自 manifest，而非签名声明
          expect(result.value!.identity.adapterId, 'school-golden');
        } else {
          expect(result.ok, isFalse, reason: '必须拒（fail-closed）');
          expect(result.reason, contains(expected['reasonContains'] as String));
        }
      });
    }
  });

  group('信任锚（预埋 pin 集合，🔒 信任根）', () {
    test('本轮 ceremony 的 active 锚已预埋且为裸 32B', () {
      final anchor = activeAnchorByKeyId('elecon-official-ncc-1');
      expect(anchor, isNotNull);
      expect(anchor!.publicKeyBytes().length, 32);
      expect(anchor.active, isTrue);
    });

    test('files 含非对象项 → 结构化格式异常', () {
      expect(
        () => BundleEnvelope.fromJson({
          'bundleFormat': kBundleFormat,
          'files': <Object?>[42],
        }),
        throwsA(isA<BundleFormatException>()),
      );
    });

    test('非法 base64 → 结构化格式异常', () {
      final env = BundleEnvelope(
        bundleFormat: kBundleFormat,
        files: const <EnvelopeFile>[
          EnvelopeFile(
              path: 'manifest.json', encoding: 'base64', content: '%%%'),
        ],
      );
      expect(() => envelopeDigest(env), throwsA(isA<BundleFormatException>()));
    });

    test('未知 keyId → null（fail-closed）', () {
      expect(activeAnchorByKeyId('does-not-exist'), isNull);
    });

    test('golden 的测试公钥绝不在预埋集合内', () {
      // 若这条红了，说明有人把测试密钥当信任根提交了 —— 灾难级。
      final testKeyHex = golden['publicKeyRawHex'] as String;
      for (final a in kTrustAnchors) {
        expect(a.publicKeyHex, isNot(testKeyHex),
            reason: '测试公钥混进了预埋 pin 集合（🔒 信任根被污染）');
      }
    });

    test('dormant 锚不得参与验签（放大信任只能随发版）', () {
      // 现状只有 1 把 active；此测试钉死 activeAnchorByKeyId 的语义，
      // 将来加 dormant 锚时不至于被"顺手放行"。
      for (final a in kTrustAnchors) {
        final found = activeAnchorByKeyId(a.keyId);
        if (!a.active) {
          expect(found, isNull, reason: 'dormant 锚 ${a.keyId} 不得被取到');
        }
      }
    });
  });

  group('sideload 档不可由远程签名裁定（ADR-002 §2.5 闸门不交给网络输入）', () {
    test('签名声称 tier=sideload → 拒，不得映射为 devSideload', () async {
      final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();
      final valid = cases.firstWhere((c) => c['name'] == 'valid_official');
      final sigJson =
          Map<String, dynamic>.from(valid['signature'] as Map<String, dynamic>);
      sigJson['tier'] = 'sideload';
      final result = await verifyBundleSignature(
        _env(valid),
        SignatureFile.fromJson(sigJson),
      );
      // 改了 tier → payload 变了 → 先在 Ed25519 处就拒；即便签名对也会在档位裁定处拒。
      expect(result.ok, isFalse);
    });
  });
}

/// 用 golden 的**测试**公钥跑**同一条生产管线**。
///
/// 生产 `verifyBundleSignature` 只认预埋 const 锚集（信任根不可运行时替换，这正是我们要的），
/// 而 golden 用测试密钥——故经 `verifyBundleSignatureWith` 注入一个只认该 keyId 的 resolver。
/// 注意跑的是**同一个函数体**，不是复刻，故顺序与失败语义与生产一致。
Future<VerifyResult<VerifiedBundle>> _verifyWithKey(
  Map<String, dynamic> c, {
  required String keyHex,
}) async {
  final sig = _sig(c);
  return verifyBundleSignatureWith(
    _env(c),
    sig,
    (keyId) => keyId == sig.keyId
        ? TrustAnchor(
            keyId: keyId,
            publicKeyHex: keyHex,
            active: true,
            note: 'golden 测试锚（仅测试）',
          )
        : null,
  );
}
