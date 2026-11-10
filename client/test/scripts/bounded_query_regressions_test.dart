import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/messages/archive.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'bounded_queries_test.dart' as queries;
import '../messages/archive_test.dart' as messages;

class FailureBlobs extends InMemoryBlobStore {
  bool fail = false;
  int failures = 0;
  Completer<void>? entered, gate;
  @override
  Future<void> write(String name, List<int> bytes) async {
    if (name == 'store.enc' && gate != null) {
      final release = gate!;
      gate = null;
      entered?.complete();
      await release.future;
    }
    if (name == 'store.enc' && failures > 0) {
      failures--;
      throw StateError('synthetic first commit failure');
    }
    if (fail && name == 'store.enc') throw StateError('synthetic failure');
    await super.write(name, bytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
    'a directory pause stays enforced without blocking other service queries',
    () async {
      final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => first.close(force: true));
      addTearDown(() => second.close(force: true));
      first.listen((r) {
        r.response.statusCode = 429;
        r.response.headers.set('retry-after', '3600');
        r.response.close();
      });
      var reached = false;
      second.listen((r) {
        reached = true;
        r.response.close();
      });
      final a = 'http://127.0.0.1:${first.port}';
      final b = 'http://127.0.0.1:${second.port}';
      final raw =
          jsonDecode(queries.source(extra: 'await ctx.fetch(p.url);').encode())
              as Map<String, dynamic>;
      raw['manifest']['network'] = {
        'origins': [a, b],
        'ipAllow': ['127.0.0.1'],
      };
      (raw['manifest']['capabilities'] as List).addAll([
        {
          'id': 'messages.session',
          'schema': 'elecon.messages.session',
          'schemaVersion': '1.0',
        },
        {
          'id': 'messages.conversations',
          'schema': 'elecon.messages.conversations',
          'schemaVersion': '1.3',
          'concurrency': {'credentials': []},
        },
      ]);
      final previousSource = (raw['source'] as String).replaceFirst(
        'export const capabilities=',
        'const capabilities=',
      );
      raw['source'] =
          '''$previousSource
        capabilities['messages.session']=async()=>(${jsonEncode(messages.account)});
        capabilities['messages.conversations']=async(ctx,p)=>{
          await ctx.fetch(p.url);
          return {serviceId:'synthetic-service',accountId:'synthetic-account',accountLabel:'Synthetic',fetchedAt:'${messages.stamp}',coverage:'complete',items:[]};
        };
        export {capabilities};
      ''';
      final p = ScriptPackage.parse(jsonEncode(raw));
      final session = await queries.prepare([p]);
      expect(
        (await session.runTrustedScript(
          p.manifest.id,
          'messages.session',
          params: {'operation': 'status'},
        )).ok,
        isTrue,
      );
      expect(
        (await session.runTrustedScript(
          p.manifest.id,
          'messages.conversations',
          params: {'accountId': 'synthetic-account', 'url': a},
        )).ok,
        isTrue,
      );
      expect(
        (await session.runTrustedScript(
          p.manifest.id,
          'messages.conversations',
          params: {'accountId': 'synthetic-account', 'url': a},
        )).reason,
        'process_request_limit',
      );
      final result = await session.runTrustedScript(
        p.manifest.id,
        'grades.list',
        params: {'url': b},
      );
      expect(
        result.ok,
        isTrue,
        reason: 'reason=${result.reason}; reached=$reached',
      );
      expect(reached, isTrue);
    },
  );
  test(
    'explicit title patches apply even when the title equals the entity id',
    () async {
      final p = messages.package(conversationsVersion: '1.3');
      final archive = MessageArchiveStore(
        CredentialStore(store: InMemorySecureStore(releaseMode: false)),
      );
      archive.saveAccount(p, messages.account);
      await archive.merge(
        p,
        'messages.conversations',
        {'accountId': messages.account['accountId']},
        {
          'serviceId': messages.account['serviceId'],
          'accountId': messages.account['accountId'],
          'accountLabel': 'Synthetic',
          'fetchedAt': messages.stamp,
          'coverage': 'complete',
          'items': [
            {
              'conversationId': 'room-1',
              'conversationKind': 'group',
              'title': 'Old name',
            },
          ],
        },
        isActive: () => true,
      );
      await archive.merge(
        p,
        'messages.enrich',
        {
          'accountId': messages.account['accountId'],
          'items': [
            {'conversationId': 'room-1', 'conversationKind': 'group'},
          ],
        },
        {
          'serviceId': messages.account['serviceId'],
          'accountId': messages.account['accountId'],
          'fetchedAt': messages.stamp,
          'items': [
            {
              'conversationId': 'room-1',
              'conversationKind': 'group',
              'title': 'room-1',
            },
          ],
        },
        isActive: () => true,
        expectedDirectory: archive.directoryRevision(p),
      );
      expect((await archive.read(p))!.conversations.single.title, 'room-1');
    },
  );
  test(
    'failed cache commits restore evictions and preserve a concurrent successful result',
    () async {
      final blobs = FailureBlobs();
      final raw = jsonDecode(queries.source().encode()) as Map<String, dynamic>;
      raw['manifest']['home'] = [
        {'capability': 'grades.list', 'ttlSeconds': 300, 'preload': false},
      ];
      final p = ScriptPackage.parse(jsonEncode(raw));
      final session = SessionController(blobStoreProvider: () async => blobs);
      addTearDown(session.dispose);
      await session.bootstrap();
      await session.installTrustedScript(p, approvedDigest: p.digest);
      await session.selectTrustedScriptSchool(p.manifest.id);
      await session.ensurePersistentStore(
        confirmSoftwareFallback: () async => true,
      );
      for (var i = 0; i < 32; i++) {
        expect(
          (await session.runTrustedScript(
            p.manifest.id,
            'grades.list',
            params: {'term': '$i'},
          )).ok,
          isTrue,
        );
      }
      expect(
        await session.cachedCapability('grades.list', params: {'term': '0'}),
        isNotNull,
      );
      blobs.fail = false;
      await session.flush();
      final persisting = Completer<void>(), release = Completer<void>();
      blobs.entered = persisting;
      blobs.gate = release;
      blobs.failures = 2; // insertion and quota eviction both fail durably
      final rejected = session.runTrustedScript(
        p.manifest.id,
        'grades.list',
        params: {'term': 'rejected'},
      );
      await persisting.future;
      final executing = Completer<void>();
      final accepted = session.runTrustedScript(
        p.manifest.id,
        'grades.list',
        params: {'term': 'accepted'},
        onLog: (_, _) {
          if (!executing.isCompleted) executing.complete();
        },
      );
      await executing.future;
      release.complete();
      expect((await rejected).reason, 'credential_persist_failed');
      expect((await accepted).ok, isTrue);
      expect(
        await session.cachedCapability(
          'grades.list',
          params: {'term': 'rejected'},
        ),
        isNull,
      );
      expect(
        await session.cachedCapability(
          'grades.list',
          params: {'term': 'accepted'},
        ),
        isNotNull,
      );
      expect(
        await session.cachedCapability('grades.list', params: {'term': '1'}),
        isNotNull,
        reason: 'only the accepted insertion may evict an old entry',
      );
      blobs.fail = true;
      final failed = await session.runTrustedScript(
        p.manifest.id,
        'grades.list',
        params: {'term': '33'},
      );
      expect(failed.reason, 'credential_persist_failed');
      expect(
        await session.cachedCapability('grades.list', params: {'term': '1'}),
        isNotNull,
      );
    },
  );
  test('queued enrichment retains its admission directory revision', () async {
    final raw =
        jsonDecode(messages.package(conversationsVersion: '1.3').encode())
            as Map<String, dynamic>;
    raw['manifest']['sdkVersion'] = 20;
    raw['manifest']['accounts'] = [];
    for (final cap in raw['manifest']['capabilities'] as List) {
      cap['concurrency'] = {
        'credentials': [
          {'namespace': 'synthetic.shared', 'key': 'session'},
        ],
      };
    }
    raw['source'] =
        '''export const capabilities = {
      'messages.session': async()=>(${jsonEncode(messages.account)}),
      'messages.conversations': async(ctx,p)=>{
        ctx.log('info','directory-start');
        await new Promise(r=>setTimeout(r,p.delay||1));
        return {serviceId:'synthetic-service',accountId:'synthetic-account',accountLabel:'Synthetic',fetchedAt:'${messages.stamp}',coverage:'complete',items:[{conversationId:'room-1',conversationKind:'group',title:p.title}]};
      },
      'messages.enrich': async()=>({serviceId:'synthetic-service',accountId:'synthetic-account',fetchedAt:'${messages.stamp}',items:[{conversationId:'room-1',conversationKind:'group',title:'Stale metadata'}]})
    };''';
    final p = ScriptPackage.parse(jsonEncode(raw));
    final session = await queries.prepare([p]);
    expect(
      (await session.runTrustedScript(
        p.manifest.id,
        'messages.session',
        params: {'operation': 'status'},
      )).ok,
      isTrue,
    );
    expect(
      (await session.runTrustedScript(
        p.manifest.id,
        'messages.conversations',
        params: {'accountId': 'synthetic-account', 'title': 'Old directory'},
      )).ok,
      isTrue,
    );
    final started = Completer<void>();
    final refreshed = session.runTrustedScript(
      p.manifest.id,
      'messages.conversations',
      params: {
        'accountId': 'synthetic-account',
        'title': 'New directory',
        'delay': 150,
      },
      onLog: (_, m) {
        if (!started.isCompleted) started.complete();
      },
    );
    await started.future;
    final queued = session.runTrustedScript(
      p.manifest.id,
      'messages.enrich',
      params: {
        'accountId': 'synthetic-account',
        'items': [
          {'conversationId': 'room-1', 'conversationKind': 'group'},
        ],
      },
    );
    expect((await refreshed).ok, isTrue);
    expect((await queued).reason, 'script_cancelled');
    expect(
      (await session.messageArchive(p))!.conversations.single.title,
      'New directory',
    );
  });
}
