/// 🔒 revocation 跨语言 golden —— Node 签端 × Dart 加载器逐字节钉死。
///
/// 消费 `contract/golden/revocation/revocation.json`（`tools/src/signer/make-revocation-golden.ts`
/// 确定性生成）。valid case 的富文本 `reason` + 中文/emoji `adapterId` 端到端证：Node
/// `Buffer.from(...,"utf8")` == Dart `utf8.encode`，且验签→解析后逐字符保真。
library;

import 'package:elecon/core/loader/revocation.dart';
import 'package:elecon/core/loader/trust_anchors.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

Map<String, dynamic> _golden() =>
    readJson(repoPath('contract/golden/revocation/revocation.json'));

void main() {
  final golden = _golden();

  group('revocation golden — Node 签名 × Dart 验签', () {
    test('golden 自洽（cases 非空）', () {
      expect((golden['cases'] as List), isNotEmpty);
    });

    for (final c in (golden['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['name'] as String, () async {
        final signed =
            SignedRevocationList.fromJson(c['signed'] as Map<String, dynamic>);
        final keyHex = c['publicKeyRawHex'] as String;
        final r = await verifyRevocationWith(
          signed,
          (keyId) => keyId == signed.keyId
              ? TrustAnchor(
                  keyId: keyId,
                  publicKeyHex: keyHex,
                  active: true,
                  note: 'golden 测试锚（仅测试）',
                )
              : null,
        );
        final expected = c['expect'] as Map<String, dynamic>;
        if (expected['ok'] == true) {
          expect(r.ok, isTrue, reason: r.reason);
          final first = r.value!.list.entries.first;
          if (expected['entry0AdapterId'] != null) {
            expect(first.adapterId, expected['entry0AdapterId']);
          }
          if (expected['entry0Reason'] != null) {
            // 富文本 reason（含换行/转义/emoji/NFD/星平面）经 Node 签→Dart 验→解析逐字符保真。
            expect(first.reason, expected['entry0Reason']);
          }
        } else {
          expect(r.ok, isFalse);
          if (expected['reasonContains'] != null) {
            expect(r.reason,
                stringContainsInOrder([expected['reasonContains'] as String]));
          }
        }
      });
    }
  });
}
