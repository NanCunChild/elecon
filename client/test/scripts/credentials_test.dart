import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/credential/types.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:flutter_test/flutter_test.dart';

CredentialEntry entry(String school, String ref, String value, {int? expiry}) =>
    CredentialEntry(
      ref: ref,
      schoolId: school,
      type: 'cookie',
      scope: const [],
      value: value,
      acquiredAt: 0,
      expiresAt: expiry,
      status: CredentialStatus.active,
    );
void main() {
  late CredentialStore store;
  late ScriptCredentials credentials;
  var active = true;
  setUp(() {
    active = true;
    store = CredentialStore(store: InMemorySecureStore(releaseMode: false));
    credentials = ScriptCredentials(
      store: store,
      schoolId: 'a',
      now: () => 100,
      isActive: () => active,
    );
  });
  test('current-school secrets and expired refresh state are readable', () {
    store.put(entry('a', 'session', 'SYNTHETIC_A', expiry: 50));
    store.put(entry('b', 'foreign', 'SYNTHETIC_B'));
    expect(credentials.get('session')!['value'], 'SYNTHETIC_A');
    expect(credentials.get('session')!['expired'], true);
    expect(credentials.get('foreign'), isNull);
    expect(credentials.list(), hasLength(1));
  });
  test(
    'same key across schools never overwrites or deletes another identity',
    () {
      store.put(entry('b', 'session', 'SYNTHETIC_B'));
      credentials.set('session', 'SYNTHETIC_A');
      expect(credentials.get('session')!['value'], 'SYNTHETIC_A');
      expect(
        store.list().singleWhere((e) => e.schoolId == 'b').value,
        'SYNTHETIC_B',
      );
      credentials.delete('session');
      expect(store.list().single.schoolId, 'b');
    },
  );
  test('legacy current-school credentials can be refreshed', () {
    store.put(entry('a', 'session', 'OLD'));
    credentials.set('session', 'NEW', type: 'cookie');
    expect(store.list().single.ref, 'session');
    expect(store.list().single.value, 'NEW');
  });
  test('inactive session rejects reads and writes', () {
    credentials.set('session', 'OLD');
    active = false;
    expect(
      () => credentials.get('session'),
      throwsA(isA<ScriptCredentialException>()),
    );
    expect(
      () => credentials.set('session', 'LATE'),
      throwsA(isA<ScriptCredentialException>()),
    );
    expect(
      () => credentials.delete('session'),
      throwsA(isA<ScriptCredentialException>()),
    );
    expect(store.list().single.value, 'OLD');
  });
  test('metadata copied; invalid keys and oversize values rejected', () {
    final scope = ['https://school.example/'];
    credentials.set('session', 'S', scope: scope);
    scope.clear();
    expect(credentials.get('session')!['scope'], ['https://school.example/']);
    expect(
      () => credentials.set('../b/session', 'X'),
      throwsA(isA<ScriptCredentialException>()),
    );
    expect(
      () => credentials.set('key', 'x' * 65537),
      throwsA(isA<ScriptCredentialException>()),
    );
  });
}
