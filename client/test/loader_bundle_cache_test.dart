/// 🔒 内容寻址 bundle 缓存 —— write 只收已验签 + 内容寻址自洽；read 重算 digest 自校验。
library;

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/loader/bundle.dart';
import 'package:elecon/core/loader/bundle_cache.dart';
import 'package:elecon/core/loader/verify.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/bundle_fixture.dart';

void main() {
  late BundleFixture fixture;
  late VerifiedBundle verified;
  late String expectedDigest;

  setUpAll(() async {
    fixture = await makeBundle({
      'manifest.json': manifestJson(adapterId: 'school-cache'),
      'index.js': 'export const x = 1;\n',
    });
    verified = await verifyFixture(fixture);
    expectedDigest = fixture.digest;
  });

  late InMemoryBlobStore store;
  late BundleCache cache;
  setUp(() {
    store = InMemoryBlobStore();
    cache = BundleCache(store);
  });

  group('write — 只收已验签 + 内容寻址自洽', () {
    test('验签证据 + 匹配 packed → 落地，read 取回**原始字节**', () async {
      await cache.write(verified, fixture.packed);
      final bytes = await cache.read(expectedDigest);
      expect(bytes, isNotNull);
      // v2 起 read 返回裸字节：调用方除了交给 openBundle 之外做不了别的，
      // "未验签的 envelope"这个危险中间态在类型上不存在。
      expect(bytes, fixture.packed);
      expect(envelopeDigest(readWire(bytes!).envelopeBytes), expectedDigest);
    });

    test('packed 内容寻址与验签证据不符 → 拒（fail-closed）', () async {
      final other = await makeBundle({
        'manifest.json': manifestJson(adapterId: 'school-other'),
      });
      expect(other.digest, isNot(expectedDigest), reason: '前提：两份内容不同');
      expect(() => cache.write(verified, other.packed),
          throwsA(isA<BundleFormatException>()));
      expect(await cache.has(expectedDigest), isFalse);
    });

    test('packed 的随存签名与验签证据不同 digest → 拒', () async {
      // envelope 字节对得上（故内容寻址自洽），但签名声明的 digest 被改坏——
      // 若不拒，缓存里就会躺着「验过内容 A + 无关签名」的组合，读回重验必然失败。
      final badSig = Map<String, dynamic>.from(fixture.signature)
        ..['digest'] = 'b' * 64;
      final packed = packWire(fixture.envelopeBytes, badSig, fixture.blobs);
      expect(() => cache.write(verified, packed),
          throwsA(isA<BundleFormatException>()));
      expect(await cache.has(expectedDigest), isFalse);
    });

    test('packed 是畸形 gzip → BundleFormatException', () async {
      expect(() => cache.write(verified, Uint8List.fromList([1, 2, 3])),
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
    test('封套含多余字段 → null（read 也走严格封套解析）', () async {
      final loose = packWire(
        fixture.envelopeBytes,
        fixture.signature,
        fixture.blobs,
        extraWireFields: const {'extra': 1},
      );
      await store.write('bundles/$expectedDigest.bundle', loose);
      expect(await cache.read(expectedDigest), isNull);
    });
    test('存在但内容寻址不符（存到错的 key 名下）→ null', () async {
      // 把合法 packed 存到"另一个 digest"名下：read 重算 digest != key → 丢弃。
      const wrongKey =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      await store.write('bundles/$wrongKey.bundle', fixture.packed);
      expect(await cache.read(wrongKey), isNull);
    });
  });

  group('解压护栏（评审 #5，readWire 边界）', () {
    test('解压体超上限 → 拒（压缩炸弹护栏）', () {
      // 极高压缩比：小 gz，解压后 > kMaxBundlePayloadBytes。
      final bomb = Uint8List.fromList(
          gzip.encode(utf8.encode('a' * (kMaxBundlePayloadBytes + 1024))));
      expect(bomb.length, lessThan(4096), reason: '构造的 gz 应很小（高压缩比）');
      expect(() => readWire(bomb), throwsA(isA<BundleFormatException>()));
    });
    test('压缩输入超上限 → 拒（不进解压）', () {
      final big = Uint8List(kMaxBundleGzBytes + 1);
      expect(() => readWire(big), throwsA(isA<BundleFormatException>()));
    });
  });

  group('has / evict', () {
    test('write→has=true；evict→has=false', () async {
      await cache.write(verified, fixture.packed);
      expect(await cache.has(expectedDigest), isTrue);
      await cache.evict(expectedDigest);
      expect(await cache.has(expectedDigest), isFalse);
    });
    test('evict 畸形 digest → no-op（不抛）', () async {
      await cache.evict('bad');
    });
  });
}
