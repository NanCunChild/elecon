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
  group('SDK 2 explicit credential addresses', () {
    ScriptCredentials sdk2(String script, {String school = 'a'}) =>
        ScriptCredentials(
          store: store,
          schoolId: school,
          scriptId: script,
          sdkVersion: 2,
          now: () => 100,
        );

    test(
      'same key across scripts and schools stays distinct; list round-trips',
      () {
        final first = sdk2('school.first');
        final second = sdk2('school.second');
        final otherSchool = sdk2('school.first', school: 'b');
        first.set('session', 'FIRST');
        second.set('session', 'SECOND');
        otherSchool.set('session', 'OTHER_SCHOOL');
        expect(first.get('session')!['value'], 'FIRST');
        expect(second.get('session')!['value'], 'SECOND');
        expect(otherSchool.get('session')!['value'], 'OTHER_SCHOOL');
        final records = first.list();
        expect(records, hasLength(2));
        expect(records.map((r) => r['id']).toSet(), hasLength(2));
        for (final record in records) {
          expect(
            first.get(
              record['key'] as String,
              namespace: record['namespace'] as String,
            ),
            record,
          );
        }
        expect(
          first.get('session', namespace: 'school.second')!['value'],
          'SECOND',
        );
      },
    );

    test(
      'explicit sharing does not overwrite either script default namespace',
      () {
        final first = sdk2('school.first');
        final second = sdk2('school.second');
        first.set('session', 'FIRST');
        second.set('session', 'SECOND');
        first.set('session', 'SHARED', namespace: 'campus.session');
        expect(
          second.get('session', namespace: 'campus.session')!['value'],
          'SHARED',
        );
        second.delete('session', namespace: 'campus.session');
        expect(first.get('session', namespace: 'campus.session'), isNull);
        expect(first.get('session')!['value'], 'FIRST');
        expect(second.get('session')!['value'], 'SECOND');
      },
    );

    test(
      'legacy and SDK1 records require explicit addresses; SDK1 keeps defaults',
      () {
        store.put(entry('a', 'session', 'LEGACY'));
        store.put(entry('a', 'script:a:session', 'PREVIEW'));
        final modern = sdk2('school.first');
        expect(modern.get('session'), isNull);
        expect(modern.get('session', namespace: '@legacy')!['value'], 'LEGACY');
        expect(
          modern.get('session', namespace: '@preview1')!['value'],
          'PREVIEW',
        );
        expect(credentials.get('session')!['value'], 'PREVIEW');
        expect(credentials.list(), hasLength(1));
        final records = modern.list();
        expect(records.map((r) => r['namespace']).toSet(), {
          '@legacy',
          '@preview1',
        });
        for (final record in records) {
          expect(
            modern.get(
              record['key'] as String,
              namespace: record['namespace'] as String,
            ),
            record,
          );
        }
        modern.set('session', 'MODERN');
        expect(modern.list(), hasLength(3));
        expect(credentials.get('session')!['value'], 'PREVIEW');
        expect(
          store.list().singleWhere((e) => e.ref == 'session').value,
          'LEGACY',
        );
      },
    );

    test(
      'legacy descriptor ids include the school even with identical raw refs',
      () {
        store.put(entry('a', 'session', 'A'));
        final aId = sdk2(
          'school.first',
        ).get('session', namespace: '@legacy')!['id'];
        store.put(entry('b', 'session', 'B'));
        final bId = sdk2(
          'school.first',
          school: 'b',
        ).get('session', namespace: '@legacy')!['id'];
        expect(aId, 'legacy:a:session');
        expect(bId, 'legacy:b:session');
        expect(aId, isNot(bId));
      },
    );

    test(
      'omitted metadata is retained while explicit empty/null clears fields',
      () {
        final modern = sdk2('school.first');
        modern.set(
          'session',
          'OLD',
          type: 'cookie',
          expiresAt: 50,
          scope: ['https://school.example/'],
        );
        modern.set('session', 'ROTATED');
        var record = modern.get('session')!;
        expect(record['type'], 'cookie');
        expect(record['scope'], ['https://school.example/']);
        expect(record['expiresAt'], 50);
        expect(record['expired'], true);
        modern.set('session', 'NEW', expiresAt: null, scope: []);
        record = modern.get('session')!;
        expect(record['type'], 'cookie');
        expect(record['scope'], isEmpty);
        expect(record['expiresAt'], isNull);
        expect(record['expired'], false);
      },
    );

    test(
      'foreign physical slots and malformed descriptors cannot be overwritten',
      () {
        final modern = sdk2('school.first');
        store.put(entry('b', 'script2:a:school.first:session', 'FOREIGN'));
        expect(
          () => modern.set('session', 'OVERWRITE'),
          throwsA(
            isA<ScriptCredentialException>().having(
              (e) => e.code,
              'code',
              'credential_descriptor_conflict',
            ),
          ),
        );
        expect(store.list().single.value, 'FOREIGN');
        store.put(entry('b', 'legacy-session', 'FOREIGN_LEGACY'));
        expect(
          () => modern.set('legacy-session', 'OVERWRITE', namespace: '@legacy'),
          throwsA(isA<ScriptCredentialException>()),
        );
        store.put(entry('a', 'script2:b:school.first:broken', 'MALFORMED'));
        expect(() => modern.list(), throwsA(isA<ScriptCredentialException>()));
      },
    );

    test('namespace/key separators and missing SDK2 identity are rejected', () {
      final modern = sdk2('school.first');
      expect(
        () => modern.set('a:b', 'X'),
        throwsA(isA<ScriptCredentialException>()),
      );
      expect(
        () => modern.set('session', 'X', namespace: 'other:scope'),
        throwsA(isA<ScriptCredentialException>()),
      );
      expect(
        () => ScriptCredentials(store: store, schoolId: 'a', sdkVersion: 2),
        throwsA(isA<ScriptCredentialException>()),
      );
    });
  });
}
