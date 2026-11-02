/// 🔒 预置基线读取 —— asset 字节还原成 Signed*/packed；缺/损坏 → null（合法降级）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:elecon/core/loader/bootstrap.dart';
import 'package:elecon/core/loader/catalog.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAssets implements AssetSource {
  _FakeAssets(this._map);
  final Map<String, Uint8List> _map;
  @override
  Future<Uint8List?> load(String key) async => _map[key];
}

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

const _root = 'assets/bootstrap';
const _digest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  BootstrapBaseline make(Map<String, Uint8List> m) =>
      BootstrapBaseline(_FakeAssets(m));

  group('catalog / revocation', () {
    test('打包了合法 signed catalog → 解析', () async {
      final b = make({
        '$_root/catalog.json': _bytes(jsonEncode(const {
          'catalogJson': '{}',
          'signature': 'AAAA',
          'keyId': 'k',
          'algorithm': 'ed25519',
        })),
      });
      final c = await b.catalog();
      expect(c, isA<SignedCatalog>());
      expect(c!.keyId, 'k');
    });
    test('未打包 → null', () async {
      expect(await make({}).catalog(), isNull);
      expect(await make({}).revocation(), isNull);
    });
    test('损坏 JSON → null', () async {
      final b = make({'$_root/catalog.json': _bytes('{oops')});
      expect(await b.catalog(), isNull);
    });
    test('缺字段（fromJson 抛）→ null', () async {
      final b = make({'$_root/revocation.json': _bytes('{"listJson":"{}"}')});
      expect(await b.revocation(), isNull);
    });
    test('合法 signed revocation → 解析', () async {
      final b = make({
        '$_root/revocation.json': _bytes(jsonEncode(const {
          'listJson': '{}',
          'signature': 'BB',
          'keyId': 'k2',
          'algorithm': 'ed25519',
        })),
      });
      expect((await b.revocation())!.keyId, 'k2');
    });
  });

  group('bundleByDigest', () {
    test('存在 → 返回 packed 字节（原样，未验签）', () async {
      final packed = Uint8List.fromList([1, 2, 3, 4]);
      final b = make({'$_root/bundles/$_digest.bundle': packed});
      expect(await b.bundleByDigest(_digest), packed);
    });
    test('不存在 → null', () async {
      expect(await make({}).bundleByDigest(_digest), isNull);
    });
    test('畸形 digest → null（不查 asset，防路径穿越）', () async {
      final b = make({'$_root/bundles/../evil.bundle': _bytes('x')});
      expect(await b.bundleByDigest('../evil'), isNull);
      expect(await b.bundleByDigest('AABB'), isNull); // 大写/过短
    });
  });

  test('assetRoot 可覆盖', () async {
    final b = BootstrapBaseline(
      _FakeAssets({'custom/catalog.json': _bytes('{"catalogJson":"{}","signature":"s","keyId":"k","algorithm":"ed25519"}')}),
      assetRoot: 'custom',
    );
    expect((await b.catalog())!.keyId, 'k');
  });
}
