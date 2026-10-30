import 'dart:convert';
import 'dart:async';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/credential/types.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/data_cache.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> fixture({
  String school = 'example',
  String version = '1.0.0',
  String source =
      'export const capabilities={"notice.list":async()=>({items:[]})};',
}) => {
  'format': 'elecon-script/1',
  'manifest': {
    'sdkVersion': 4,
    'id': 'school.example',
    'version': version,
    'schoolId': school,
    'name': 'Synthetic school',
    'network': {'origins': []},
    'browser': true,
    'capabilities': [
      {
        'id': 'notice.list',
        'schema': 'elecon.notice.list',
        'schemaVersion': '1.1',
      },
    ],
    'home': [
      {'capability': 'notice.list', 'ttlSeconds': 30, 'preload': true},
    ],
  },
  'source': source,
};
ScriptPackage package({String school = 'example', String version = '1.0.0'}) =>
    ScriptPackage.parse(jsonEncode(fixture(school: school, version: version)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'home declaration rejects undeclared, duplicate, oversized and old SDK policies',
    () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (m) => m['sdkVersion'] = 3,
        (m) => m['home'] = null,
        (m) => m['home'][0]['ttlSeconds'] = 29,
        (m) => m['home'][0]['preload'] = 'true',
        (m) => m['home'][0]['capability'] = 'card.balance',
        (m) => m['home'].add(<String, dynamic>{...m['home'][0]}),
        (m) => m['home'][0]['params'] = {'x': 'x' * 4096},
        (m) => m['home'][0]['unknown'] = true,
      ]) {
        final json = jsonDecode(jsonEncode(fixture())) as Map<String, dynamic>;
        mutate(json['manifest']);
        expect(
          () => ScriptPackage.parse(jsonEncode(json)),
          throwsFormatException,
        );
      }
      expect(package().manifest.home.single.preload, isTrue);
    },
  );

  test(
    'canonical parameters, TTL and retention preserve actual successful time',
    () {
      var time = 1000000;
      final cache = ScriptDataCache(CredentialStore(), now: () => time);
      final pkg = package();
      expect(
        cache.write(
          pkg,
          'notice.list',
          {
            'a': 1,
            'b': {'d': 2, 'c': 3},
          },
          {'items': []},
        ),
        isTrue,
      );
      final params = {
        'b': {'c': 3, 'd': 2},
        'a': 1,
      };
      final original = cache.read(pkg, 'notice.list', params: params)!;
      time += 30000;
      expect(cache.read(pkg, 'notice.list', params: params)!.isStale, isTrue);
      expect(
        cache.read(pkg, 'notice.list', params: params)!.fetchedAt,
        original.fetchedAt,
      );
      expect(cache.read(pkg, 'notice.list'), isNull);
      expect(
        cache.read(package(version: '1.0.1'), 'notice.list', params: params),
        isNull,
      );
      expect(
        cache.read(package(school: 'other'), 'notice.list', params: params),
        isNull,
      );
      time += ScriptDataCache.retentionMs;
      expect(cache.latest(pkg, 'notice.list'), isNull);
    },
  );

  test(
    'cache cannot count as credentials, be addressed or return invalid schema',
    () {
      final store = CredentialStore();
      final cache = ScriptDataCache(store);
      final pkg = package();
      expect(cache.write(pkg, 'notice.list', {}, {'items': []}), isTrue);
      final creds = ScriptCredentials(
        store: store,
        schoolId: 'example',
        scriptId: pkg.manifest.id,
        sdkVersion: 4,
      );
      expect(creds.list(), isEmpty);
      expect(
        () => creds.get(store.list().single.ref),
        throwsA(isA<ScriptCredentialException>()),
      );
      expect(
        cache.write(pkg, 'notice.list', {}, {'items': 'invalid'}),
        isFalse,
      );
      expect(cache.read(pkg, 'notice.list')!.data, {'items': []});
      final entry = store.list().single;
      store.put(
        CredentialEntry(
          ref: entry.ref,
          schoolId: entry.schoolId,
          type: entry.type,
          scope: [],
          value: '{"params":{},"data":{"items":"invalid"}}',
          acquiredAt: entry.acquiredAt,
          expiresAt: null,
          status: CredentialStatus.active,
        ),
      );
      expect(cache.read(pkg, 'notice.list'), isNull);
    },
  );

  test('bounded cache evicts oldest and refuses oversized outputs', () {
    var time = 1000000;
    final store = CredentialStore();
    final cache = ScriptDataCache(store, now: () => time++);
    final pkg = package();
    for (var i = 0; i < 33; i++) {
      cache.write(pkg, 'notice.list', {'page': i}, {'items': []});
    }
    expect(store.list().length, 32);
    expect(cache.read(pkg, 'notice.list', params: {'page': 0}), isNull);
    expect(cache.latest(pkg, 'notice.list')!.params, {'page': 32});
    expect(
      cache.write(pkg, 'notice.list', {}, {
        'items': [
          {
            'id': 'large',
            'title': 'x' * ScriptDataCache.maxBytes,
            'category': 'academic',
            'source': 'Synthetic',
          },
        ],
      }),
      isFalse,
    );
  });

  test(
    'session cache restores through chosen storage and logout erases it',
    () async {
      final blobs = InMemoryBlobStore();
      final session = SessionController(blobStoreProvider: () async => blobs);
      await session.bootstrap();
      final pkg = package();
      await session.installTrustedScript(pkg, approvedDigest: pkg.digest);
      await session.selectTrustedScriptSchool(pkg.manifest.id);
      session.scriptStorageConsent = () async => true;
      expect((await session.runCapability('notice.list')).ok, isTrue);
      expect(session.isLoggedIn, isFalse);
      expect(session.credentialMetadata, isEmpty);
      final time = (await session.cachedCapability('notice.list'))!.fetchedAt;
      await session.flush();
      session.dispose();
      final restored = SessionController(blobStoreProvider: () async => blobs);
      addTearDown(restored.dispose);
      await restored.bootstrap();
      expect((await restored.cachedCapability('notice.list'))!.fetchedAt, time);
      expect(restored.isLoggedIn, isFalse);
      restored.logout();
      expect(await restored.cachedCapability('notice.list'), isNull);
    },
  );

  test('preload deduplicates, honors TTL and never presents UI', () async {
    final session = SessionController();
    addTearDown(session.dispose);
    await session.bootstrap();
    var opened = 0;
    var forms = 0;
    session.scriptBrowserPresenter = (_, execute) async {
      opened++;
      return execute((_, _) async => null);
    };
    session.scriptInputPresenter = (_, execute) async {
      forms++;
      return execute((_) async => null);
    };
    final pkg = package();
    await session.installTrustedScript(pkg, approvedDigest: pkg.digest);
    await session.selectTrustedScriptSchool(pkg.manifest.id);
    final revision = session.homeDataRevision;
    await Future.wait([session.refreshHomeData(), session.refreshHomeData()]);
    expect(session.homeDataRevision, revision + 1);
    expect(await session.cachedCapability('notice.list'), isNotNull);
    await session.refreshHomeData();
    expect(session.homeDataRevision, revision + 1);
    await session.refreshHomeData(force: true);
    expect(session.homeDataRevision, revision + 2);
    expect(opened, 0);
    expect(forms, 0);
    final blocked = ScriptPackage.parse(
      jsonEncode(
        fixture(
          version: '1.0.1',
          source:
              'export const capabilities={"notice.list":async(ctx)=>{await ctx.browser.open("https://example.invalid");return {items:[]};}};',
        ),
      ),
    );
    await session.installTrustedScript(blocked, approvedDigest: blocked.digest);
    await session.refreshHomeData();
    expect(opened, 0);
    expect(forms, 0);
    expect(await session.cachedCapability('notice.list'), isNull);
  });
  test(
    'logout cancels a late successful output before it can recreate cache',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      final started = Completer<void>();
      final pkg = ScriptPackage.parse(
        jsonEncode(
          fixture(
            source:
                'export const capabilities={"notice.list":async(ctx)=>{ctx.log("info","synthetic_wait");await new Promise(r=>setTimeout(r,50));return {items:[]};}};',
          ),
        ),
      );
      await session.installTrustedScript(pkg, approvedDigest: pkg.digest);
      await session.selectTrustedScriptSchool(pkg.manifest.id);
      final pending = session.runCapability(
        'notice.list',
        onLog: (_, message) {
          if (message == 'synthetic_wait' && !started.isCompleted) {
            started.complete();
          }
        },
      );
      await started.future;
      session.logout();
      expect((await pending).ok, isFalse);
      expect(await session.cachedCapability('notice.list'), isNull);
      expect(session.isLoggedIn, isFalse);
    },
  );

  test('school byte budget evicts data independently of entry count', () {
    var time = 1000000;
    final store = CredentialStore();
    final cache = ScriptDataCache(store, now: () => time++);
    final pkg = package();
    for (var i = 0; i < 12; i++) {
      cache.write(
        pkg,
        'notice.list',
        {'page': i},
        {
          'items': [
            {
              'id': 'large',
              'title': 'x' * (400 * 1024),
              'category': 'academic',
              'source': 'Synthetic',
            },
          ],
        },
      );
    }
    final bytes = store.list().fold<int>(
      0,
      (n, e) => n + utf8.encode(e.value).length,
    );
    expect(bytes, lessThanOrEqualTo(ScriptDataCache.maxSchoolBytes));
    expect(store.list().length, lessThan(12));
    expect(cache.read(pkg, 'notice.list', params: {'page': 11}), isNotNull);
    expect(cache.read(pkg, 'notice.list', params: {'page': 0}), isNull);
  });
  test('digest-bound home parameters are deeply immutable', () {
    final json = fixture();
    json['manifest']['home'][0]['params'] = {
      'nested': {
        'items': [1, 2],
      },
    };
    final pkg = ScriptPackage.parse(jsonEncode(json));
    final nested = pkg.manifest.home.single.params['nested'] as Map;
    expect(() => nested['items'] = [], throwsUnsupportedError);
    expect(() => (nested['items'] as List).add(3), throwsUnsupportedError);
    expect(ScriptPackage.parse(pkg.encode()).digest, pkg.digest);
  });
}
