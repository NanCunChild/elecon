/// 🔒 last-good 持久化 —— write 只收不可伪造 Verified* 令牌（评审 #4）+ 原始 Signed* 字节；
/// 原样往返；缺/损坏 → null（回退 bootstrap）。Verified* 经 golden 验签管线获得（私有构造）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/loader/catalog.dart';
import 'package:elecon/core/loader/last_good_store.dart';
import 'package:elecon/core/loader/revocation.dart';
import 'package:elecon/core/loader/trust_anchors.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

/// 复用 catalog golden：验签得到 (VerifiedCatalog, 其源 SignedCatalog)。
Future<(VerifiedCatalog, SignedCatalog)> _verifiedCatalog() async {
  final g = readJson(repoPath('contract/golden/catalog/catalog.json'));
  final c = (g['cases'] as List).cast<Map<String, dynamic>>().firstWhere(
    (c) => c['name'] == 'valid_multibyte_identity',
  );
  final signed = SignedCatalog.fromJson(c['signed'] as Map<String, dynamic>);
  final r = await verifyCatalogWith(
    signed,
    (keyId) => keyId == signed.keyId
        ? TrustAnchor(
            keyId: keyId,
            publicKeyHex: c['publicKeyRawHex'] as String,
            active: true,
            note: 'golden 测试锚',
          )
        : null,
  );
  expect(r.ok, isTrue, reason: r.reason);
  return (r.value!, signed);
}

Future<(VerifiedRevocationList, SignedRevocationList)>
_verifiedRevocation() async {
  final g = readJson(repoPath('contract/golden/revocation/revocation.json'));
  final c = (g['cases'] as List).cast<Map<String, dynamic>>().firstWhere(
    (c) => c['name'] == 'valid_multibyte_reason',
  );
  final signed = SignedRevocationList.fromJson(
    c['signed'] as Map<String, dynamic>,
  );
  final r = await verifyRevocationWith(
    signed,
    (keyId) => keyId == signed.keyId
        ? TrustAnchor(
            keyId: keyId,
            publicKeyHex: c['publicKeyRawHex'] as String,
            active: true,
            note: 'golden 测试锚',
          )
        : null,
  );
  expect(r.ok, isTrue, reason: r.reason);
  return (r.value!, signed);
}

void main() {
  late InMemoryBlobStore store;
  late LastGoodStore lg;
  setUp(() {
    store = InMemoryBlobStore();
    lg = LastGoodStore(store);
  });

  group('catalog', () {
    test('空 → null', () async => expect(await lg.readCatalog(), isNull));

    test('写（Verified+Signed）→ 读 原样往返（被签名字节不变）', () async {
      final (v, signed) = await _verifiedCatalog();
      await lg.writeCatalog(v, signed);
      final back = await lg.readCatalog();
      expect(back, isNotNull);
      expect(back!.catalogJson, signed.catalogJson);
      expect(back.signature, signed.signature);
      expect(back.keyId, signed.keyId);
      expect(back.algorithm, signed.algorithm);
    });

    test('较旧 sequence 不得覆盖现有 last-good', () async {
      final (v, signed) = await _verifiedCatalog();
      final newer = <String, dynamic>{
        ...signed.toJson(),
        'catalogJson': jsonEncode({
          'catalogVersion': '1.0',
          'sequence': 999,
          'issuedAt': '2026-07-19T00:00:00Z',
          'ttlSeconds': 86400,
          'entries': <dynamic>[],
        }),
      };
      await store.write(
        'last-good/catalog.json',
        Uint8List.fromList(utf8.encode(jsonEncode(newer))),
      );
      await lg.writeCatalog(v, signed);
      expect((await lg.readCatalog())!.catalogJson, newer['catalogJson']);
    });

    test('Signed 与 Verified keyId 不符 → ArgumentError（不落地）', () async {
      final (v, signed) = await _verifiedCatalog();
      final wrong = SignedCatalog(
        catalogJson: signed.catalogJson,
        signature: signed.signature,
        keyId: 'different-key',
        algorithm: signed.algorithm,
      );
      expect(() => lg.writeCatalog(v, wrong), throwsArgumentError);
      expect(await lg.readCatalog(), isNull);
    });

    test('损坏字节 → null（不抛）', () async {
      await store.write(
        'last-good/catalog.json',
        Uint8List.fromList(utf8.encode('{not json')),
      );
      expect(await lg.readCatalog(), isNull);
    });
    test('缺字段 → null（fromJson 抛被吞）', () async {
      await store.write(
        'last-good/catalog.json',
        Uint8List.fromList(utf8.encode('{"catalogJson":"{}"}')),
      );
      expect(await lg.readCatalog(), isNull);
    });
  });

  group('revocation', () {
    test('空 → null', () async => expect(await lg.readRevocation(), isNull));

    test('写（Verified+Signed）→ 读 原样往返', () async {
      final (v, signed) = await _verifiedRevocation();
      await lg.writeRevocation(v, signed);
      final back = await lg.readRevocation();
      expect(back, isNotNull);
      expect(back!.listJson, signed.listJson);
      expect(back.keyId, signed.keyId);
    });

    test('keyId 不符 → ArgumentError', () async {
      final (v, signed) = await _verifiedRevocation();
      final wrong = SignedRevocationList(
        listJson: signed.listJson,
        signature: signed.signature,
        keyId: 'nope',
        algorithm: signed.algorithm,
      );
      expect(() => lg.writeRevocation(v, wrong), throwsArgumentError);
    });

    test('损坏 → null', () async {
      await store.write(
        'last-good/revocation.json',
        Uint8List.fromList([0xff, 0xfe]),
      );
      expect(await lg.readRevocation(), isNull);
    });
  });

  test('catalog 与 revocation 各自独立槽位', () async {
    final (vc, sc) = await _verifiedCatalog();
    await lg.writeCatalog(vc, sc);
    expect(await lg.readRevocation(), isNull);
    final (vr, sr) = await _verifiedRevocation();
    await lg.writeRevocation(vr, sr);
    expect(await lg.readCatalog(), isNotNull);
  });
}
