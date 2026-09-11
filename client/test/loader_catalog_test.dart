/// 🔒 catalog 验签测试 —— [verifyCatalogWith] fail-closed 各步 + 结构/语义校验 + 防回滚/TTL。
///
/// 生产 [verifyCatalog] 只认预埋 const 锚集，故用**测试**密钥经 [verifyCatalogWith] 注入
/// 只认该 keyId 的 resolver，跑**同一条生产管线**。防回滚/TTL 原语只收不可伪造的
/// [VerifiedCatalog]，故其测试也经验签取得实例（无法直接构造）。
///
/// 说明：catalog 签名是字节精确（Ed25519 over `utf8(catalogJson)`）。本测试用 Dart 端生成的
/// 真实向量覆盖管线正反例；**Node×Dart 逐字节 golden**（含中文/emoji/转义/换行）作后续增强，
/// 以证 Node `Buffer.from(...,"utf8")` 与 Dart `utf8.encode` 的真实互操作。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:elecon/core/loader/catalog.dart';
import 'package:elecon/core/loader/trust_anchors.dart';
import 'package:elecon_contract/capability_registry.dart' show kCapabilityIds;
import 'package:elecon/core/loader/signature.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

const _testKeyId = 'test-catalog-key';

typedef AnchorResolverFn = TrustAnchor? Function(String keyId);

Map<String, dynamic> _entry({
  String adapterId = 'school-xidian',
  String adapterVersion = '1.2.0',
  String digest = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  String? url,
  String? stdlibMin,
  List<String> capabilities = const ['notice.list'],
}) =>
    {
      'adapterId': adapterId,
      'adapterVersion': adapterVersion,
      'digest': digest,
      // url 已弃用（ADR-018 §2.5.1）；仅历史 catalog 携带，默认不写。
      'url': ?url,
      'stdlibMin': ?stdlibMin,
      'capabilities': capabilities,
    };

Map<String, dynamic> _payload({
  int sequence = 7,
  String issuedAt = '2026-07-17T00:00:00Z',
  int ttlSeconds = 3600,
  List<Map<String, dynamic>>? entries,
}) =>
    {
      'catalogVersion': '1.0',
      'sequence': sequence,
      'issuedAt': issuedAt,
      'ttlSeconds': ttlSeconds,
      'entries': entries ?? [_entry()],
    };

String _hex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

void main() {
  late SimpleKeyPair keyPair;
  late String pubHex;

  setUpAll(() async {
    keyPair = await Ed25519().newKeyPair();
    pubHex = _hex((await keyPair.extractPublicKey()).bytes);
  });

  Future<SignedCatalog> sign(
    String catalogJson, {
    String keyId = _testKeyId,
    String algorithm = 'ed25519',
  }) async {
    final sig = await Ed25519()
        // 域分隔（ADR-002 §2.3）：签 `elecon.catalog/1 ‖ 0x00 ‖ catalogJson 字节`。
        .sign(withContext(kContextTagCatalog, utf8.encode(catalogJson)),
            keyPair: keyPair);
    return SignedCatalog(
      catalogJson: catalogJson,
      signature: base64.encode(sig.bytes),
      keyId: keyId,
      algorithm: algorithm,
    );
  }

  AnchorResolverFn resolver() => (keyId) => keyId == _testKeyId
      ? TrustAnchor(
          keyId: keyId,
          publicKeyHex: pubHex,
          active: true,
          note: 'catalog 测试锚（仅测试）',
        )
      : null;

  /// 签 payload 并验签，断言通过，返回 VerifiedCatalog。
  Future<VerifiedCatalog> verified(Map<String, dynamic> payload) async {
    final r = await verifyCatalogWith(await sign(jsonEncode(payload)), resolver());
    expect(r.ok, isTrue, reason: r.reason);
    return r.value!;
  }

  /// 签 payload 并验签，断言被拒（可选 reason 子串）。
  Future<void> reject(Map<String, dynamic> payload, {String? contains}) async {
    final r = await verifyCatalogWith(await sign(jsonEncode(payload)), resolver());
    expect(r.ok, isFalse);
    if (contains != null) expect(r.reason, stringContainsInOrder([contains]));
  }

  group('verifyCatalog — 验签管线', () {
    test('合法 → 通过并返回已解析 catalog', () async {
      final c = (await verified(_payload(entries: [
        _entry(),
        _entry(adapterId: 'school-xjt', adapterVersion: '0.9.1', stdlibMin: '1.0.0', digest: 'b' * 64, url: 'https://cdn.example/b/${'b' * 64}.json.gz', capabilities: ['notice.list', 'grades.list']),
      ]))).catalog;
      expect(c.sequence, 7);
      expect(c.entries, hasLength(2));
      expect(c.entries[0].stdlibMin, isNull);
      expect(c.entries[1].stdlibMin, '1.0.0');
      expect(c.entries[1].capabilities, ['notice.list', 'grades.list']);
    });

    test('VerifiedCatalog 记录命中的 keyId', () async {
      final v = await verified(_payload());
      expect(v.keyId, _testKeyId);
    });

    test('catalogJson 被篡改一字节 → 拒', () async {
      final signed = await sign(jsonEncode(_payload()));
      final tampered = SignedCatalog(
        catalogJson: signed.catalogJson.replaceFirst('"sequence":7', '"sequence":8'),
        signature: signed.signature,
        keyId: signed.keyId,
        algorithm: signed.algorithm,
      );
      expect((await verifyCatalogWith(tampered, resolver())).ok, isFalse);
    });

    test('非 ed25519 算法 → 拒（不降级）', () async {
      final r = await verifyCatalogWith(
          await sign(jsonEncode(_payload()), algorithm: 'rsa'), resolver());
      expect(r.ok, isFalse);
      expect(r.reason, stringContainsInOrder(['算法']));
    });

    test('keyId 不命中预埋 active 锚 → 拒', () async {
      final r = await verifyCatalogWith(
          await sign(jsonEncode(_payload()), keyId: 'unknown-key'), resolver());
      expect(r.ok, isFalse);
      expect(r.reason, stringContainsInOrder(['信任锚']));
    });

    test('签名非合法 base64 → 拒', () async {
      final signed = await sign(jsonEncode(_payload()));
      final bad = SignedCatalog(
          catalogJson: signed.catalogJson,
          signature: '!!!not-base64!!!',
          keyId: signed.keyId,
          algorithm: signed.algorithm);
      expect((await verifyCatalogWith(bad, resolver())).ok, isFalse);
    });

    test('签名非裸 64 字节 → 拒', () async {
      final signed = await sign(jsonEncode(_payload()));
      final bad = SignedCatalog(
          catalogJson: signed.catalogJson,
          signature: base64.encode(Uint8List(32)),
          keyId: signed.keyId,
          algorithm: signed.algorithm);
      expect((await verifyCatalogWith(bad, resolver())).ok, isFalse);
    });

    test('签名有效但内容非 JSON → 验签过、解析拒', () async {
      final r = await verifyCatalogWith(await sign('这不是 JSON{'), resolver());
      expect(r.ok, isFalse);
      expect(r.reason, stringContainsInOrder(['解析']));
    });
  });

  group('结构/语义校验（验签过后仍须 fail-closed）', () {
    test('缺必填字段 sequence → 拒', () =>
        reject(_payload()..remove('sequence'), contains: 'sequence'));

    test('catalog 未知字段 → 拒（additionalProperties=false）', () =>
        reject(_payload()..['extra'] = 1, contains: '未知字段'));

    test('entry 未知字段 → 拒', () =>
        reject(_payload(entries: [_entry()..['rogue'] = true]), contains: '未知字段'));

    test('catalogVersion 非 x.y → 拒', () async {
      final p = _payload()..['catalogVersion'] = '1';
      await reject(p, contains: 'catalogVersion');
    });

    test('adapterId 非 school-* → 拒', () =>
        reject(_payload(entries: [_entry(adapterId: 'evil-corp')]), contains: 'adapterId'));

    test('adapterVersion 空串 → 拒（但非 x.y.z 的字符串版本被接受，与 contract 一致）', () async {
      await reject(_payload(entries: [_entry(adapterVersion: '')]),
          contains: 'adapterVersion');
      // contract 只声明 adapterVersion:type=string，客户端不加 x.y.z，故 '1.2' 应通过。
      final v = await verified(_payload(entries: [_entry(adapterVersion: '1.2')]));
      expect(v.catalog.entries.first.adapterVersion, '1.2');
    });

    test('digest 非 64 位小写 hex → 拒（大写）', () =>
        reject(_payload(entries: [_entry(digest: 'A' * 64)]), contains: 'digest'));

    test('digest 长度不足 → 拒', () =>
        reject(_payload(entries: [_entry(digest: 'a' * 63)]), contains: 'digest'));

    test('历史 catalog 的已弃用 url 被整段忽略（sequence ≤ 8 兼容，ADR-018 §2.5.1）', () async {
      // 任何取值（含此前会被拒的 http / userinfo）都不影响解析——它已不参与任何决策。
      for (final u in const [
        'https://cdn.example/bundles/x.json.gz',
        'http://cdn.example/x.json.gz',
        'https://u:p@cdn.example/x.json.gz',
        'not a url',
      ]) {
        final v = await verified(_payload(entries: [_entry(url: u)]));
        expect(v.catalog.entries.single.digest, 'a' * 64, reason: 'url=$u 应被忽略');
      }
    });

    test('stdlibMin 非 semver → 拒', () =>
        reject(_payload(entries: [_entry(stdlibMin: '1.0')]), contains: 'stdlibMin'));

    test('capabilities 空数组 → 拒', () =>
        reject(_payload(entries: [_entry(capabilities: [])]), contains: 'capabilities'));

    test('capabilities 含空串 → 拒', () =>
        reject(_payload(entries: [_entry(capabilities: [''])]), contains: 'capabilities'));

    test('capabilities 含 registry 之外的未知能力 → 拒', () => reject(
        _payload(entries: [_entry(capabilities: ['unknown.capability'])]),
        contains: '未知能力'));

    test('重复 adapterId → 拒（客户端 fail-closed）', () => reject(
        _payload(entries: [_entry(), _entry(digest: 'c' * 64)]),
        contains: '重复'));

    test('issuedAt 非 RFC3339 → 拒', () =>
        reject(_payload(issuedAt: 'not-a-date'), contains: 'issuedAt'));

    test('issuedAt 月/日超数字范围 → 正则阶段拒', () =>
        reject(_payload(issuedAt: '2026-13-40T00:00:00Z'), contains: 'issuedAt'));

    test('issuedAt 2 月 31 日 → 日历校验拒', () =>
        reject(_payload(issuedAt: '2026-02-31T00:00:00Z'), contains: 'issuedAt'));

    test('issuedAt 2 月 30 日 → 日历校验拒', () =>
        reject(_payload(issuedAt: '2026-02-30T00:00:00Z'), contains: 'issuedAt'));

    test('issuedAt 非闰年 2 月 29 日 → 拒', () =>
        reject(_payload(issuedAt: '2026-02-29T00:00:00Z'), contains: 'issuedAt'));

    test('issuedAt 4 月 31 日 → 日历校验拒', () =>
        reject(_payload(issuedAt: '2026-04-31T00:00:00Z'), contains: 'issuedAt'));

    test('issuedAt 闰年 2 月 29 日 → 通过', () async {
      final v = await verified(_payload(issuedAt: '2024-02-29T00:00:00Z'));
      expect(v.catalog.issuedAt, '2024-02-29T00:00:00Z');
    });
  });

  group('capability 集合 × registry 单源', () {
    // kCapabilityIds 由 contract codegen 从 registry.json 产出（CI 漂移闸门保证同步）；此断言是
    // Dart 侧的额外交叉核对——即便有人手改生成物也会红。
    test('kCapabilityIds 与 registry.json 完全一致', () {
      final reg = readJson(repoPath('contract/capability/registry.json'));
      final ids = (reg['capabilities'] as Map<String, dynamic>).keys.toSet();
      expect(kCapabilityIds, equals(ids),
          reason: '生成的能力集须与 contract/capability/registry.json 同步（红线 #6）');
    });
  });

  group('规模上限（DoS 护栏）', () {
    test('catalogJson 超码元上限 → 验签前即拒', () async {
      final huge = SignedCatalog(
        catalogJson: 'x' * (kMaxCatalogJsonChars + 1),
        signature: base64.encode(Uint8List(64)),
        keyId: _testKeyId,
        algorithm: 'ed25519',
      );
      final r = await verifyCatalogWith(huge, resolver());
      expect(r.ok, isFalse);
      expect(r.reason, stringContainsInOrder(['过大']));
    });

    test('entries 超上限 → 拒', () async {
      // entry 已无 url，总码元数不触碰 catalogJson 上限——隔离出 entries 计数上限这一步。
      final many = List.generate(
        kMaxCatalogEntries + 1,
        (i) => _entry(adapterId: 'school-$i'),
      );
      await reject(_payload(entries: many), contains: 'entries 过多');
    });

    test('单 entry capabilities 超上限 → 拒', () => reject(
        _payload(entries: [
          _entry(capabilities: List.filled(kMaxCapabilitiesPerEntry + 1, 'notice.list')),
        ]),
        contains: 'capabilities 过多'));

    test('adapterId 超长 → 拒', () => reject(
        _payload(entries: [_entry(adapterId: 'school-${'a' * kMaxAdapterIdChars}')]),
        contains: 'adapterId'));
  });

  group('SignedCatalog.fromJson — 传输封套', () {
    test('完整字段 → 解析', () {
      final s = SignedCatalog.fromJson({
        'catalogJson': '{}',
        'signature': 'AAAA',
        'keyId': 'k',
        'algorithm': 'ed25519',
      });
      expect(s.keyId, 'k');
    });
    test('缺字段 → 抛', () {
      expect(() => SignedCatalog.fromJson({'catalogJson': '{}'}),
          throwsA(isA<FormatException>()));
    });
    test('字段空串 → 抛', () {
      expect(
          () => SignedCatalog.fromJson({
                'catalogJson': '{}',
                'signature': '',
                'keyId': 'k',
                'algorithm': 'ed25519',
              }),
          throwsA(isA<FormatException>()));
    });
  });

  group('pickNewerCatalog — 防回滚', () {
    test('incoming 更大 → 取 incoming', () async {
      final a = await verified(_payload(sequence: 3));
      final b = await verified(_payload(sequence: 4));
      expect(pickNewerCatalog(a, b).catalog.sequence, 4);
    });
    test('相等 → 保留 current（拒同序号替换）', () async {
      final a = await verified(_payload(sequence: 4));
      final b = await verified(_payload(sequence: 4));
      expect(identical(pickNewerCatalog(a, b), a), isTrue);
    });
    test('incoming 更小 → 保留 current（拒回滚）', () async {
      final a = await verified(_payload(sequence: 5));
      final b = await verified(_payload(sequence: 2));
      expect(pickNewerCatalog(a, b).catalog.sequence, 5);
    });
  });

  group('catalogFresh — TTL + 未来时间上限', () {
    final issued = DateTime.parse('2026-07-17T00:00:00Z').millisecondsSinceEpoch;

    test('TTL 内 → 新鲜', () async {
      final v = await verified(_payload(ttlSeconds: 3600));
      expect(catalogFresh(v, nowMs: issued + 1000), isTrue);
    });
    test('恰在 TTL 边界 → 新鲜', () async {
      final v = await verified(_payload(ttlSeconds: 3600));
      expect(catalogFresh(v, nowMs: issued + 3600 * 1000), isTrue);
    });
    test('超过 TTL → 不新鲜', () async {
      final v = await verified(_payload(ttlSeconds: 3600));
      expect(catalogFresh(v, nowMs: issued + 3600 * 1000 + 1), isFalse);
    });
    test('issuedAt 超前 now 超过偏差上限 → 不新鲜', () async {
      // issuedAt 设为一小时后；now 在其之前很久。
      final v = await verified(_payload(issuedAt: '2026-07-17T01:00:00Z'));
      expect(catalogFresh(v, nowMs: issued), isFalse);
    });
    test('issuedAt 轻微超前（偏差内）→ 仍判新鲜', () async {
      final v = await verified(_payload(issuedAt: '2026-07-17T00:01:00Z', ttlSeconds: 3600));
      // now 比 issuedAt 早 60s，< 5min 偏差上限。
      expect(catalogFresh(v, nowMs: issued), isTrue);
    });
  });
}
