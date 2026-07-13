/// §2.8 三档存储接线测试：ensurePersistentStore 裁定 + bootstrap 续用 S 档。
///
/// 用注入的 InMemoryBlobStore 脱离 path_provider，验证 confirm=true→S 档持久化、
/// confirm=false→M 内存档不落盘、以及 bootstrap 静默续用已持久化的 S 档。
library;

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/types.dart';
import 'package:elecon/catalog/schools.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

CredentialEntry _entry(String ref, {String schoolId = 'xidian'}) =>
    CredentialEntry(
      ref: ref,
      schoolId: schoolId,
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

  test('bootstrap 同时恢复已选学校与已持久化凭证状态', () async {
    final blobs = InMemoryBlobStore();

    final c1 = SessionController(blobStoreProvider: () async => blobs);
    await c1.ensurePersistentStore(confirmSoftwareFallback: () async => true);
    c1.selectSchool(defaultSchool);
    c1.store.put(_entry('ehall-session'));
    await c1.flush();

    final c2 = SessionController(blobStoreProvider: () async => blobs);
    await c2.bootstrap();
    expect(c2.selectedSchool?.id, defaultSchool.id);
    expect(c2.isConfigured, isTrue);
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

  test('logout 仅抹除当前学校凭证，不波及他校（schoolId 过滤）', () async {
    final c = SessionController();
    c.selectSchool(defaultSchool); // xidian
    c.store.put(_entry('ehall-session'));
    c.store.put(_entry('other-session', schoolId: 'other-school'));

    c.logout();

    final remaining = c.store.list();
    expect(remaining.map((e) => e.ref), ['other-session'],
        reason: '登出 = 抹除当前学校全部凭证（ADR-012 §2.5），他校凭证保留');
    expect(remaining.every((e) => e.schoolId != defaultSchool.id), isTrue);
  });

  test('logout 未选校时防御性抹除全部；reset 一律抹除全部', () async {
    final c1 = SessionController();
    c1.store.put(_entry('a'));
    c1.store.put(_entry('b', schoolId: 'other-school'));
    c1.logout(); // 未选校：无归属口径，宁可多删（隐私优先）
    expect(c1.store.list(), isEmpty);

    final c2 = SessionController();
    c2.selectSchool(defaultSchool);
    c2.store.put(_entry('a'));
    c2.store.put(_entry('b', schoolId: 'other-school'));
    c2.reset(); // 彻底重置跨校抹除
    expect(c2.store.list(), isEmpty);
    expect(c2.isConfigured, isFalse);
  });
}
