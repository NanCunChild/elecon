/// 🔒 加载器验签 —— 与 Node 签端**共享 golden**（`contract/golden/bundle/loader.json`）。
///
/// 落实 ADR-002 §3 风险 5：规范化规格已钉死，残余风险在**跨平台实现一致性**。
/// 本测试让 Dart 侧照 Node 生成的真实 Ed25519 向量跑——digest、payload 键序与域分隔前缀、
/// base64 解码、卫生闸门、blob 校验、身份三方一致，任一处漂移即红。
///
/// **v2 起 golden 只给「线上原始字节」**（`packedBundleBase64`），不给解析好的 envelope 对象：
/// 给对象等于替 Dart 做完了解析，恰好绕过 digest v2 最重要的纪律（验签先于解析、哈希收到的
/// 那串字节）。现在两端跑的是**同一条管线的同一份输入**。
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

Uint8List _packed(Map<String, dynamic> c) =>
    Uint8List.fromList(base64.decode(c['packedBundleBase64'] as String));

void main() {
  final golden = _readLoaderGolden();
  final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();
  final valid = cases.firstWhere((c) => c['name'] == 'valid_official');

  group('loader golden（Dart × Node 跨语言钉死）', () {
    test('golden 非空且自洽', () {
      expect(cases, isNotEmpty);
      expect(golden['publicKeyRawHex'], isA<String>());
      expect(golden['expectedDigest'], isA<String>());
      expect(golden['bundleFormat'], kBundleFormat,
          reason: 'golden 与 Dart 侧必须是同一个 bundle 格式');
    });

    // ---- 传输封套：与 Node packBundle 互通，且 digest 只认字节 ----
    test('readWire 能拆 Node 的传输封套，envelopeDigest 与 Node 一致', () {
      final wire = readWire(_packed(valid));
      expect(envelopeDigest(wire.envelopeBytes), golden['expectedDigest'],
          reason: 'digest = SHA-256(envelopeBytes)，两端必须逐字节一致');
      expect(utf8.decode(wire.envelopeBytes), golden['expectedEnvelopeUtf8'],
          reason: 'envelope 的序列化字节（键序/空白/文件序）必须与 Node 一致');
      expect(wire.signatureJson['algorithm'], 'ed25519');
      expect(wire.blobs, isNotEmpty);
    });

    // ---- serializeSignaturePayload：跨语言的窄腰（含域分隔前缀） ----
    test('serializeSignaturePayload 与 Node 逐字节一致（键序 + UTF-8 + contextTag）', () {
      final sig = SignatureFile.fromJson(readWire(_packed(valid)).signatureJson);
      final payload = serializeSignaturePayload(
        adapterId: sig.adapterId,
        adapterVersion: sig.adapterVersion,
        tier: sig.tier,
        digest: sig.digest,
      );
      expect(_hex(payload), golden['expectedPayloadHex']);
      // 前缀确实在——若少了它，两端就再也验不通对方的签名（且是静默的）。
      expect(utf8.decode(payload.sublist(0, kContextTagBundle.length)),
          golden['contextTagBundle']);
      expect(payload[kContextTagBundle.length], 0x00,
          reason: 'contextTag 与正文之间须有 0x00 分隔');
    });

    // ---- 逐案跑完整验签管线 ----
    for (final c in cases) {
      final name = c['name'] as String;
      final expected = c['expect'] as Map<String, dynamic>;
      test('case: $name — ${c['_why']}', () async {
        final result = await _openWithKey(
          c,
          keyHex: c['publicKeyRawHex'] as String,
        );

        if (expected['ok'] != true) {
          expect(result.ok, isFalse, reason: '必须拒（fail-closed）');
          expect(result.reason, contains(expected['reasonContains'] as String),
              reason: '不仅要拒，还要**拒在同一步**——否则两端的失败语义已经分叉');
          return;
        }

        // `loaderMustRefuse`：验签层成立（密码学事实），但**加载器必须拒**。
        // Dart 的 openBundle 就是加载器入口，故这里期望它拒（与 TS 的 openBundle 刻意不同，
        // 见 verify.dart 文件头「与 TS openBundle 的两处刻意差异」）。
        if (expected['loaderMustRefuse'] == true) {
          expect(result.ok, isFalse,
              reason: '远程签名不得自称 sideload 进 dev 档（ADR-002 §2.5）');
          expect(result.reason, contains('档位'));
          return;
        }

        expect(result.ok, isTrue, reason: '应验过，实际：${result.reason}');
        final v = result.value!;
        expect(v.digest, expected['digest']);
        expect(v.identity.adapterId, 'school-golden',
            reason: '权威身份取自 envelope 内 manifest，而非签名声明');
        expect(v.identity.adapterVersion, '1.2.3');
        expect(v.stdlibMin, '1.0.0');
        // 验签产物**携带内容**：验的那份就是要用的那份。
        expect(envelopeDigest(v.envelopeBytes), v.digest);
        expect(
          utf8.decode(fileBytesByPath(v.envelope, v.blobs, 'index.js')!),
          contains('notice.list'),
        );
        // 内容相同的两个文件共用一个 blob（按内容寻址，非按路径）。
        expect(fileBytesByPath(v.envelope, v.blobs, 'a.txt'),
            fileBytesByPath(v.envelope, v.blobs, 'b.txt'));
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
      for (final a in kTrustAnchors) {
        final found = activeAnchorByKeyId(a.keyId);
        if (!a.active) {
          expect(found, isNull, reason: 'dormant 锚 ${a.keyId} 不得被取到');
        }
      }
    });

    test('未知 keyId 的 bundle 被拒（不落到「碰巧有把公钥能验过」）', () async {
      final wire = readWire(_packed(valid));
      final result = await openBundleWith(_packed(valid), (_) => null);
      expect(result.ok, isFalse);
      expect(result.reason, contains('信任锚'));
      expect(wire.signatureJson['keyId'], 'golden-test-key');
    });
  });

  group('结构畸形 → BundleFormatException（fail-closed，非 crash）', () {
    test('非 gzip 字节', () {
      expect(() => readWire(Uint8List.fromList(utf8.encode('not gzip'))),
          throwsA(isA<BundleFormatException>()));
    });

    test('envelope files 含非对象项', () {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode({
        'bundleFormat': kBundleFormat,
        'adapterId': 'x',
        'adapterVersion': '1.0.0',
        'files': <Object?>[42],
      })));
      expect(() => parseEnvelope(bytes), throwsA(isA<BundleFormatException>()));
    });

    test('envelope 含未知字段（严格解析，防降级面）', () {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode({
        'bundleFormat': kBundleFormat,
        'adapterId': 'x',
        'adapterVersion': '1.0.0',
        'files': <Object?>[],
        'extra': 1,
      })));
      expect(() => parseEnvelope(bytes), throwsA(isA<BundleFormatException>()));
    });

    test('descriptor.sha256 非 64 位小写 hex', () {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode({
        'bundleFormat': kBundleFormat,
        'adapterId': 'x',
        'adapterVersion': '1.0.0',
        'files': [
          {'path': 'a.js', 'size': 1, 'sha256': 'ABC'},
        ],
      })));
      expect(() => parseEnvelope(bytes), throwsA(isA<BundleFormatException>()));
    });
  });
}

String _hex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// 用 golden 的**测试**公钥跑**同一条生产管线**。
///
/// 生产 `openBundle` 只认预埋 const 锚集（信任根不可运行时替换，这正是我们要的），
/// 而 golden 用测试密钥——故经 `openBundleWith` 注入一个只认该 keyId 的 resolver。
/// 注意跑的是**同一个函数体**，不是复刻，故顺序与失败语义与生产一致。
Future<VerifyResult<VerifiedBundle>> _openWithKey(
  Map<String, dynamic> c, {
  required String keyHex,
}) async {
  final packed = _packed(c);
  // keyId 从封套里取；封套本身畸形的用例（wire_extra_field）取不到，用占位值即可——
  // 那条用例会在第 2 步就拒，根本走不到 resolver。
  String keyId;
  try {
    keyId = readWire(packed).signatureJson['keyId'] as String? ?? '';
  } on BundleFormatException {
    keyId = '';
  }
  return openBundleWith(
    packed,
    (id) => id == keyId && keyId.isNotEmpty
        ? TrustAnchor(
            keyId: id,
            publicKeyHex: keyHex,
            active: true,
            note: 'golden 测试锚（仅测试）',
          )
        : null,
  );
}
