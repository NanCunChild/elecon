/// §2.8 三档存储接线测试：ensurePersistentStore 裁定 + bootstrap 续用 S 档。
///
/// 用注入的 InMemoryBlobStore 脱离 path_provider，验证 confirm=true→S 档持久化、
/// confirm=false→M 内存档不落盘、以及 bootstrap 静默续用已持久化的 S 档。
library;

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/types.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

CredentialEntry _entry(String ref) => CredentialEntry(
      ref: ref,
      schoolId: 'xidian',
      type: 'cookie',
      scope: const ['https://ehall.xidian.edu.cn/*'],
      value: 'secret-$ref',
      acquiredAt: 1000,
      expiresAt: null,
      status: CredentialStatus.active,
    );

void main() {
  test('confirm=true → S 软件档，持久化跨"重启"', () async {
    final blobs = InMemoryBlobStore();

    final c1 = SessionController(blobStoreProvider: () async => blobs);
    await c1.ensurePersistentStore(confirmSoftwareFallback: () async => true);
    c1.store.put(_entry('ehall-session'));
    await c1.flush();

    // 新控制器 bootstrap：静默续用已持久化的 S 档。
    final c2 = SessionController(blobStoreProvider: () async => blobs);
    await c2.bootstrap();
    expect(c2.isLoggedIn, isTrue);
    expect(c2.credentialRefs, ['ehall-session']);
  });

  test('confirm=false → M 内存档，不落盘', () async {
    final blobs = InMemoryBlobStore();

    final c1 = SessionController(blobStoreProvider: () async => blobs);
    await c1.ensurePersistentStore(confirmSoftwareFallback: () async => false);
    c1.store.put(_entry('s'));
    await c1.flush();
    expect(c1.isLoggedIn, isTrue); // 本进程内有效

    // 重启：未落盘 → 不续用。
    final c2 = SessionController(blobStoreProvider: () async => blobs);
    await c2.bootstrap();
    expect(c2.isLoggedIn, isFalse);
  });

  test('无 blobStoreProvider → 保持内存档，ensure 不抛错', () async {
    final c = SessionController();
    await c.bootstrap();
    await c.ensurePersistentStore(confirmSoftwareFallback: () async => true);
    c.store.put(_entry('s'));
    expect(c.isLoggedIn, isTrue);
  });
}
