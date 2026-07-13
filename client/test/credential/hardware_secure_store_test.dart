/// H 硬件档存储功能测试（ADR-012 §2.8）。
///
/// 用内存 [HardwareKeyStore] 假体 + [InMemoryBlobStore] 验证：
/// wrap DEK 落盘、整库 AEAD、跨「重启」还原、protection=hardware。
library;

import 'dart:typed_data';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/hardware_keystore.dart';
import 'package:elecon/core/credential/hardware_secure_store.dart';
import 'package:elecon/core/credential/types.dart';
import 'package:flutter_test/flutter_test.dart';

/// 软件模拟 KEK：XOR 固定掩码（仅测试；非密码学安全）。
class FakeHardwareKeyStore implements HardwareKeyStore {
  FakeHardwareKeyStore({this.available = true});

  final bool available;
  static final _mask = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<Uint8List> wrapDek(List<int> dek) async {
    final out = Uint8List(dek.length);
    for (var i = 0; i < dek.length; i++) {
      out[i] = dek[i] ^ _mask[i % _mask.length];
    }
    return out;
  }

  @override
  Future<Uint8List> unwrapDek(List<int> wrapped) => wrapDek(wrapped);
}

CredentialEntry _entry(String ref, String value) => CredentialEntry(
      ref: ref,
      schoolId: 'xidian',
      type: 'cookie',
      scope: const ['https://ehall.xidian.edu.cn/*'],
      value: value,
      acquiredAt: 1000,
      expiresAt: null,
      status: CredentialStatus.active,
    );

void main() {
  test('put → flush → 重开解密还原 value', () async {
    final blobs = InMemoryBlobStore();
    final hw = FakeHardwareKeyStore();
    final store = await HardwareSecureStore.open(hw, blobs);
    store.put(_entry('ehall-session', 'secret-hw'));
    await store.flush();

    final reopened = await HardwareSecureStore.open(hw, blobs);
    final got = reopened.get('ehall-session');
    expect(got, isNotNull);
    expect(got!.value, 'secret-hw');
    expect(got.protection, CredentialProtection.hardware);
  });

  test('落盘密文不含明文 value；wrapped DEK 存在', () async {
    final blobs = InMemoryBlobStore();
    final store = await HardwareSecureStore.open(FakeHardwareKeyStore(), blobs);
    store.put(_entry('s', 'PLAINTEXT-NEEDLE'));
    await store.flush();

    final sealed = await blobs.read('store.enc');
    expect(sealed, isNotNull);
    expect(String.fromCharCodes(sealed!).contains('PLAINTEXT-NEEDLE'), isFalse);

    final wrapped = await blobs.read('store.dek.wrapped');
    expect(wrapped, isNotNull);
    expect(wrapped!.length, 32);

    // H 档不得落明文 DEK
    expect(await blobs.read('store.dek'), isNull);
  });

  test('hasPersisted 据 wrapped DEK', () async {
    final blobs = InMemoryBlobStore();
    expect(await HardwareSecureStore.hasPersisted(blobs), isFalse);
    await HardwareSecureStore.open(FakeHardwareKeyStore(), blobs);
    expect(await HardwareSecureStore.hasPersisted(blobs), isTrue);
  });

  test('delete 持久化：重开后不存在', () async {
    final blobs = InMemoryBlobStore();
    final hw = FakeHardwareKeyStore();
    final store = await HardwareSecureStore.open(hw, blobs);
    store.put(_entry('s', 'v'));
    await store.flush();
    store.delete('s');
    await store.flush();

    final reopened = await HardwareSecureStore.open(hw, blobs);
    expect(reopened.get('s'), isNull);
  });
}
