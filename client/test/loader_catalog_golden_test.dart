/// 🔒 catalog 跨语言 golden —— Node 签端 × Dart 加载器逐字节钉死。
///
/// 消费 `contract/golden/catalog/catalog.json`（由 `tools/src/catalog/make-catalog-golden.ts`
/// 确定性生成）。两段：
///  ① byteInterop：证 Node `Buffer.from(...,"utf8")` == Dart `utf8.encode`（两端不归一化）。
///  ② cases：Node `signCatalog` 真实签名经 Dart `verifyCatalogWith` 验签，正反例同判。
///
/// golden 的测试公钥经 resolver 注入（生产预埋集里没有它，见 trust_anchors.dart）。
library;

import 'dart:convert';

import 'package:elecon/core/loader/catalog.dart';
import 'package:elecon/core/loader/trust_anchors.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

Map<String, dynamic> _golden() =>
    readJson(repoPath('contract/golden/catalog/catalog.json'));

void main() {
  final golden = _golden();

  group('catalog golden — UTF-8 字节互操作', () {
    final probes = (golden['byteInterop'] as List).cast<Map<String, dynamic>>();
    test('golden 自洽（探针与 case 非空）', () {
      expect(probes, isNotEmpty);
      expect((golden['cases'] as List), isNotEmpty);
    });
    for (final p in probes) {
      test('utf8 一致：${p['name']}', () {
        // Dart utf8.encode 的字节须等于 Node Buffer.from(text,"utf8")（golden 里的 utf8Base64）。
        expect(base64.encode(utf8.encode(p['text'] as String)), p['utf8Base64']);
      });
    }
  });

  group('catalog golden — Node 签名 × Dart 验签', () {
    for (final c in (golden['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['name'] as String, () async {
        final signed =
            SignedCatalog.fromJson(c['signed'] as Map<String, dynamic>);
        final keyHex = c['publicKeyRawHex'] as String;
        final r = await verifyCatalogWith(
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
          if (expected['adapterId0'] != null) {
            // 证多字节 adapterId 经 Node 签→Dart 验→解析后逐字符保真。
            expect(r.value!.catalog.entries.first.adapterId, expected['adapterId0']);
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
