/// §2.8 三档存储接线测试：ensurePersistentStore 裁定 + bootstrap 续用 S 档。
///
/// 用注入的 InMemoryBlobStore 脱离 path_provider，验证 confirm=true→S 档持久化、
/// confirm=false→M 内存档不落盘、以及 bootstrap 静默续用已持久化的 S 档。
library;

import 'dart:typed_data';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/hardware_keystore.dart';
import 'package:elecon/core/credential/hardware_secure_store.dart';
import 'package:elecon/core/credential/software_secure_store.dart';
import 'package:elecon/core/credential/types.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../credential/hardware_secure_store_test.dart'
    show FakeHardwareKeyStore;
import '../support/school_fixture.dart';

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

Future<void> _seedSoftware(
  InMemoryBlobStore blobs,
  CredentialEntry entry,
) async {
  final secure = await SoftwareSecureStore.open(blobs);
  secure.put(entry);
  await secure.flush();
}

Future<void> _seedHardware(
  InMemoryBlobStore blobs,
  HardwareKeyStore hardware,
  CredentialEntry entry,
) async {
  final secure = await HardwareSecureStore.open(hardware, blobs);
  secure.put(entry);
  await secure.flush();
}

void main() {
  test('confirm=true → S 软件档，持久化跨"重启"', () async {
    final blobs = InMemoryBlobStore();

    final c1 = SessionController(blobStoreProvider: () async => blobs);
    await c1.ensurePersistentStore(confirmSoftwareFallback: () async => true);
    await _seedSoftware(blobs, _entry('ehall-session'));
    await c1.flush();

    // 新控制器 bootstrap：静默续用已持久化的 S 档。
    final c2 = SessionController(
      blobStoreProvider: () async => blobs,
      initialSchools: [testSchool()],
    );
    await c2.bootstrap();
    expect(c2.isLoggedIn, isTrue);
    expect(c2.credentialRefs, ['ehall-session']);
    expect(c2.credentialProtection, SessionCredentialProtection.software);
    final metadata = c2.credentialMetadata.single;
    expect(metadata.ref, 'ehall-session');
    expect(metadata.status, SessionCredentialStatus.active);
    expect(metadata.sensitivity, SessionCredentialSensitivity.standard);
    expect(metadata.protection, SessionCredentialProtection.software);
  });

  test('bootstrap 同时恢复已选学校与已持久化凭证状态', () async {
    final blobs = InMemoryBlobStore();

    final c1 = SessionController(blobStoreProvider: () async => blobs);
    await c1.ensurePersistentStore(confirmSoftwareFallback: () async => true);
    c1.selectSchool(testSchool());
    await _seedSoftware(blobs, _entry('ehall-session'));
    await c1.flush();

    final c2 = SessionController(
      blobStoreProvider: () async => blobs,
      initialSchools: [testSchool()],
    );
    await c2.bootstrap();
    expect(c2.selectedSchool?.id, testSchool().id);
    expect(c2.isConfigured, isTrue);
    expect(c2.isLoggedIn, isTrue);
    expect(c2.credentialRefs, ['ehall-session']);
  });

  test('confirm=false → M 内存档，不落盘', () async {
    final blobs = InMemoryBlobStore();

    final c1 = SessionController(blobStoreProvider: () async => blobs);
    await c1.ensurePersistentStore(confirmSoftwareFallback: () async => false);
    await c1.flush();
    expect(await SoftwareSecureStore.hasPersisted(blobs), isFalse);
    expect(c1.credentialMetadata, isEmpty);
    expect(c1.credentialProtection, isNull);

    // 重启：未落盘 → 不续用。
    final c2 = SessionController(blobStoreProvider: () async => blobs);
    await c2.bootstrap();
    expect(c2.isLoggedIn, isFalse);
  });

  test('无 blobStoreProvider → 保持内存档，ensure 不抛错', () async {
    final c = SessionController();
    await c.bootstrap();
    await c.ensurePersistentStore(confirmSoftwareFallback: () async => true);
    expect(c.isLoggedIn, isFalse);
    expect(c.credentialMetadata, isEmpty);
    expect(c.credentialProtection, isNull);
  });

  test('H 可用 → ensurePersistentStore 走硬件档，bootstrap 静默续用', () async {
    final blobs = InMemoryBlobStore();
    final hw = FakeHardwareKeyStore();

    final c1 = SessionController(
      hardware: hw,
      blobStoreProvider: () async => blobs,
    );
    await c1.ensurePersistentStore(
      confirmSoftwareFallback: () =>
          Future<bool>.error(TestFailure('H 可用时不应询问 S 档')),
    );
    await _seedHardware(blobs, hw, _entry('ehall-session'));
    await c1.flush();

    final c2 = SessionController(
      hardware: hw,
      blobStoreProvider: () async => blobs,
    );
    await c2.bootstrap();
    expect(c2.isLoggedIn, isTrue);
    expect(c2.credentialRefs, ['ehall-session']);
    final e2 = c2.credentialMetadata.singleWhere(
      (e) => e.ref == 'ehall-session',
    );
    expect(e2.status, SessionCredentialStatus.active);
    expect(e2.sensitivity, SessionCredentialSensitivity.standard);
    expect(e2.protection, SessionCredentialProtection.hardware);
    expect(c2.credentialProtection, SessionCredentialProtection.hardware);
  });

  test('H unwrap 失败 → wipe + hardwareUnlockFailed + 保留选校', () async {
    final blobs = InMemoryBlobStore();
    final good = FakeHardwareKeyStore();
    final c1 = SessionController(
      hardware: good,
      blobStoreProvider: () async => blobs,
    );
    await c1.ensurePersistentStore(
      confirmSoftwareFallback: () => Future<bool>.error(TestFailure('no S')),
    );
    c1.selectSchool(testSchool());
    await _seedHardware(blobs, good, _entry('ehall-session'));
    await c1.flush();

    final c2 = SessionController(
      hardware: _BrokenHardwareKeyStore(),
      blobStoreProvider: () async => blobs,
      initialSchools: [testSchool()],
    );
    await c2.bootstrap();
    expect(c2.hardwareUnlockFailed, isTrue);
    expect(c2.isLoggedIn, isFalse);
    expect(c2.selectedSchool?.id, testSchool().id);
    expect(await HardwareSecureStore.hasPersisted(blobs), isFalse);

    c2.acknowledgeHardwareUnlockFailure();
    expect(c2.hardwareUnlockFailed, isFalse);
  });

  test('旧 H blob 遇平台降级为不可用 → wipe 后要求重新登录', () async {
    final blobs = InMemoryBlobStore();
    final good = FakeHardwareKeyStore();
    final c1 = SessionController(
      hardware: good,
      blobStoreProvider: () async => blobs,
    );
    await c1.ensurePersistentStore(
      confirmSoftwareFallback: () => Future<bool>.error(TestFailure('no S')),
    );
    await _seedHardware(blobs, good, _entry('ehall-session'));
    await c1.flush();

    final c2 = SessionController(
      // 默认 UnavailableHardwareKeyStore
      blobStoreProvider: () async => blobs,
    );
    await c2.bootstrap();
    expect(c2.hardwareUnlockFailed, isTrue);
    expect(c2.isLoggedIn, isFalse);
    expect(await HardwareSecureStore.hasPersisted(blobs), isFalse);
  });

  test('logout 仅抹除当前学校凭证，不波及他校（schoolId 过滤）', () async {
    final blobs = InMemoryBlobStore();
    final setup = SessionController(blobStoreProvider: () async => blobs);
    await setup.ensurePersistentStore(
      confirmSoftwareFallback: () async => true,
    );
    setup.selectSchool(testSchool());
    await setup.flush();
    final secure = await SoftwareSecureStore.open(blobs);
    secure.put(_entry('ehall-session'));
    secure.put(_entry('other-session', schoolId: 'other-school'));
    await secure.flush();

    final c = SessionController(
      blobStoreProvider: () async => blobs,
      initialSchools: [testSchool()],
    );
    await c.bootstrap();

    c.logout();
    await c.flush();

    final reopened = await SoftwareSecureStore.open(blobs);
    final remaining = reopened.list();
    expect(remaining.map((e) => e.ref), [
      'other-session',
    ], reason: '登出 = 抹除当前学校全部凭证（ADR-012 §2.5），他校凭证保留');
    expect(remaining.every((e) => e.schoolId != testSchool().id), isTrue);
  });

  test('logout 未选校时防御性抹除全部；reset 一律抹除全部', () async {
    final blobs1 = InMemoryBlobStore();
    await _seedSoftware(blobs1, _entry('a'));
    final secure1 = await SoftwareSecureStore.open(blobs1);
    secure1.put(_entry('b', schoolId: 'other-school'));
    await secure1.flush();
    final c1 = SessionController(blobStoreProvider: () async => blobs1);
    await c1.bootstrap();
    c1.logout(); // 未选校：无归属口径，宁可多删（隐私优先）
    await c1.flush();
    expect((await SoftwareSecureStore.open(blobs1)).list(), isEmpty);

    final blobs2 = InMemoryBlobStore();
    final setup = SessionController(blobStoreProvider: () async => blobs2);
    await setup.ensurePersistentStore(
      confirmSoftwareFallback: () async => true,
    );
    setup.selectSchool(testSchool());
    await setup.flush();
    final secure2 = await SoftwareSecureStore.open(blobs2);
    secure2.put(_entry('a'));
    secure2.put(_entry('b', schoolId: 'other-school'));
    await secure2.flush();
    final c2 = SessionController(
      blobStoreProvider: () async => blobs2,
      initialSchools: [testSchool()],
    );
    await c2.bootstrap();
    c2.reset(); // 彻底重置跨校抹除
    await c2.flush();
    expect((await SoftwareSecureStore.open(blobs2)).list(), isEmpty);
    expect(c2.isConfigured, isFalse);
  });
}

/// unwrap 恒失败（模拟 TEE 轮换 / 损坏）。
class _BrokenHardwareKeyStore implements HardwareKeyStore {
  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<Uint8List> wrapDek(List<int> dek) async =>
      Uint8List.fromList(List<int>.from(dek));

  @override
  Future<Uint8List> unwrapDek(List<int> wrapped) async =>
      throw StateError('broken-tee');
}
