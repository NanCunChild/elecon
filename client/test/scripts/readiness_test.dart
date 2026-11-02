import 'dart:convert';
import 'package:elecon/core/adapter_service.dart';
import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage package({String version = '1.0.0'}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 5,
      'id': 'setup-example',
      'schoolId': 'example',
      'version': version,
      'name': 'Synthetic setup',
      'network': {'origins': []},
      'browser': false,
      'capabilities': [
        for (final id in ['notice.list', 'generic.section'])
          {
            'id': id,
            'schema': 'elecon.$id',
            'schemaVersion': id == 'notice.list' ? '1.1' : '1.0',
          },
      ],
      'home': [
        {'capability': 'notice.list', 'preload': true, 'ttlSeconds': 30},
      ],
    },
    'source': '''export const capabilities={
    'notice.list':async(ctx,p)=>{
      const count=Number((await ctx.credentials.get('calls'))?.value??0)+1;
      await ctx.credentials.set('calls',String(count));
      if(p.fail)throw new Error('synthetic_transport_failure');
      if(p.configure)await ctx.credentials.set('ready','yes');
      if(!(await ctx.credentials.get('ready'))){const e=new Error('no setup');e.code='configuration_required';throw e;}
      return {items:[]};
    },
    'generic.section':async(ctx)=>({sectionId:'count',title:(await ctx.credentials.get('calls'))?.value??'0'})
  };''',
  }),
);

Future<int> calls(SessionController session) async {
  final run = await session.runCapability('generic.section');
  expect(run.ok, isTrue, reason: run.reason);
  return int.parse((run.data as Map)['title'] as String);
}

class FailingBlobs extends InMemoryBlobStore {
  bool fail = false;
  @override
  Future<void> write(String name, List<int> bytes) async {
    if (fail && name == 'store.enc') {
      throw StateError('synthetic_write_failure');
    }
    await super.write(name, bytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'configuration skips automatic and forced refresh; explicit setup resumes',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      final p = package();
      await session.installTrustedScript(p, approvedDigest: p.digest);
      await session.selectTrustedScriptSchool(p.manifest.id);
      await session.refreshHomeData();
      expect(await session.capabilityNeedsConfiguration('notice.list'), isTrue);
      expect(await calls(session), 1);
      await session.refreshHomeData(force: true);
      final skipped = await session.runCapability(
        'notice.list',
        interactive: false,
      );
      expect(skipped.failureKind, CapabilityFailureKind.configuration);
      expect(await calls(session), 1);
      final other = await session.runCapability(
        'notice.list',
        params: {'scope': 'other'},
        interactive: false,
      );
      expect(other.failureKind, CapabilityFailureKind.configuration);
      expect(await calls(session), 2);
      final failure = await session.runCapability(
        'notice.list',
        params: {'fail': true},
      );
      expect(failure.failureKind, CapabilityFailureKind.run);
      expect(await session.capabilityNeedsConfiguration('notice.list'), isTrue);
      expect(
        await session.capabilityNeedsConfiguration(
          'notice.list',
          params: {'fail': true},
        ),
        isFalse,
      );
      final configured = await session.runCapability(
        'notice.list',
        params: {'configure': true},
      );
      expect(configured.ok, isTrue, reason: configured.reason);
      expect(
        await session.capabilityNeedsConfiguration('notice.list'),
        isFalse,
      );
      expect(
        await session.capabilityNeedsConfiguration(
          'notice.list',
          params: {'scope': 'other'},
        ),
        isFalse,
      );
      await session.refreshHomeData(force: true);
      expect(await calls(session), 5);
    },
  );

  test(
    'setup state survives protected storage but not digest change or logout',
    () async {
      final blobs = InMemoryBlobStore();
      final first = SessionController(blobStoreProvider: () async => blobs);
      await first.bootstrap();
      final p = package();
      await first.installTrustedScript(p, approvedDigest: p.digest);
      await first.selectTrustedScriptSchool(p.manifest.id);
      await first.ensurePersistentStore(
        confirmSoftwareFallback: () async => true,
      );
      await first.refreshHomeData();
      await first.flush();
      first.dispose();
      final session = SessionController(blobStoreProvider: () async => blobs);
      addTearDown(session.dispose);
      await session.bootstrap();
      expect(await session.capabilityNeedsConfiguration('notice.list'), isTrue);
      expect(
        session.credentialRefs.every(
          (ref) => !ref.startsWith('script-readiness:'),
        ),
        isTrue,
      );
      await session.refreshHomeData(force: true);
      expect(await calls(session), 1);
      final update = package(version: '1.0.1');
      await session.installTrustedScript(update, approvedDigest: update.digest);
      expect(
        await session.capabilityNeedsConfiguration('notice.list'),
        isFalse,
      );
      await session.refreshHomeData();
      expect(await calls(session), 2);
      session.logout();
      expect(
        await session.capabilityNeedsConfiguration('notice.list'),
        isFalse,
      );
    },
  );
  test('failed setup persistence retains the skip marker', () async {
    final blobs = FailingBlobs();
    final session = SessionController(blobStoreProvider: () async => blobs);
    addTearDown(session.dispose);
    await session.bootstrap();
    final p = package();
    await session.installTrustedScript(p, approvedDigest: p.digest);
    await session.selectTrustedScriptSchool(p.manifest.id);
    await session.ensurePersistentStore(
      confirmSoftwareFallback: () async => true,
    );
    await session.refreshHomeData();
    blobs.fail = true;
    final failed = await session.runCapability(
      'notice.list',
      params: {'configure': true},
    );
    expect(failed.reason, 'credential_persist_failed');
    expect(
      await session.latestCachedCapability('notice.list'),
      isNull,
      reason: 'a failed setup must not leave successful-looking cache data',
    );
    expect(await session.capabilityNeedsConfiguration('notice.list'), isTrue);
    blobs.fail = false;
    await session.refreshHomeData(force: true);
    expect(await session.capabilityNeedsConfiguration('notice.list'), isTrue);
    expect(
      (await session.runCapability(
        'notice.list',
        interactive: false,
      )).failureKind,
      CapabilityFailureKind.configuration,
    );
  });
}
