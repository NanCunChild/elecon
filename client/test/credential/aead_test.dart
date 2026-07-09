/// AES-256-GCM AEAD 功能测试（ADR-012 §2.8）。
///
/// 🔒 这是**功能**测试，非安全充分性证明。安全关键覆盖——NIST KAT 向量、
/// 完备篡改/负例、nonce 唯一性、边界——须人工编写或实质审阅（红线 #1 / testing.md）。
library;

import 'dart:typed_data';

import 'package:elecon/core/credential/aead.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
  final otherKey = Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));

  test('seal → open 往返还原明文', () async {
    final aead = Aes256GcmAead(key);
    final plaintext = Uint8List.fromList('ehall-session=abc123; path=/'.codeUnits);
    final sealed = await aead.seal(plaintext);

    expect(sealed, isNot(equals(plaintext)), reason: '密文不应等于明文');
    final opened = await aead.open(sealed);
    expect(opened, equals(plaintext));
  });

  test('同一明文两次 seal 得到不同密文（nonce 随机）', () async {
    final aead = Aes256GcmAead(key);
    final p = Uint8List.fromList([1, 2, 3, 4]);
    final a = await aead.seal(p);
    final b = await aead.seal(p);
    expect(a, isNot(equals(b)), reason: 'GCM nonce 每次随机，密文应不同');
  });

  test('篡改密文 → open 抛错（GCM 认证失败）', () async {
    final aead = Aes256GcmAead(key);
    final sealed = await aead.seal(Uint8List.fromList([9, 9, 9, 9]));
    final tampered = Uint8List.fromList(sealed);
    tampered[tampered.length - 1] ^= 0x01; // 翻转 mac 尾字节
    await expectLater(aead.open(tampered), throwsA(anything));
  });

  test('错 key → open 抛错', () async {
    final sealed = await Aes256GcmAead(key).seal(Uint8List.fromList([5, 6, 7]));
    await expectLater(Aes256GcmAead(otherKey).open(sealed), throwsA(anything));
  });

  test('非 256 位 key → 断言失败（debug）', () {
    expect(() => Aes256GcmAead(Uint8List(16)), throwsA(isA<AssertionError>()));
  });
}
