/// S 软件档存储功能测试（ADR-012 §2.8）。
///
/// 用 [InMemoryBlobStore] 脱离平台插件验证：加密落盘 → 重开解密还原、
/// 登记 protection=software、DEK 落盘、删除持久化。
///
/// 🔒 功能测试，非安全充分性证明。持久化并发/写序、崩溃一致性、明文 DEK 的
/// 威胁面等安全关键测试须人工把关（红线 #1 / testing.md）。
library;

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/software_secure_store.dart';
import 'package:elecon/core/credential/types.dart';
import 'package:flutter_test/flutter_test.dart';

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
    expect(asText.contains('PLAINTEXT-NEEDLE'), isFalse,
        reason: 'value 应在密文内，不得明文出现');
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
}
