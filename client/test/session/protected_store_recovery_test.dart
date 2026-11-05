import 'dart:async';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/hardware_keystore_channel.dart';
import 'package:elecon/core/credential/hardware_secure_store.dart';
import 'package:elecon/core/credential/software_secure_store.dart';
import 'package:elecon/session/profile_controller.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/protected_store_fixture.dart';
import '../support/school_fixture.dart';

class _KeyReadFailure implements BlobStore {
  _KeyReadFailure(this.inner);
  final BlobStore inner;
  bool fail = true;
  @override
  Future<Uint8List?> read(String name) async {
    if (fail && name == 'store.dek.wrapped') {
      throw StateError('synthetic_read_failure');
    }
    return inner.read(name);
  }

  @override
  Future<void> write(String name, List<int> bytes) => inner.write(name, bytes);
  @override
  Future<void> delete(String name) => inner.delete(name);
}

class _DelayedKeyRead extends _KeyReadFailure {
  _DelayedKeyRead(super.inner) {
    this.fail = false;
  }
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<Uint8List?> read(String name) async {
    if (name == 'store.dek.wrapped') {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return super.read(name);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'repeated failures retain bytes; explicit retry restores the original store',
    () async {
      final hardware = RecoverableHardware();
      final blobs = await seedProtectedStore(hardware);
      final wrapped = await blobs.read('store.dek.wrapped');
      final sealed = await blobs.read('store.enc');
      hardware.unavailable = true;
      final session = protectedSession(blobs, hardware);
      addTearDown(session.dispose);
      await session.bootstrap();
      expect(session.hardwareUnlockFailed, isTrue);
      expect(session.isRestored, isTrue);
      expect(session.credentialMetadata, isEmpty);
      expect(session.selectedSchool?.id, testSchool().id);
      expect(await session.retryProtectedStore(), isFalse);
      expect(await session.retryProtectedStore(), isFalse);
      final identity = session.identityRevision;
      final generation = session.trustedScriptViewGeneration;
      hardware.unavailable = false;
      expect(await session.retryProtectedStore(), isTrue);
      expect(session.hardwareUnlockFailed, isFalse);
      expect(session.identityRevision, greaterThan(identity));
      expect(session.trustedScriptViewGeneration, greaterThan(generation));
      expect(session.credentialRefs, ['synthetic-session']);
      expect(
        hardware.probes,
        0,
        reason: 'recovery never uses the first-save key probe',
      );
      expect(hardware.wraps, 1);
      await session.flush();
      expect(await blobs.read('store.dek.wrapped'), wrapped);
      expect(await blobs.read('store.enc'), sealed);
      expect(await blobs.read('store.dek'), isNull);
    },
  );

  test(
    'waiting state rejects execution, login bridges, cache and fallback',
    () async {
      final hardware = RecoverableHardware();
      final blobs = await seedProtectedStore(hardware);
      hardware.unavailable = true;
      final session = protectedSession(blobs, hardware);
      addTearDown(session.dispose);
      await session.bootstrap();
      var consent = 0;
      await expectLater(
        session.ensurePersistentStore(
          confirmSoftwareFallback: () async {
            consent++;
            return true;
          },
        ),
        throwsStateError,
      );
      expect(consent, 0);
      expect(
        (await session.runCapability('notice.list')).reason,
        'protected_store_unavailable',
      );
      expect(
        (await session.runTrustedScript('synthetic', 'notice.list')).reason,
        'protected_store_unavailable',
      );
      expect(
        (await session.runAdapterCapability(
          adapterId: 'synthetic',
          capability: 'notice.list',
        )).reason,
        'protected_store_unavailable',
      );
      await expectLater(
        session.createWebViewAuthBridge(login: testSchool().login),
        throwsStateError,
      );
      await expectLater(session.loginHermesAccount(), throwsStateError);
      await expectLater(session.clearHermesConfiguration(), throwsStateError);
      expect(session.logout, throwsStateError);
      expect(session.reset, throwsStateError);
      expect(await session.latestCachedCapability('notice.list'), isNull);
      expect(
        await session.cachedQueryForm('synthetic', 'digest', 'notice.list', {}),
        isNull,
      );
      expect(await blobs.read('store.dek'), isNull);
    },
  );

  test(
    'concurrent retries share one attempt and remain blocked until it completes',
    () async {
      final hardware = RecoverableHardware();
      final blobs = await seedProtectedStore(hardware);
      hardware.unavailable = true;
      final session = protectedSession(blobs, hardware);
      addTearDown(session.dispose);
      await session.bootstrap();
      hardware.unavailable = false;
      hardware.release = Completer<void>();
      hardware.entered = Completer<void>();
      final first = session.retryProtectedStore();
      final second = session.retryProtectedStore();
      expect(identical(first, second), isTrue);
      await hardware.entered!.future;
      expect(hardware.unwraps, 2);
      expect(session.isRetryingProtectedStore, isTrue);
      expect(session.hardwareUnlockFailed, isTrue);
      expect(
        (await session.runCapability('notice.list')).reason,
        'protected_store_unavailable',
      );
      hardware.release!.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(session.isRetryingProtectedStore, isFalse);
    },
  );

  for (final invalidation in ['school', 'dispose']) {
    test(
      'late recovery after $invalidation does not replace the session',
      () async {
        final hardware = RecoverableHardware();
        final blobs = await seedProtectedStore(hardware);
        hardware.unavailable = true;
        final session = protectedSession(blobs, hardware);
        await session.bootstrap();
        hardware.unavailable = false;
        hardware.release = Completer<void>();
        hardware.entered = Completer<void>();
        final pending = session.retryProtectedStore();
        await hardware.entered!.future;
        if (invalidation == 'dispose') {
          session.dispose();
        } else {
          session.clearSchoolSelection();
        }
        hardware.release!.complete();
        expect(await pending, isFalse);
        expect(session.hardwareUnlockFailed, isTrue);
        expect(session.credentialMetadata, isEmpty);
        if (invalidation != 'dispose') {
          expect(await session.retryProtectedStore(), isTrue);
          session.dispose();
        }
      },
    );
  }

  test(
    'Profile switch revokes a pending recovery without opening the old identity',
    () async {
      final hardware = RecoverableHardware();
      final blobs = await seedProtectedStore(hardware);
      hardware.unavailable = true;
      final profiles = ProfileController(
        blobStoreProvider: () async => blobs,
        createSession: (scope) => protectedSession(scope ?? blobs, hardware),
      );
      addTearDown(profiles.dispose);
      await profiles.bootstrap();
      final old = profiles.active.session;
      hardware.unavailable = false;
      hardware.release = Completer<void>();
      hardware.entered = Completer<void>();
      final pending = old.retryProtectedStore();
      await hardware.entered!.future;
      await profiles.add();
      hardware.release!.complete();
      expect(await pending, isFalse);
      expect(old.hardwareUnlockFailed, isTrue);
      expect(profiles.active.id, isNot('default'));
      expect(profiles.active.session.credentialMetadata, isEmpty);
    },
  );

  test(
    'bad ciphertext and missing original key material never cause replacement writes',
    () async {
      final hardware = RecoverableHardware();
      final blobs = await seedProtectedStore(hardware);
      final wrapped = await blobs.read('store.dek.wrapped');
      await blobs.write('store.enc', [1, 2, 3]);
      final session = protectedSession(blobs, hardware);
      addTearDown(session.dispose);
      await session.bootstrap();
      expect(await session.retryProtectedStore(), isFalse);
      expect(await blobs.read('store.enc'), [1, 2, 3]);
      expect(await blobs.read('store.dek.wrapped'), wrapped);
      await blobs.delete('store.dek.wrapped');
      expect(await session.retryProtectedStore(), isFalse);
      expect(await blobs.read('store.dek.wrapped'), isNull);
      expect(hardware.wraps, 1);
      expect(session.hardwareUnlockFailed, isTrue);
    },
  );

  test(
    'a missing platform channel can recover without a destructive availability probe',
    () async {
      final hardware = RecoverableHardware();
      final blobs = await seedProtectedStore(hardware);
      final sealed = await blobs.read('store.enc');
      const channel = MethodChannel('elecon/keystore');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'temporarily_unavailable'),
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final session = protectedSession(blobs, const BackedHardwareKeyStore());
      addTearDown(session.dispose);
      await session.bootstrap();
      expect(session.hardwareUnlockFailed, isTrue);
      expect(await blobs.read('store.enc'), sealed);
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'unwrapDek');
        return hardware.unwrapDek((call.arguments as List).cast<int>());
      });
      expect(await session.retryProtectedStore(), isTrue);
      expect(session.credentialRefs, ['synthetic-session']);
    },
  );

  test(
    'openExisting cannot create a store when there is no old wrapped key',
    () async {
      final hardware = RecoverableHardware();
      final blobs = await seedProtectedStore(hardware);
      final sealed = await blobs.read('store.enc');
      await blobs.delete('store.dek.wrapped');
      await expectLater(
        HardwareSecureStore.openExisting(hardware, blobs),
        throwsA(isA<HardwareUnlockException>()),
      );
      expect(hardware.wraps, 1);
      expect(await blobs.read('store.enc'), sealed);
      expect(await blobs.read('store.dek.wrapped'), isNull);
    },
  );

  test(
    'a missing ciphertext image is not restored as an empty account',
    () async {
      final hardware = RecoverableHardware();
      final blobs = await seedProtectedStore(hardware);
      final wrapped = await blobs.read('store.dek.wrapped');
      await blobs.delete('store.enc');
      final session = protectedSession(blobs, hardware);
      addTearDown(session.dispose);
      await session.bootstrap();
      expect(session.hardwareUnlockFailed, isTrue);
      expect(await session.retryProtectedStore(), isFalse);
      expect(await blobs.read('store.enc'), isNull);
      expect(await blobs.read('store.dek.wrapped'), wrapped);
      expect(hardware.wraps, 1);
    },
  );

  test(
    'a transient original-key read failure stays retryable without a fallback',
    () async {
      final hardware = RecoverableHardware();
      final backing = await seedProtectedStore(hardware);
      final sealed = await backing.read('store.enc');
      final blobs = _KeyReadFailure(backing);
      final session = protectedSession(blobs, hardware);
      addTearDown(session.dispose);
      await session.bootstrap();
      expect(session.hardwareUnlockFailed, isTrue);
      expect(session.isRestored, isTrue);
      expect(await session.retryProtectedStore(), isFalse);
      blobs.fail = false;
      expect(await session.retryProtectedStore(), isTrue);
      expect(await backing.read('store.enc'), sealed);
      expect(hardware.wraps, 1);
    },
  );

  test(
    'disposed startup cannot adopt a late successfully opened H store',
    () async {
      final hardware = RecoverableHardware();
      final blobs = await seedProtectedStore(hardware);
      hardware.release = Completer<void>();
      hardware.entered = Completer<void>();
      final session = protectedSession(blobs, hardware);
      final boot = session.bootstrap();
      await hardware.entered!.future;
      session.dispose();
      hardware.release!.complete();
      await boot;
      expect(session.hardwareUnlockFailed, isTrue);
      expect(session.credentialMetadata, isEmpty);
      expect(session.isRestored, isFalse);
    },
  );

  for (final malformedSoftwareKey in [false, true]) {
    test(
      'cold orphan ciphertext blocks bootstrap and first-save ($malformedSoftwareKey)',
      () async {
        final hardware = RecoverableHardware();
        final blobs = await seedProtectedStore(hardware);
        final sealed = await blobs.read('store.enc');
        await blobs.delete('store.dek.wrapped');
        if (malformedSoftwareKey) await blobs.write('store.dek', [1, 2, 3]);
        final cold = protectedSession(blobs, hardware);
        addTearDown(cold.dispose);
        await cold.bootstrap();
        expect(cold.isRestored, isTrue);
        expect(cold.hardwareUnlockFailed, isTrue);
        expect(await cold.retryProtectedStore(), isFalse);
        expect(cold.credentialMetadata, isEmpty);

        final firstSave = protectedSession(blobs, hardware);
        addTearDown(firstSave.dispose);
        var consent = 0;
        await expectLater(
          firstSave.ensurePersistentStore(
            confirmSoftwareFallback: () async {
              consent++;
              return false;
            },
          ),
          throwsStateError,
        );
        expect(firstSave.hardwareUnlockFailed, isTrue);
        expect(consent, 0);
        expect(hardware.probes, 0);
        expect(hardware.wraps, 1);
        expect(await blobs.read('store.enc'), sealed);
        expect(await blobs.read('store.dek.wrapped'), isNull);
        expect(
          await blobs.read('store.dek'),
          malformedSoftwareKey ? [1, 2, 3] : isNull,
        );
      },
    );
  }

  test(
    'previous S key-only selection remains compatible without probing H or asking again',
    () async {
      final blobs = InMemoryBlobStore();
      await SoftwareSecureStore.open(blobs);
      final key = await blobs.read('store.dek');
      expect(await blobs.read('store.enc'), isNull);
      final hardware = RecoverableHardware();
      final firstSave = protectedSession(blobs, hardware);
      addTearDown(firstSave.dispose);
      await firstSave.ensurePersistentStore(
        confirmSoftwareFallback: () async =>
            fail('previous S consent is retained'),
      );
      final cold = protectedSession(blobs, hardware);
      addTearDown(cold.dispose);
      await cold.bootstrap();
      expect(cold.hardwareUnlockFailed, isFalse);
      expect(cold.isRestored, isTrue);
      expect(await blobs.read('store.dek'), key);
      expect(await blobs.read('store.enc'), isNull);
      expect(hardware.probes, 0);
      expect(hardware.wraps, 0);
    },
  );

  test(
    'same-identity first-save calls share one new key and empty encrypted image',
    () async {
      final backing = InMemoryBlobStore();
      final blobs = _DelayedKeyRead(backing);
      final hardware = RecoverableHardware();
      final session = protectedSession(blobs, hardware);
      addTearDown(session.dispose);
      final first = session.ensurePersistentStore(
        confirmSoftwareFallback: () async => false,
      );
      final second = session.ensurePersistentStore(
        confirmSoftwareFallback: () async => false,
      );
      expect(identical(first, second), isTrue);
      await blobs.entered.future;
      blobs.release.complete();
      await Future.wait([first, second]);
      expect(hardware.probes, 1);
      expect(hardware.wraps, 1);
      final original = await HardwareSecureStore.openExisting(
        hardware,
        backing,
      );
      expect(original.list(), isEmpty);
      expect(await backing.read('store.enc'), isNotNull);
    },
  );

  test(
    'known S corruption stays blocked and retries only its existing S key',
    () async {
      final blobs = InMemoryBlobStore();
      final original = await SoftwareSecureStore.open(blobs);
      original.delete('synthetic-absent');
      await original.flush();
      final key = await blobs.read('store.dek');
      final sealed = await blobs.read('store.enc');
      await blobs.write('store.enc', [1, 2, 3]);
      final hardware = RecoverableHardware();
      final session = protectedSession(blobs, hardware);
      addTearDown(session.dispose);
      await session.bootstrap();
      expect(session.hardwareUnlockFailed, isTrue);
      expect(await session.retryProtectedStore(), isFalse);
      expect(await blobs.read('store.enc'), [1, 2, 3]);
      await blobs.write('store.enc', sealed!);
      expect(await session.retryProtectedStore(), isTrue);
      expect(await blobs.read('store.dek'), key);
      expect(hardware.probes, 0);
      expect(hardware.wraps, 0);
      expect(hardware.unwraps, 0);
    },
  );

  test(
    'an unreadable original-key probe also blocks first-save instead of proceeding as M',
    () async {
      final hardware = RecoverableHardware();
      final backing = await seedProtectedStore(hardware);
      final blobs = _KeyReadFailure(backing);
      final session = protectedSession(blobs, hardware);
      addTearDown(session.dispose);
      await expectLater(
        session.ensurePersistentStore(
          confirmSoftwareFallback: () async =>
              fail('no fallback after an unreadable protected file'),
        ),
        throwsStateError,
      );
      expect(session.hardwareUnlockFailed, isTrue);
      expect(hardware.probes, 0);
      expect(hardware.wraps, 1);
    },
  );

  for (final stage in ['provider', 'key', 'consent', 'identity']) {
    test(
      'first-save canceled during $stage never adopts or writes a new store',
      () async {
        final backing = InMemoryBlobStore();
        final blobs = _DelayedKeyRead(backing);
        final provider = Completer<void>();
        final consent = Completer<bool>();
        final consentEntered = Completer<void>();
        final hardware = RecoverableHardware()..unavailable = true;
        final session = SessionController(
          hardware: hardware,
          blobStoreProvider: () async {
            if (stage == 'provider') await provider.future;
            return blobs;
          },
          initialSchools: [testSchool()],
        );
        addTearDown(session.dispose);
        final pending = session.ensurePersistentStore(
          confirmSoftwareFallback: () {
            if (!consentEntered.isCompleted) consentEntered.complete();
            return consent.future;
          },
        );
        if (stage != 'provider') await blobs.entered.future;
        if (stage == 'consent') {
          blobs.release.complete();
          await consentEntered.future;
        }
        final failed = expectLater(pending, throwsStateError);
        if (stage == 'identity') {
          session.onCredentialsChanged(identityChanged: true);
        } else {
          session.clearSchoolSelection();
        }
        await expectLater(
          session.ensurePersistentStore(
            confirmSoftwareFallback: () async => true,
          ),
          throwsStateError,
        );
        if (stage == 'provider') provider.complete();
        if (!blobs.release.isCompleted) blobs.release.complete();
        if (stage == 'consent') consent.complete(true);
        await failed;
        expect(hardware.probes, stage == 'consent' ? 1 : 0);
        expect(hardware.wraps, 0);
        expect(await backing.read('store.dek'), isNull);
        expect(await backing.read('store.dek.wrapped'), isNull);
        expect(await backing.read('store.enc'), isNull);
      },
    );
  }
}
