/// AEAD 抽象 + AES-256-GCM 实现（ADR-012 §2.8 S 软件档的对称加密原语）。
///
/// 绝不自造原语——底层用 `cryptography` 的 AES-256-GCM（§2.7 决策 D「用平台/审计过的库」）。
///
/// 🔒 红线 #1 承重路径。AI 起草、经人工 + 安全清单审阅接受（2026-07-09）；**后续改动**
/// 仍须人工 + 安全清单审，不得 AI 独自闭环（AGENTS.md §1）。
/// NIST KAT 向量 / 完备篡改负例覆盖作为后续测试增强（testing.md）。
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 认证加密封装。[seal] 产出自包含密文（nonce‖ciphertext‖mac），可直接落盘；
/// [open] 校验完整性后还原明文——篡改 / 错 key → 抛异常（GCM 认证失败）。
abstract interface class Aead {
  Future<Uint8List> seal(List<int> plaintext);
  Future<Uint8List> open(List<int> sealed);
}

class Aes256GcmAead implements Aead {
  Aes256GcmAead(List<int> keyBytes)
      : assert(keyBytes.length == 32, 'DEK 须为 256 位（32 字节）'),
        _key = SecretKey(List<int>.unmodifiable(keyBytes));

  static final AesGcm _algorithm = AesGcm.with256bits();
  static const int _nonceLength = 12;
  static const int _macLength = 16;

  final SecretKey _key;

  @override
  Future<Uint8List> seal(List<int> plaintext) async {
    // nonce 由算法每次随机生成（GCM 绝不可复用 nonce；库负责随机）。
    final box = await _algorithm.encrypt(plaintext, secretKey: _key);
    return Uint8List.fromList(box.concatenation());
  }

  @override
  Future<Uint8List> open(List<int> sealed) async {
    final box = SecretBox.fromConcatenation(
      sealed,
      nonceLength: _nonceLength,
      macLength: _macLength,
    );
    final clear = await _algorithm.decrypt(box, secretKey: _key);
    return Uint8List.fromList(clear);
  }
}
