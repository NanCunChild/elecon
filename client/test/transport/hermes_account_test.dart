import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/software_secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/transport/app_tunnel.dart';
import 'package:elecon/core/transport/hermes/hermes.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/profile_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/school_fixture.dart';
import 'hermes_configuration_test.dart' show syntheticSession;

class FakeHermes extends HermesNativeBinding {
  final calls = <Map<String, Object?>>[];
  Completer<Map<String, dynamic>>? pending;
  int cancelled = 0;
  Map<String, dynamic>? checkResult;
  Object? checkError;
  @override
  bool get isAvailable => true;
  @override
  HermesNativeRequest request(Map<String, Object?> values) {
    calls.add(Map.of(values));
    return HermesNativeRequest(
      pending?.future ??
          (values['op'] == 'checkSession'
              ? checkError == null
                    ? Future.value(checkResult ?? {'status': 'unknown'})
                    : Future.error(checkError!)
              : Future.value({'session': syntheticSession()})),
      () async {
        cancelled++;
        return {};
      },
    );
  }
}

class FailingBlobs extends InMemoryBlobStore {
  bool fail = false;
  Completer<void>? hold;
  Completer<void>? entered;
  @override
  Future<void> write(String name, List<int> bytes) async {
    if (name == 'store.enc') {
      entered?.complete();
      entered = null;
      final wait = hold;
      hold = null;
      if (wait != null) await wait.future;
      if (fail) throw StateError('synthetic storage failure');
    }
    return super.write(name, bytes);
  }
}

Future<void> save(
  SessionController session, {
  String password = 'SYNTHETIC_PASSWORD',
  String username = 'synthetic-user',
}) => session.saveHermesAccount(
  gatewayUrl: 'https://gateway.example.invalid',
  username: username,
  password: password,
);

Matcher code(String expected) =>
    isA<AppTunnelException>().having((error) => error.code, 'code', expected);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'tunnel status needs online proof, strips private fields and keeps network failures unknown',
    () async {
      final native = FakeHermes();
      final session = SessionController(hermesBinding: native);
      addTearDown(session.dispose);
      session.selectSchool(testSchool());
      expect(await session.checkHermesAccount(), {'status': 'signedOut'});
      expect(native.calls, isEmpty);
      await save(session);
      expect(await session.checkHermesAccount(), {'status': 'signedOut'});
      await session.loginHermesAccount();
      native.checkResult = {
        'status': 'authenticated',
        'accountLabel': 'Synthetic',
        'session': syntheticSession(),
        'password': 'SECRET',
      };
      final state = await session.checkHermesAccount();
      expect(state['status'], 'authenticated');
      expect(state['accountLabel'], 'Synthetic');
      expect(state.containsKey('session'), isFalse);
      expect(state.containsKey('password'), isFalse);
      expect(native.calls.last['op'], 'checkSession');
      expect(native.calls.last.containsKey('password'), isFalse);
      native.checkResult = {'status': 'expired'};
      expect((await session.checkHermesAccount())['status'], 'expired');
      native.checkError = const AppTunnelException('hermes_connection_failed');
      expect(await session.checkHermesAccount(), {'status': 'unknown'});
      expect(session.hermesConfigurationInfo(), isNotNull);
    },
  );

  test('a late account check cannot publish after switching school', () async {
    final native = FakeHermes();
    final session = SessionController(hermesBinding: native);
    addTearDown(session.dispose);
    session.selectSchool(testSchool());
    await save(session);
    await session.loginHermesAccount();
    native.pending = Completer();
    final check = session.checkHermesAccount();
    final failure = expectLater(check, throwsA(isA<Exception>()));
    session.selectSchool(testSchool(schoolId: 'other-school'));
    native.pending!.complete({
      'status': 'authenticated',
      'accountLabel': 'Previous',
    });
    await failure;
    expect(native.cancelled, 1);
  });

  test(
    'manual cancellation rejects late status rotation without changing school',
    () async {
      final native = FakeHermes();
      final session = SessionController(hermesBinding: native);
      addTearDown(session.dispose);
      session.selectSchool(testSchool());
      await save(session);
      await session.loginHermesAccount();
      native.pending = Completer();
      final failure = expectLater(
        session.checkHermesAccount(),
        throwsA(isA<Exception>()),
      );
      session.cancelHermesAccountLogin();
      native.pending!.complete({
        'status': 'authenticated',
        'session': {...syntheticSession(), 'sid': 'SYNTHETIC_LATE_SID'},
      });
      await failure;
      native.pending = null;
      native.checkResult = {'status': 'unknown'};
      await session.checkHermesAccount();
      expect(
        (native.calls.last['session'] as Map)['sid'],
        'SYNTHETIC_PRIVATE_SID',
      );
      expect(native.cancelled, 1);
    },
  );

  test(
    'online status rotates protected cookies for the next call and restart',
    () async {
      final blobs = InMemoryBlobStore();
      final native = FakeHermes();
      final session = SessionController(
        blobStoreProvider: () async => blobs,
        hermesBinding: native,
      )..scriptStorageConsent = () async => true;
      addTearDown(session.dispose);
      session.selectSchool(testSchool());
      await save(session);
      await session.loginHermesAccount();
      final rotated = {
        ...syntheticSession(),
        'sid': 'SYNTHETIC_ROTATED_SID',
        'cookies': [
          {'name': 'sid', 'value': 'SYNTHETIC_ROTATED_SID'},
        ],
      };
      native.checkResult = {
        'status': 'authenticated',
        'accountLabel': 'Synthetic',
        'session': rotated,
      };
      final result = await session.checkHermesAccount();
      expect(result['status'], 'authenticated');
      expect(result.containsKey('session'), isFalse);
      native.checkResult = {'status': 'unknown'};
      await session.checkHermesAccount();
      expect(
        (native.calls.last['session'] as Map)['sid'],
        'SYNTHETIC_ROTATED_SID',
      );
      final restored = HermesConfigStore(
        CredentialStore(store: await SoftwareSecureStore.open(blobs)),
      ).load(testSchool().id)!;
      expect(
        (restored.nativeCheck()['session'] as Map)['sid'],
        'SYNTHETIC_ROTATED_SID',
      );
      expect(
        utf8.decode((await blobs.read('store.enc'))!, allowMalformed: true),
        isNot(contains('SYNTHETIC_ROTATED_SID')),
      );
    },
  );

  test(
    'failed rotation persistence or identity mismatch retains previous material',
    () async {
      final blobs = FailingBlobs();
      final native = FakeHermes();
      final session = SessionController(
        blobStoreProvider: () async => blobs,
        hermesBinding: native,
      )..scriptStorageConsent = () async => true;
      addTearDown(session.dispose);
      session.selectSchool(testSchool());
      await save(session);
      await session.loginHermesAccount();
      native.checkResult = {
        'status': 'authenticated',
        'session': {...syntheticSession(), 'sid': 'SYNTHETIC_NEW_SID'},
      };
      blobs.fail = true;
      expect(await session.checkHermesAccount(), {'status': 'unknown'});
      blobs.fail = false;
      native.checkResult = {
        'status': 'authenticated',
        'session': {...syntheticSession(), 'username': 'different-identity'},
      };
      expect(await session.checkHermesAccount(), {'status': 'unknown'});
      native.checkResult = {'status': 'unknown'};
      await session.checkHermesAccount();
      expect(
        (native.calls.last['session'] as Map)['sid'],
        'SYNTHETIC_PRIVATE_SID',
      );
    },
  );

  test(
    'the same school has independent tunnel accounts in local Profiles after restart',
    () async {
      final blobs = InMemoryBlobStore();
      ProfileController profiles() => ProfileController(
        blobStoreProvider: () async => blobs,
        createSession: (storage) => SessionController(
          blobStoreProvider: () async => storage,
          initialSchools: [testSchool()],
        )..scriptStorageConsent = () async => true,
      );
      final controller = profiles();
      await controller.bootstrap();
      controller.active.session.selectSchool(testSchool());
      await save(controller.active.session, username: 'synthetic-alpha');
      await controller.add();
      final beta = controller.active.id;
      controller.active.session.selectSchool(testSchool());
      expect(controller.active.session.hermesAccountInfo(), isNull);
      await save(controller.active.session, username: 'synthetic-beta');
      await controller.activate('default');
      expect(
        controller.active.session.hermesAccountInfo()!.username,
        'synthetic-alpha',
      );
      controller.dispose();
      final restored = profiles();
      addTearDown(restored.dispose);
      await restored.bootstrap();
      expect(
        restored.active.session.hermesAccountInfo()!.username,
        'synthetic-alpha',
      );
      await restored.activate(beta);
      expect(
        restored.active.session.hermesAccountInfo()!.username,
        'synthetic-beta',
      );
    },
  );

  test(
    'account is encrypted, school scoped, script inaccessible and survives restart',
    () async {
      final blobs = InMemoryBlobStore();
      final backend = await SoftwareSecureStore.open(blobs);
      final credentials = CredentialStore(store: backend);
      final store = HermesAccountStore(credentials);
      store.save(
        'school-a',
        HermesAccount(
          gatewayUrl: 'https://gateway.example.invalid',
          username: 'synthetic-user',
          password: 'SYNTHETIC_PASSWORD',
        ),
      );
      expect(store.load('school-b'), isNull);
      expect(
        ScriptCredentials(
          store: credentials,
          schoolId: 'school-a',
          scriptId: 'synthetic',
          sdkVersion: 11,
        ).list(),
        isEmpty,
      );
      expect(
        store.load('school-a').toString(),
        isNot(contains('SYNTHETIC_PASSWORD')),
      );
      await backend.flush();
      final ciphertext = utf8.decode(
        (await blobs.read('store.enc'))!,
        allowMalformed: true,
      );
      expect(ciphertext, isNot(contains('SYNTHETIC_PASSWORD')));
      expect(ciphertext, isNot(contains('synthetic-user')));
      final restored = HermesAccountStore(
        CredentialStore(store: await SoftwareSecureStore.open(blobs)),
      ).load('school-a')!;
      expect(restored.info.username, 'synthetic-user');
      expect(restored.nativeAuthenticate()['password'], 'SYNTHETIC_PASSWORD');
    },
  );

  test(
    'blank password preserves only the same account and save is not login',
    () async {
      final native = FakeHermes();
      final session = SessionController(hermesBinding: native);
      addTearDown(session.dispose);
      session.selectSchool(testSchool());
      await expectLater(
        save(session, password: ''),
        throwsA(code('hermes_password_required')),
      );
      await save(session);
      expect(session.hermesAccountInfo()!.username, 'synthetic-user');
      expect(session.hermesConfigurationInfo(), isNull);
      expect(session.isLoggedIn, isFalse);
      expect(session.credentialMetadata, isEmpty);
      await save(session, password: '');
      await expectLater(
        save(session, password: '', username: 'other-user'),
        throwsA(code('hermes_password_required')),
      );
      expect(native.calls, isEmpty);
      await session.loginHermesAccount();
      expect(native.calls, hasLength(1));
      expect(native.calls.single['op'], 'authenticatePassword');
      expect(native.calls.single['password'], 'SYNTHETIC_PASSWORD');
      expect(session.hermesConfigurationInfo(), isNotNull);
      expect(session.isLoggedIn, isFalse);
      await save(session, password: 'replacement');
      expect(session.hermesConfigurationInfo(), isNull);
      await session.clearHermesConfiguration();
      expect(session.hermesAccountInfo(), isNull);
    },
  );

  for (final cancel in ['cancel', 'school', 'logout']) {
    test(
      '$cancel rejects a late successful authentication without retry',
      () async {
        final native = FakeHermes()..pending = Completer();
        final session = SessionController(hermesBinding: native);
        addTearDown(session.dispose);
        session.selectSchool(testSchool());
        await save(session);
        final login = session.loginHermesAccount();
        final failure = expectLater(login, throwsA(code('hermes_cancelled')));
        if (cancel == 'cancel') session.cancelHermesAccountLogin();
        if (cancel == 'school') {
          session.selectSchool(testSchool(schoolId: 'other-school'));
        }
        if (cancel == 'logout') session.logout();
        native.pending!.complete({'session': syntheticSession()});
        await failure;
        expect(native.cancelled, 1);
        expect(native.calls, hasLength(1));
        expect(session.hermesConfigurationInfo(), isNull);
      },
    );
  }

  test(
    'failed durable account edit restores previous credentials and session',
    () async {
      final blobs = FailingBlobs();
      final native = FakeHermes();
      final session = SessionController(
        blobStoreProvider: () async => blobs,
        hermesBinding: native,
      )..scriptStorageConsent = () async => true;
      addTearDown(session.dispose);
      session.selectSchool(testSchool());
      await save(session);
      await session.loginHermesAccount();
      blobs.fail = true;
      await expectLater(
        save(session, username: 'new-user'),
        throwsA(code('hermes_persist_failed')),
      );
      expect(session.hermesAccountInfo()!.username, 'synthetic-user');
      expect(session.hermesConfigurationInfo(), isNotNull);
      blobs.fail = false;
      final restored = HermesAccountStore(
        CredentialStore(store: await SoftwareSecureStore.open(blobs)),
      );
      expect(restored.load(testSchool().id)!.info.username, 'synthetic-user');
    },
  );

  test(
    'cancelling during durable session flush prevents session publication',
    () async {
      final blobs = FailingBlobs();
      final native = FakeHermes();
      final session = SessionController(
        blobStoreProvider: () async => blobs,
        hermesBinding: native,
      )..scriptStorageConsent = () async => true;
      addTearDown(session.dispose);
      session.selectSchool(testSchool());
      await save(session);
      final entered = Completer<void>();
      final hold = Completer<void>();
      blobs.entered = entered;
      blobs.hold = hold;
      final failure = expectLater(
        session.loginHermesAccount(),
        throwsA(code('hermes_cancelled')),
      );
      await entered.future;
      expect(session.hermesConfigurationInfo, throwsA(code('app_tunnel_busy')));
      expect(session.hermesAccountInfo, throwsA(code('app_tunnel_busy')));
      await expectLater(
        session.appTunnelProviders.single.open(schoolId: testSchool().id),
        throwsA(code('app_tunnel_busy')),
      );
      expect(native.calls, hasLength(1));
      session.cancelHermesAccountLogin();
      hold.complete();
      await failure;
      expect(session.hermesConfigurationInfo(), isNull);
      final restored = HermesConfigStore(
        CredentialStore(store: await SoftwareSecureStore.open(blobs)),
      );
      expect(restored.load(testSchool().id), isNull);
    },
  );
}
