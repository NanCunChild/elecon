/// 🔒 内容寻址 bundle 缓存 —— write 只收已验签 + 内容寻址自洽；read 重算 digest 自校验。
library;

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/loader/bundle.dart';
import 'package:elecon/core/loader/bundle_cache.dart';
import 'package:elecon/core/loader/signature.dart';
import 'package:elecon/core/loader/trust_anchors.dart';
import 'package:elecon/core/loader/verify.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

Map<String, dynamic> _loaderGolden() =>
    readJson(repoPath('contract/golden/bundle/loader.json'));

/// 手工打一个 packed bundle（`gzip(JSON({envelope, signature?}))`），供构造"内容寻址不符"的字节。
Uint8List _pack(Map<String, dynamic> envelopeJson, [Map<String, dynamic>? sig]) =>
    Uint8List.fromList(gzip.encode(utf8.encode(
        jsonEncode({'envelope': envelopeJson, 'signature': ?sig}))));

Map<String, dynamic> _envJson(String manifestJson) => {
      'bundleFormat': kBundleFormat,
      'files': [
        {'path': 'manifest.json', 'encoding': 'utf-8', 'content': manifestJson},
      ],
    };

void main() {
  final golden = _loaderGolden();
  final valid = (golden['cases'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((c) => c['name'] == 'valid_official');
  final expectedDigest = golden['expectedDigest'] as String;
  final packedGolden =
      Uint8List.fromList(base64.decode(golden['packedBundleBase64'] as String));

  Future<VerifiedBundle> verifiedGolden() async {
    final sig = SignatureFile.fromJson(valid['signature'] as Map<String, dynamic>);
    final r = await verifyBundleSignatureWith(
      BundleEnvelope.fromJson(valid['envelope'] as Map<String, dynamic>),
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

  late InMemoryBlobStore store;
  late BundleCache cache;
  setUp(() {
    store = InMemoryBlobStore();
    cache = BundleCache(store);
  });

  group('write — 只收已验签 + 内容寻址自洽', () {
    test('验签证据 + 匹配 packed → 落地，read 取回 envelope + 签名', () async {
      final v = await verifiedGolden();
      await cache.write(v, packedGolden);
      final cb = await cache.read(expectedDigest);
      expect(cb, isNotNull);
      expect(envelopeDigest(cb!.envelope), expectedDigest);
      // 携签：读回后可据此重跑 verifyBundleSignature（评审 #1）。
      expect(cb.signature.digest, expectedDigest);
    });

    test('packed digest 匹配但缺 detached 签名 → 拒（评审 #1/#2）', () async {
      final v = await verifiedGolden();
      // 打一份**同 envelope**（故 digest 匹配）但不含 signature 的 packed。
      final noSig = _pack(valid['envelope'] as Map<String, dynamic>);
      expect(() => cache.write(v, noSig),
          throwsA(isA<BundleFormatException>()));
      expect(await cache.has(expectedDigest), isFalse);
    });

    test('packed 内容寻址与验签证据不符 → 拒（fail-closed）', () async {
      final v = await verifiedGolden(); // digest = expectedDigest
      final other = _pack(_envJson(jsonEncode({
        'adapterId': 'school-other',
        'adapterVersion': '9.9.9',
        'runtime': {'stdlibMin': '1.0.0'},
      })));
      expect(() => cache.write(v, other),
          throwsA(isA<BundleFormatException>()));
      // 且未落地
      expect(await cache.has(expectedDigest), isFalse);
    });

    test('packed 是畸形 gzip → BundleFormatException', () async {
      final v = await verifiedGolden();
      expect(() => cache.write(v, Uint8List.fromList([1, 2, 3])),
          throwsA(isA<BundleFormatException>()));
    });
  });

  group('read — 内容寻址自校验', () {
    test('未命中 → null', () async {
      expect(await cache.read('a' * 64), isNull);
    });
    test('畸形 digest key → null（不碰磁盘）', () async {
      expect(await cache.read('not-a-digest'), isNull);
    });
    test('缓存字节损坏 → null（视为未命中）', () async {
      await store.write('bundles/$expectedDigest.bundle',
          Uint8List.fromList([9, 9, 9]));
      expect(await cache.read(expectedDigest), isNull);
    });
    test('缓存 digest 匹配但缺签名 → null（无法重验，视为未命中）', () async {
      await store.write('bundles/$expectedDigest.bundle',
          _pack(valid['envelope'] as Map<String, dynamic>));
      expect(await cache.read(expectedDigest), isNull);
    });
    test('存在但内容寻址不符（存到错的 key 名下）→ null', () async {
      // 把合法 packed 存到"另一个 digest"名下：read 重算 digest != key → 丢弃。
      const wrongKey =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      await store.write('bundles/$wrongKey.bundle', packedGolden);
      expect(await cache.read(wrongKey), isNull);
    });
  });

  group('解压护栏（评审 #5，unpackBundle 边界）', () {
    test('解压体超上限 → 拒（压缩炸弹护栏）', () {
      // 极高压缩比：小 gz，解压后 > kMaxBundlePayloadBytes。
      final bomb = Uint8List.fromList(
          gzip.encode(utf8.encode('a' * (kMaxBundlePayloadBytes + 1024))));
      expect(bomb.length, lessThan(4096), reason: '构造的 gz 应很小（高压缩比）');
      expect(() => unpackBundle(bomb), throwsA(isA<BundleFormatException>()));
    });
    test('压缩输入超上限 → 拒（不进解压）', () {
      final big = Uint8List(kMaxBundleGzBytes + 1);
      expect(() => unpackBundle(big), throwsA(isA<BundleFormatException>()));
    });
  });

  group('has / evict', () {
    test('write→has=true；evict→has=false', () async {
      final v = await verifiedGolden();
      await cache.write(v, packedGolden);
      expect(await cache.has(expectedDigest), isTrue);
      await cache.evict(expectedDigest);
      expect(await cache.has(expectedDigest), isFalse);
    });
    test('evict 畸形 digest → no-op（不抛）', () async {
      await cache.evict('bad');
    });
  });
}
