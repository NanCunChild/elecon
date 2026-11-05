import 'dart:convert';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/software_secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/query_form_cache.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'query_form_runtime_test.dart' as fixtures;

const target = 'grades.list';
Map<String, dynamic> form({bool date = false}) => {
  'target': target,
  'title': 'Synthetic',
  'submitLabel': 'Search',
  'controls': [
    if (date)
      {
        'id': 'date',
        'kind': 'date',
        'label': 'Date',
        'initialValue': '2026-11-05',
      },
    {
      'id': 'term',
      'kind': 'select',
      'label': 'Term',
      'options': [
        {'value': 'term-a', 'label': 'Term A'},
      ],
    },
  ],
};
const draft = {
  'applied': <String, dynamic>{},
  'edits': {'term': 'term-a'},
  'cleared': <String>[],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'raw editor records are bounded and cannot disguise a mismatched base',
    () {
      final cache = ScriptQueryFormCache(CredentialStore());
      final package = fixtures.package();
      final complete = {
        ...draft,
        'rawEditors': {
          'seats': '-',
          'range:hours:start': '08:15',
          'range:hours:end': '',
        },
      };
      expect(cache.write(package, target, {}, complete, draft: true), isTrue);
      expect(cache.read(package, target, {}, draft: true), complete);
      for (final raw in [
        {'seats': 'x' * 65},
        {'range:hours:start': '123456'},
        {'__proto__': 'x'},
        {'range:hours:sideways': '08:00'},
        {'field': 1},
      ]) {
        expect(
          cache.write(package, target, {}, {
            ...draft,
            'rawEditors': raw,
          }, draft: true),
          isFalse,
        );
      }
      expect(
        cache.write(
          package,
          target,
          {
            'current': {'term': 'term-b'},
          },
          complete,
          draft: true,
        ),
        isFalse,
      );
    },
  );

  test(
    'metadata uses exact dependencies, version and locale, with original TTL',
    () {
      var now = 1000000;
      final store = CredentialStore();
      final cache = ScriptQueryFormCache(store, now: () => now);
      final package = fixtures.package(version: '2.1');
      final params = {
        'target': target,
        'current': {'term': 'term-a'},
        'load': ['details'],
      };
      expect(cache.write(package, target, params, form()), isTrue);
      now += ScriptQueryFormCache.freshMs - 1;
      expect(
        cache.read(package, target, {
          'load': ['details'],
          'current': {'term': 'term-a'},
          'target': target,
        }),
        isNotNull,
      );
      expect(
        cache.read(package, target, {
          ...params,
          'current': {'term': 'term-b'},
        }),
        isNull,
      );
      expect(
        ScriptQueryFormCache(
          store,
          locale: 'en',
          now: () => now,
        ).read(package, target, params),
        isNull,
      );
      expect(
        cache.read(fixtures.package(version: '2.0'), target, params),
        isNull,
      );
      now++;
      expect(
        cache.read(package, target, params),
        isNull,
        reason: 'reads must not extend source freshness',
      );
    },
  );

  test(
    'school defaults are recomputed while user dates remain exact-keyed',
    () {
      final cache = ScriptQueryFormCache(CredentialStore());
      final package = fixtures.package();
      final defaults = {'target': target, 'current': <String, dynamic>{}};
      expect(cache.write(package, target, defaults, form(date: true)), isTrue);
      expect(cache.read(package, target, defaults), isNull);
      final chosen = {
        'target': target,
        'current': {'date': '2026-11-05'},
      };
      expect(cache.write(package, target, chosen, form(date: true)), isTrue);
      expect(cache.read(package, target, chosen), isNotNull);
    },
  );

  test(
    'drafts survive protected-store reopening, remain private and clear per school',
    () async {
      final blobs = InMemoryBlobStore();
      final backend = await SoftwareSecureStore.open(blobs);
      final package = fixtures.package();
      final cache = ScriptQueryFormCache(CredentialStore(store: backend));
      expect(cache.write(package, target, {}, draft, draft: true), isTrue);
      await backend.flush();
      final reopenedBackend = await SoftwareSecureStore.open(blobs);
      final reopened = CredentialStore(store: reopenedBackend);
      final restored = ScriptQueryFormCache(reopened);
      expect(restored.read(package, target, {}, draft: true), draft);
      expect(
        ScriptCredentials(
          store: reopened,
          schoolId: 'synthetic',
          scriptId: package.manifest.id,
          sdkVersion: 17,
        ).list(),
        isEmpty,
      );
      final foreign = jsonDecode(package.encode()) as Map<String, dynamic>;
      foreign['manifest']['schoolId'] = 'foreign';
      final other = ScriptPackage.parse(jsonEncode(foreign));
      restored.write(other, target, {}, draft, draft: true);
      expect(restored.clearSchool('synthetic'), hasLength(1));
      await reopenedBackend.flush();
      expect(restored.read(package, target, {}, draft: true), isNull);
      expect(restored.read(other, target, {}, draft: true), isNotNull);
    },
  );

  test(
    'session form snapshots never count as login and logout removes them',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      final package = fixtures.package();
      await session.bootstrap();
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
      await session.selectTrustedScriptSchool(package.manifest.id);
      expect(
        await session.saveQueryForm(
          package.manifest.id,
          package.digest,
          target,
          {},
          form(),
        ),
        isTrue,
      );
      expect(session.isLoggedIn, isFalse);
      expect(session.credentialMetadata, isEmpty);
      expect(
        await session.cachedQueryForm(
          package.manifest.id,
          package.digest,
          target,
          {},
        ),
        isNotNull,
      );
      session.logout();
      expect(
        await session.cachedQueryForm(
          package.manifest.id,
          package.digest,
          target,
          {},
        ),
        isNull,
      );
      expect(
        await session.saveQueryForm(
          package.manifest.id,
          'wrong-digest',
          target,
          {},
          form(),
        ),
        isFalse,
      );
    },
  );
}
