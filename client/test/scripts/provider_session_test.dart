import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:elecon/core/credential/blob_store.dart';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/school_fixture.dart';

ScriptPackage _package(String id, {bool fail = false, bool climate = false}) =>
    ScriptPackage.parse(
      jsonEncode({
        'format': 'elecon-script/1',
        'manifest': {
          'sdkVersion': 4,
          'id': id,
          'version': '1.0.0',
          'schoolId': 'synthetic-providers',
          'name': 'Synthetic providers',
          'network': {'origins': []},
          'browser': false,
          'capabilities': [
            if (climate)
              for (final cap in ['climate.devices', 'climate.status'])
                {'id': cap, 'schema': 'elecon.$cap', 'schemaVersion': '1.0'},
            {
              'id': 'notice.list',
              'schema': 'elecon.notice.list',
              'schemaVersion': '1.1',
            },
            {
              'id': 'generic.section',
              'schema': 'elecon.generic.section',
              'schemaVersion': '1.0',
            },
          ],
          'home': [
            {'capability': 'notice.list', 'ttlSeconds': 60, 'preload': true},
          ],
        },
        'source':
            '''export const capabilities = {
      'notice.list': async (ctx) => {
        const count = Number((await ctx.credentials.get('count'))?.value ?? 0) + 1;
        await ctx.credentials.set('count', String(count));
        ${fail ? "throw new Error('SYNTHETIC_FAILURE');" : "return {items:[], sourceSystem:'$id'};"}
      },
      'generic.section': async (ctx) => ({
        sectionId: 'count', title: (await ctx.credentials.get('${climate ? 'climate-count' : 'count'}'))?.value ?? '0'
      }),
      'climate.devices': async (ctx) => {
        const count = Number((await ctx.credentials.get('climate-count'))?.value ?? 0) + 1;
        await ctx.credentials.set('climate-count', String(count));
        return {items: []};
      },
      'climate.status': async (ctx, p) => ({deviceId: p.deviceId})
    };''',
      }),
    );

Future<String> _count(SessionController session, String packageId) async {
  final run = await session.runTrustedScript(
    packageId,
    'generic.section',
    interactive: false,
  );
  expect(run.ok, isTrue, reason: run.reason);
  return (run.data as Map)['title'] as String;
}

class _GatedRegistryBlobs extends InMemoryBlobStore {
  final readStarted = Completer<void>();
  final releaseRead = Completer<void>();

  @override
  Future<Uint8List?> read(String name) async {
    if (name == 'trusted-scripts.json') {
      readStarted.complete();
      await releaseRead.future;
    }
    return super.read(name);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cancellation while opening the registry cannot re-admit an old run',
    () async {
      final package = _package('base');
      final blobs = _GatedRegistryBlobs();
      await blobs.write(
        'trusted-scripts.json',
        utf8.encode(
          jsonEncode({
            'version': 1,
            'entries': [
              {
                'package': package.encode(),
                'digest': package.digest,
                'enabled': true,
              },
            ],
          }),
        ),
      );
      final school = testSchool(schoolId: 'synthetic-providers');
      final session = SessionController(
        initialSchools: [school],
        blobStoreProvider: () async => blobs,
      );
      addTearDown(session.dispose);
      session.selectSchool(school);
      final pending = session.runTrustedScript(
        'base',
        'notice.list',
        interactive: false,
      );
      await blobs.readStarted.future;
      session.cancelTrustedScriptRuns();
      blobs.releaseRead.complete();
      final result = await pending;
      expect(result.reason, 'script_cancelled');
      expect(await _count(session, 'base'), '0');
    },
  );

  test(
    'cancellation while approving storage cannot re-admit an old run',
    () async {
      final blobs = InMemoryBlobStore();
      final session = SessionController(blobStoreProvider: () async => blobs);
      addTearDown(session.dispose);
      await session.bootstrap();
      final package = _package('base');
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
      await session.selectTrustedScriptSchool('base');
      final consentStarted = Completer<void>();
      final consent = Completer<bool>();
      session.scriptStorageConsent = () {
        consentStarted.complete();
        return consent.future;
      };
      final pending = session.runTrustedScript('base', 'notice.list');
      await consentStarted.future;
      session.cancelTrustedScriptRuns();
      consent.complete(false);
      final result = await pending;
      expect(result.reason, 'script_cancelled');
      expect(await _count(session, 'base'), '0');
    },
  );

  test(
    'local notice identifiers never fall through to a V1 detail source',
    () async {
      var legacyResolutions = 0;
      final school = testSchool(schoolId: 'synthetic-providers');
      final session = SessionController(
        initialSchools: [school],
        adapterServiceProvider: () async {
          legacyResolutions++;
          return null;
        },
      );
      addTearDown(session.dispose);
      await session.bootstrap();
      final package = _package('local-notices');
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
      session.selectSchool(school);
      final run = await session.runCapability(
        'notice.detail',
        params: {'id': 'local-id'},
      );
      expect(run.ok, isFalse);
      expect(run.reason, 'script_provider_unavailable');
      expect(legacyResolutions, 0);
    },
  );

  test(
    'preload runs only the selected provider and cached data follows selection',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      for (final id in ['base', 'extra']) {
        final package = _package(id);
        await session.installTrustedScript(
          package,
          approvedDigest: package.digest,
        );
      }
      await session.selectTrustedScriptSchool('base');
      expect(await _count(session, 'base'), '0');
      expect(await _count(session, 'extra'), '0');
      await session.refreshHomeData(force: true);
      expect(await _count(session, 'base'), '1');
      expect(await _count(session, 'extra'), '0');
      expect(
        ((await session.cachedCapability('notice.list'))!.data
            as Map)['sourceSystem'],
        'base',
      );
      final generation = session.trustedScriptViewGeneration;
      await session.selectTrustedScriptProvider(
        'synthetic-providers',
        'notice.list',
        'extra',
      );
      expect(session.trustedScriptViewGeneration, greaterThan(generation));
      expect(await session.cachedCapability('notice.list'), isNull);
      await session.refreshHomeData(force: true);
      expect(await _count(session, 'base'), '1');
      expect(await _count(session, 'extra'), '1');
      expect(
        ((await session.cachedCapability('notice.list'))!.data
            as Map)['sourceSystem'],
        'extra',
      );
      await session.selectTrustedScriptProvider(
        'synthetic-providers',
        'notice.list',
        null,
      );
      expect(
        ((await session.cachedCapability('notice.list'))!.data
            as Map)['sourceSystem'],
        'base',
      );
    },
  );

  test('login cannot sync climate through a superseded package', () async {
    final session = SessionController();
    addTearDown(session.dispose);
    await session.bootstrap();
    for (final id in ['base', 'extra']) {
      final package = _package(id, climate: true);
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
    }
    await session.selectTrustedScriptSchool('base');
    await session.selectTrustedScriptProvider(
      'synthetic-providers',
      'climate.devices',
      'extra',
    );
    expect(await _count(session, 'base'), '0');
    // The login sync is scheduled on the event queue. The next script waits for
    // any queued device query, so its counter observes an unwanted execution.
    await Future<void>(() {});
    expect(await _count(session, 'base'), '0');
  });

  test('failed enhancement execution never retries the base handler', () async {
    final session = SessionController();
    addTearDown(session.dispose);
    await session.bootstrap();
    for (final package in [_package('base'), _package('failing', fail: true)]) {
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
    }
    await session.selectTrustedScriptSchool('base');
    await session.selectTrustedScriptProvider(
      'synthetic-providers',
      'notice.list',
      'failing',
    );
    final run = await session.runCapability('notice.list', interactive: false);
    expect(run.ok, isFalse);
    expect(await _count(session, 'base'), '0');
    expect(await _count(session, 'failing'), '1');
  });
}
