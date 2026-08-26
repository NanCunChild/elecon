/// S 软件档存储功能测试（ADR-012 §2.8）。
///
/// 用 [InMemoryBlobStore] 脱离平台插件验证：加密落盘 → 重开解密还原、
/// 登记 protection=software、DEK 落盘、删除持久化。
///
/// 功能测试。持久化并发/写序、崩溃一致性等更深覆盖作为后续测试增强（红线 #1 / testing.md）。
library;

import 'dart:typed_data';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/software_secure_store.dart';
import 'package:elecon/core/credential/types.dart';
import 'package:flutter_test/flutter_test.dart';

class _FlakyBlobStore implements BlobStore {
  final _inner = InMemoryBlobStore();
  int failedWrites = 0;

  @override
  Future<Uint8List?> read(String name) => _inner.read(name);

  @override
  Future<void> write(String name, List<int> bytes) {
    if (failedWrites > 0) {
      failedWrites--;
      return Future<void>.error(StateError('sim-write-fail'));
    }
    return _inner.write(name, bytes);
  }

  @override
  Future<void> delete(String name) => _inner.delete(name);
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
    final store = await SoftwareSecureStore.open(blobs);
    store.put(_entry('ehall-session', 'secret-abc'));
    await store.flush();

    // 用同一 blobs 重开（模拟重启）——须能解密还原。
    final reopened = await SoftwareSecureStore.open(blobs);
    final got = reopened.get('ehall-session');
    expect(got, isNotNull);
    expect(got!.value, 'secret-abc');
  });

  test('落盘的整库 blob 不含明文 value（已 AEAD 加密）', () async {
    final blobs = InMemoryBlobStore();
    final store = await SoftwareSecureStore.open(blobs);
    store.put(_entry('s', 'PLAINTEXT-NEEDLE'));
    await store.flush();

    final sealed = await blobs.read('store.enc');
    expect(sealed, isNotNull);
    final asText = String.fromCharCodes(sealed!);
    expect(
      asText.contains('PLAINTEXT-NEEDLE'),
      isFalse,
      reason: 'value 应在密文内，不得明文出现',
    );
  });

  test('登记 protection=software', () async {
    final store = await SoftwareSecureStore.open(InMemoryBlobStore());
    store.put(_entry('s', 'v'));
    expect(store.get('s')!.protection, CredentialProtection.software);
  });

  test('DEK 明文落盘（S 档，32 字节）', () async {
    final blobs = InMemoryBlobStore();
    await SoftwareSecureStore.open(blobs);
    final dek = await blobs.read('store.dek');
    expect(dek, isNotNull);
    expect(dek!.length, 32);
  });

  test('delete 持久化：重开后不存在', () async {
    final blobs = InMemoryBlobStore();
    final store = await SoftwareSecureStore.open(blobs);
    store.put(_entry('s', 'v'));
    await store.flush();
    store.delete('s');
    await store.flush();

    final reopened = await SoftwareSecureStore.open(blobs);
    expect(reopened.get('s'), isNull);
  });

  test('首写失败后后写可恢复，flush 暴露 durability failure', () async {
    final blobs = _FlakyBlobStore();
    final store = await SoftwareSecureStore.open(blobs);
    blobs.failedWrites = 1;

    store.put(_entry('first', 'v1'));
    await expectLater(store.flush(), throwsStateError);
    expect(store.durabilityError, isA<StateError>());

    store.put(_entry('second', 'v2'));
    await store.flush();
    expect(store.durabilityError, isNull);
    final reopened = await SoftwareSecureStore.open(blobs);
    expect(reopened.get('first')!.value, 'v1');
    expect(reopened.get('second')!.value, 'v2');
  });
}
