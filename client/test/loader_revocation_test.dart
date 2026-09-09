/// 🔒 revocation 验签 + 判定测试 —— [verifyRevocationWith] fail-closed 各步 + 结构校验 +
/// isRevoked/pickNewer/freshness 纯逻辑。手法同 loader_catalog_test（测试密钥经 resolver 注入）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:elecon/core/loader/revocation.dart';
import 'package:elecon/core/loader/trust_anchors.dart';
import 'package:elecon/core/loader/signature.dart';
import 'package:flutter_test/flutter_test.dart';

const _testKeyId = 'test-revocation-key';
const _digestA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _digestB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

typedef AnchorResolverFn = TrustAnchor? Function(String keyId);

Map<String, dynamic> _entry({
  String adapterId = 'school-xidian',
  String? digest = _digestA,
  Map<String, dynamic>? versionRange,
  String reason = '安全问题',
}) =>
    {
      'adapterId': adapterId,
      'digest': ?digest,
      'versionRange': ?versionRange,
      'reason': reason,
    };

Map<String, dynamic> _list({
  int sequence = 5,
  String issuedAt = '2026-07-17T00:00:00Z',
  int ttlSeconds = 3600,
  Map<String, String> minVersions = const {},
  bool killSwitch = false,
  List<Map<String, dynamic>>? entries,
}) =>
    {
      'sequence': sequence,
      'issuedAt': issuedAt,
      'ttlSeconds': ttlSeconds,
      'minVersions': minVersions,
      'killSwitch': killSwitch,
      'entries': entries ?? const [],
    };

String _hex(List<int> b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
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

  Future<SignedRevocationList> sign(String listJson,
      {String keyId = _testKeyId, String algorithm = 'ed25519'}) async {
    final sig = await Ed25519()
        // 域分隔（ADR-002 §2.3）：签 `elecon.revocation/1 ‖ 0x00 ‖ listJson 字节`。
        .sign(withContext(kContextTagRevocation, utf8.encode(listJson)),
            keyPair: keyPair);
    return SignedRevocationList(
      listJson: listJson,
      signature: base64.encode(sig.bytes),
      keyId: keyId,
      algorithm: algorithm,
    );
  }

  AnchorResolverFn resolver() => (keyId) => keyId == _testKeyId
      ? TrustAnchor(
          keyId: keyId, publicKeyHex: pubHex, active: true, note: '测试锚')
      : null;

  Future<VerifiedRevocationList> verified(Map<String, dynamic> list) async {
    final r = await verifyRevocationWith(await sign(jsonEncode(list)), resolver());
    expect(r.ok, isTrue, reason: r.reason);
    return r.value!;
  }

  Future<void> reject(Map<String, dynamic> list, {String? contains}) async {
    final r = await verifyRevocationWith(await sign(jsonEncode(list)), resolver());
    expect(r.ok, isFalse);
    if (contains != null) expect(r.reason, stringContainsInOrder([contains]));
  }

  group('verifyRevocation — 验签管线', () {
    test('合法 → 通过并返回已解析清单', () async {
      final v = await verified(_list(
        minVersions: {'school-xjt': '1.0.0'},
        entries: [_entry()],
      ));
      expect(v.keyId, _testKeyId);
      expect(v.list.sequence, 5);
      expect(v.list.minVersions['school-xjt'], '1.0.0');
      expect(v.list.entries.single.digest, _digestA);
    });

    test('listJson 被篡改 → 拒', () async {
      final signed = await sign(jsonEncode(_list()));
      final tampered = SignedRevocationList(
        listJson: signed.listJson.replaceFirst('"sequence":5', '"sequence":6'),
        signature: signed.signature,
        keyId: signed.keyId,
        algorithm: signed.algorithm,
      );
      expect((await verifyRevocationWith(tampered, resolver())).ok, isFalse);
    });

    test('非 ed25519 → 拒', () async {
      final r = await verifyRevocationWith(
          await sign(jsonEncode(_list()), algorithm: 'rsa'), resolver());
      expect(r.ok, isFalse);
      expect(r.reason, stringContainsInOrder(['算法']));
    });

    test('keyId 不命中锚 → 拒', () async {
      final r = await verifyRevocationWith(
          await sign(jsonEncode(_list()), keyId: 'nope'), resolver());
      expect(r.ok, isFalse);
      expect(r.reason, stringContainsInOrder(['信任锚']));
    });

    test('签名非 64B → 拒', () async {
      final s = await sign(jsonEncode(_list()));
      final bad = SignedRevocationList(
          listJson: s.listJson,
          signature: base64.encode(Uint8List(32)),
          keyId: s.keyId,
          algorithm: s.algorithm);
      expect((await verifyRevocationWith(bad, resolver())).ok, isFalse);
    });
  });

  group('结构校验', () {
    test('未知字段 → 拒', () => reject(_list()..['rogue'] = 1, contains: '未知字段'));
    test('sequence 负 → 拒', () => reject(_list(sequence: -1), contains: 'sequence'));
    test('issuedAt 非法日历日 → 拒', () =>
        reject(_list(issuedAt: '2026-02-30T00:00:00Z'), contains: 'issuedAt'));
    test('killSwitch 非布尔 → 拒', () async {
      final l = _list()..['killSwitch'] = 'yes';
      await reject(l, contains: 'killSwitch');
    });
    test('minVersions 值非 semver → 拒', () =>
        reject(_list(minVersions: {'school-x': '1.0'}), contains: 'minVersions'));
    test('minVersions 键非 school-* → 拒', () =>
        reject(_list(minVersions: {'evil': '1.0.0'}), contains: 'minVersions'));
    test('entry 无 digest 且无 versionRange → 拒', () =>
        reject(_list(entries: [_entry(digest: null)]), contains: 'digest 或 versionRange'));
    test('entry digest 非法 → 拒', () =>
        reject(_list(entries: [_entry(digest: 'A' * 64)]), contains: 'digest'));
    test('entry reason 空 → 拒', () =>
        reject(_list(entries: [_entry(reason: '')]), contains: 'reason'));
    test('versionRange 两端皆空 → 拒', () => reject(
        _list(entries: [_entry(digest: null, versionRange: {})]),
        contains: 'versionRange'));
    test('versionRange 未知字段 → 拒', () => reject(
        _list(entries: [
          _entry(digest: null, versionRange: {'minInclusive': '1.0.0', 'x': 1})
        ]),
        contains: '未知字段'));
    test('versionRange 边界非 semver → 拒', () => reject(
        _list(entries: [_entry(digest: null, versionRange: {'minInclusive': '1.0'})]),
        contains: 'minInclusive'));
    test('versionRange 反向区间（下界>上界）→ 拒（评审 #3）', () => reject(
        _list(entries: [
          _entry(digest: null, versionRange: {'minInclusive': '2.0.0', 'maxInclusive': '1.0.0'})
        ]),
        contains: '下界大于上界'));
    test('versionRange 下界==上界（单点区间）→ 接受', () async {
      final v = await verified(_list(entries: [
        _entry(digest: null, versionRange: {'minInclusive': '1.2.0', 'maxInclusive': '1.2.0'})
      ]));
      expect(v.list.entries.single.versionRange!.minInclusive, '1.2.0');
    });
  });

  group('compareSemver — 无界数值（评审 #2）', () {
    test('超大版本号不溢出为 0', () {
      const huge = '99999999999999999999'; // 远超 2^63
      expect(compareSemver('$huge.0.0', '1.0.0'), 1);
      expect(compareSemver('1.0.0', '$huge.0.0'), -1);
      expect(compareSemver('$huge.0.0', '$huge.0.0'), 0);
    });
    test('前导零不影响数值序', () {
      expect(compareSemver('1.02.0', '1.2.0'), 0);
      expect(compareSemver('1.10.0', '1.2.0'), 1); // 非字典序
    });
    test('超大 minVersion 仍拦住旧版本（不因溢出误放行）', () async {
      const huge = '99999999999999999999';
      final v = await verified(_list(minVersions: {'school-xidian': '$huge.0.0'}));
      final d = isRevoked(
        v,
        const AdapterRef(adapterId: 'school-xidian', adapterVersion: '1.0.0', digest: 'x'),
      );
      expect(d.allowed, isFalse);
      expect(d.reason, stringContainsInOrder(['低于最低要求']));
    });
  });

  group('规模上限', () {
    test('listJson 超码元上限 → 验签前拒', () async {
      final huge = SignedRevocationList(
        listJson: 'x' * (kMaxRevocationJsonChars + 1),
        signature: base64.encode(Uint8List(64)),
        keyId: _testKeyId,
        algorithm: 'ed25519',
      );
      final r = await verifyRevocationWith(huge, resolver());
      expect(r.ok, isFalse);
      expect(r.reason, stringContainsInOrder(['过大']));
    });
    test('entries 超上限 → 拒', () async {
      final many = List.generate(
          kMaxRevocationEntries + 1, (i) => _entry(adapterId: 'school-$i'));
      await reject(_list(entries: many), contains: 'entries 过多');
    });
  });

  group('isRevoked — 判定逻辑', () {
    AdapterRef ref({String id = 'school-xidian', String v = '1.2.0', String d = _digestB}) =>
        AdapterRef(adapterId: id, adapterVersion: v, digest: d);

    test('kill-switch → 全拒', () async {
      final v = await verified(_list(killSwitch: true));
      expect(isRevoked(v, ref()).allowed, isFalse);
    });

    test('低于 minVersion → 拒', () async {
      final v = await verified(_list(minVersions: {'school-xidian': '2.0.0'}));
      final d = isRevoked(v, ref(v: '1.9.9'));
      expect(d.allowed, isFalse);
      expect(d.reason, stringContainsInOrder(['最低要求']));
    });
    test('满足 minVersion → 放行', () async {
      final v = await verified(_list(minVersions: {'school-xidian': '2.0.0'}));
      expect(isRevoked(v, ref(v: '2.0.0')).allowed, isTrue);
    });
    test('minVersion 针对本 adapter 但版本非 x.y.z → fail-closed 拒', () async {
      final v = await verified(_list(minVersions: {'school-xidian': '2.0.0'}));
      final d = isRevoked(v, ref(v: '1.2'));
      expect(d.allowed, isFalse);
      expect(d.reason, stringContainsInOrder(['非 x.y.z']));
    });

    test('digest 精确命中 → 拒', () async {
      final v = await verified(_list(entries: [_entry(digest: _digestB)]));
      expect(isRevoked(v, ref(d: _digestB)).allowed, isFalse);
    });
    test('digest 不同 → 放行', () async {
      final v = await verified(_list(entries: [_entry(digest: _digestA)]));
      expect(isRevoked(v, ref(d: _digestB)).allowed, isTrue);
    });

    test('落在 versionRange → 拒', () async {
      final v = await verified(_list(entries: [
        _entry(digest: null, versionRange: {'minInclusive': '1.0.0', 'maxInclusive': '1.5.0'})
      ]));
      expect(isRevoked(v, ref(v: '1.2.0')).allowed, isFalse);
    });
    test('区间外 → 放行', () async {
      final v = await verified(_list(entries: [
        _entry(digest: null, versionRange: {'minInclusive': '1.0.0', 'maxInclusive': '1.5.0'})
      ]));
      expect(isRevoked(v, ref(v: '2.0.0')).allowed, isTrue);
    });
    test('versionRange 针对本 adapter 但版本非 x.y.z → fail-closed 拒', () async {
      final v = await verified(_list(entries: [
        _entry(digest: null, versionRange: {'maxInclusive': '1.5.0'})
      ]));
      final d = isRevoked(v, ref(v: 'weird'));
      expect(d.allowed, isFalse);
    });

    test('无规则命中 → 放行', () async {
      final v = await verified(_list(entries: [_entry(adapterId: 'school-other')]));
      expect(isRevoked(v, ref()).allowed, isTrue);
    });
  });

  group('pickNewerRevocation / revocationFresh', () {
    final issued = DateTime.parse('2026-07-17T00:00:00Z').millisecondsSinceEpoch;

    test('取更大 sequence；拒同/回滚', () async {
      final a = await verified(_list(sequence: 4));
      final b = await verified(_list(sequence: 5));
      expect(pickNewerRevocation(a, b).list.sequence, 5);
      expect(identical(pickNewerRevocation(b, a), b), isTrue);
      final c = await verified(_list(sequence: 5));
      expect(identical(pickNewerRevocation(b, c), b), isTrue); // 同序号保留 current
    });

    test('TTL 内新鲜 / 超期不新鲜 / 未来超偏差不新鲜', () async {
      final v = await verified(_list(ttlSeconds: 3600));
      expect(revocationFresh(v, nowMs: issued + 1000), isTrue);
      expect(revocationFresh(v, nowMs: issued + 3600 * 1000 + 1), isFalse);
      final future = await verified(_list(issuedAt: '2026-07-17T01:00:00Z'));
      expect(revocationFresh(future, nowMs: issued), isFalse);
    });
  });

  group('SignedRevocationList.fromJson', () {
    test('完整 → 解析', () {
      final s = SignedRevocationList.fromJson({
        'listJson': '{}',
        'signature': 'AAAA',
        'keyId': 'k',
        'algorithm': 'ed25519',
      });
      expect(s.keyId, 'k');
    });
    test('缺字段 → 抛', () {
      expect(() => SignedRevocationList.fromJson({'listJson': '{}'}),
          throwsA(isA<FormatException>()));
    });
  });
}
