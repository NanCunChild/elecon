import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/home/campus_snapshot_loader.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/school_fixture.dart';

// Real IO is needed for the final declared loopback fixture. Configure this
// before QuickJS creates its shared host callback port (which retains its zone).
// All other script network allowlists in this file are empty.
class _NetworkSessionBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

ScriptPackage _package({
  String id = 'local-example',
  String school = 'example',
  String version = '1.0.0',
  String name = 'Local school',
  bool browser = false,
  Map<String, Object?> network = const {'origins': []},
  String capability = 'notice.list',
  String schemaVersion = '1.1',
  String source =
      'export const capabilities={"notice.list":async()=>({items:[{id:"one",title:"Local notice",category:"academic",source:"Synthetic school"}]})};',
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 1,
      'id': id,
      'version': version,
      'schoolId': school,
      'name': name,
      'network': network,
      'browser': browser,
      'capabilities': [
        {
          'id': capability,
          'schema': 'elecon.$capability',
          'schemaVersion': schemaVersion,
        },
      ],
    },
    'source': source,
  }),
);

Future<void> _install(SessionController session, ScriptPackage package) =>
    session.installTrustedScript(package, approvedDigest: package.digest);

void main() {
  _NetworkSessionBinding();

  test(
    'explicit trust discovers a new school and routes normal runCapability to JS',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      final package = _package();
      await expectLater(
        session.installTrustedScript(package, approvedDigest: 'wrong'),
        throwsStateError,
      );
      expect(session.availableSchools, isEmpty);
      await _install(session, package);
      expect(session.availableSchools.single.id, 'example');
      expect(session.availableSchools.single.adapterId, 'script:local-example');
      await session.selectTrustedScriptSchool('local-example');
      final result = await session.runCapability('notice.list');
      expect(result.ok, isTrue, reason: result.reason);
      expect((result.data as Map)['items'][0]['title'], 'Local notice');
      expect(result.supportedCapabilities, {'notice.list'});
      final snapshot = await loadCampusSnapshot(session);
      expect(snapshot.schoolName, 'Local school');
      expect(snapshot.notices!.items.single.title, 'Local notice');
    },
  );

  test(
    'local installations and selected school survive session reconstruction',
    () async {
      final blobs = InMemoryBlobStore();
      final first = SessionController(blobStoreProvider: () async => blobs);
      await first.bootstrap();
      final package = _package();
      await _install(first, package);
      await first.selectTrustedScriptSchool(package.manifest.id);
      await first.flush();
      first.dispose();

      final restored = SessionController(blobStoreProvider: () async => blobs);
      addTearDown(restored.dispose);
      await restored.bootstrap();
      expect(restored.selectedSchool?.id, package.manifest.schoolId);
      expect(restored.availableSchools.single.displayName, 'Local school');
      expect(
        (await restored.scriptRegistry)
            .find(package.manifest.id)
            ?.package
            .digest,
        package.digest,
      );
      expect((await restored.runCapability('notice.list')).ok, isTrue);
    },
  );

  test(
    'same credential key remains distinct across independently installed schools',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      ScriptPackage school(String id, String secret) => _package(
        id: id,
        school: id,
        source:
            '''
      export const capabilities={'notice.list':async(ctx)=>{
        const before=await ctx.credentials.get('session');
        await ctx.credentials.set('session','$secret');
        return {items:[],sourceSystem:before ? before.value : 'EMPTY'};
      }};
    ''',
      );
      await _install(session, school('school-a', 'SYNTHETIC_A'));
      await _install(session, school('school-b', 'SYNTHETIC_B'));
      await session.selectTrustedScriptSchool('school-a');
      expect(
        ((await session.runCapability('notice.list')).data
            as Map)['sourceSystem'],
        'EMPTY',
      );
      await session.selectTrustedScriptSchool('school-b');
      expect(session.isLoggedIn, isFalse);
      expect(session.credentialCount, 0);
      expect(session.credentialMetadata, isEmpty);
      expect(
        ((await session.runCapability('notice.list')).data
            as Map)['sourceSystem'],
        'EMPTY',
      );
      expect(session.isLoggedIn, isTrue);
      expect(session.credentialCount, 1);
      await session.selectTrustedScriptSchool('school-a');
      expect(
        ((await session.runCapability('notice.list')).data
            as Map)['sourceSystem'],
        'SYNTHETIC_A',
      );
      session.logout();
      await session.selectTrustedScriptSchool('school-b');
      expect(
        ((await session.runCapability('notice.list')).data
            as Map)['sourceSystem'],
        'SYNTHETIC_B',
      );
    },
  );

  for (final mutation in ['logout', 'switch', 'disable', 'update', 'remove']) {
    test(
      '$mutation invalidates a waiting script before late credential writes',
      () async {
        final session = SessionController();
        addTearDown(session.dispose);
        await session.bootstrap();
        final slow = _package(
          browser: true,
          source: '''
        export const capabilities={'notice.list':async(ctx)=>{
          await ctx.browser.evaluate('synthetic wait');
          await ctx.credentials.set('late','SYNTHETIC_LATE');
          return {items:[]};
        }};
      ''',
        );
        await _install(session, slow);
        await _install(session, _package(id: 'other', school: 'other'));
        await session.selectTrustedScriptSchool(slow.manifest.id);
        final entered = Completer<void>();
        final pending = Completer<Object?>();
        final running = session.runTrustedScript(
          slow.manifest.id,
          'notice.list',
          browserCall: (_, _) {
            entered.complete();
            return pending.future;
          },
        );
        await entered.future.timeout(const Duration(seconds: 5));
        switch (mutation) {
          case 'logout':
            session.logout();
          case 'switch':
            await session.selectTrustedScriptSchool('other');
          case 'disable':
            await session.enableTrustedScript(slow.manifest.id, false);
          case 'update':
            await _install(session, _package(version: '1.0.1'));
          case 'remove':
            await session.removeTrustedScript(slow.manifest.id);
        }
        final result = await running.timeout(const Duration(seconds: 2));
        expect(result.ok, isFalse);
        pending.complete('late old page result');
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(
          session.credentialRefs.where((ref) => ref.endsWith(':late')),
          isEmpty,
        );
      },
    );
  }

  test(
    'disable removes local-only selected school; reenable and update restore it',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      final original = _package();
      await _install(session, original);
      await session.selectTrustedScriptSchool(original.manifest.id);
      await session.enableTrustedScript(original.manifest.id, false);
      expect(session.selectedSchool, isNull);
      expect(session.availableSchools, isEmpty);
      expect(
        (await session.runTrustedScript(
          original.manifest.id,
          'notice.list',
        )).ok,
        isFalse,
      );
      await session.enableTrustedScript(original.manifest.id, true);
      await session.selectTrustedScriptSchool(original.manifest.id);
      await _install(
        session,
        _package(version: '1.0.1', name: 'Updated school'),
      );
      expect(session.selectedSchool?.displayName, 'Updated school');
      expect((await session.runCapability('notice.list')).ok, isTrue);
    },
  );

  test(
    'missing notices leave other local capabilities available in the snapshot',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      final package = _package(
        capability: 'grades.list',
        source:
            'export const capabilities={"grades.list":async()=>({term:"2026-1",items:[]})};',
      );
      await _install(session, package);
      await session.selectTrustedScriptSchool(package.manifest.id);
      final snapshot = await loadCampusSnapshot(session);
      expect(snapshot.notices, isNull);
      expect(snapshot.supportedCapabilities, {'grades.list'});
      expect(snapshot.isEmpty, isFalse);
    },
  );
  test(
    'simultaneous refresh invocations serialize and second sees first credential write',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      final package = _package(
        browser: true,
        source: """
      export const capabilities={'notice.list':async(ctx)=>{
        const before=await ctx.credentials.get('counter');
        await ctx.browser.evaluate('yield');
        const next=Number(before ? before.value : '0')+1;
        await ctx.credentials.set('counter',String(next));
        return {items:[],sourceSystem:String(next)};
      }};
    """,
      );
      await _install(session, package);
      await session.selectTrustedScriptSchool(package.manifest.id);
      final entered = Completer<void>();
      final gate = Completer<Object?>();
      var calls = 0;
      Future<Object?> browser(String _, Map<String, Object?> _) {
        calls++;
        if (calls == 1) {
          entered.complete();
          return gate.future;
        }
        return Future.value(null);
      }

      final first = session.runTrustedScript(
        package.manifest.id,
        'notice.list',
        browserCall: browser,
      );
      final second = session.runTrustedScript(
        package.manifest.id,
        'notice.list',
        browserCall: browser,
      );
      await entered.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(calls, 1, reason: 'The second invocation must remain queued');
      gate.complete(null);
      final results = await Future.wait([
        first,
        second,
      ]).timeout(const Duration(seconds: 5));
      expect(results.every((result) => result.ok), isTrue);
      expect(results.map((result) => (result.data as Map)['sourceSystem']), [
        '1',
        '2',
      ]);
      expect(calls, 2);
    },
  );

  test(
    'logout cancels queued invocations before they can read or refresh credentials',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      final package = _package(
        browser: true,
        source: """
      export const capabilities={'notice.list':async(ctx)=>{
        await ctx.browser.evaluate('yield');
        await ctx.credentials.set('after-logout','SYNTHETIC');
        return {items:[]};
      }};
    """,
      );
      await _install(session, package);
      await session.selectTrustedScriptSchool(package.manifest.id);
      final entered = Completer<void>();
      final gate = Completer<Object?>();
      var calls = 0;
      Future<Object?> browser(String _, Map<String, Object?> _) {
        calls++;
        if (!entered.isCompleted) entered.complete();
        return gate.future;
      }

      final first = session.runTrustedScript(
        package.manifest.id,
        'notice.list',
        browserCall: browser,
      );
      final queued = session.runTrustedScript(
        package.manifest.id,
        'notice.list',
        browserCall: browser,
      );
      await entered.future.timeout(const Duration(seconds: 5));
      session.logout();
      final results = await Future.wait([
        first,
        queued,
      ]).timeout(const Duration(seconds: 2));
      expect(results.every((result) => !result.ok), isTrue);
      expect(calls, 1);
      gate.complete(null);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(session.credentialRefs, isEmpty);
    },
  );

  test(
    'direct home capability resolves consent and persists credentials across restart',
    () async {
      final blobs = InMemoryBlobStore();
      final first = SessionController(blobStoreProvider: () async => blobs);
      await first.bootstrap();
      final package = _package(
        source: """
      export const capabilities={'notice.list':async(ctx)=>{
        const previous=await ctx.credentials.get('session');
        if(!previous) await ctx.credentials.set('session','PERSISTED_SYNTHETIC');
        return {items:[],sourceSystem:previous ? previous.value : 'CREATED'};
      }};
    """,
      );
      await _install(first, package);
      await first.selectTrustedScriptSchool(package.manifest.id);
      var asked = 0;
      first.scriptStorageConsent = () async {
        asked++;
        return true;
      };
      final created = await first.runCapability('notice.list');
      expect(created.ok, isTrue, reason: created.reason);
      expect((created.data as Map)['sourceSystem'], 'CREATED');
      expect(first.credentialProtection, SessionCredentialProtection.software);
      expect(asked, 1);
      await first.flush();
      first.dispose();

      final restored = SessionController(blobStoreProvider: () async => blobs);
      addTearDown(restored.dispose);
      await restored.bootstrap();
      expect(restored.selectedSchool?.id, package.manifest.schoolId);
      final result = await restored.runCapability('notice.list');
      expect(result.ok, isTrue, reason: result.reason);
      expect((result.data as Map)['sourceSystem'], 'PERSISTED_SYNTHETIC');
    },
  );

  test(
    'logout during pending storage consent does not start the admitted script afterward',
    () async {
      final blobs = InMemoryBlobStore();
      final session = SessionController(blobStoreProvider: () async => blobs);
      addTearDown(session.dispose);
      await session.bootstrap();
      final package = _package(
        source: """
      export const capabilities={'notice.list':async(ctx)=>{
        await ctx.credentials.set('late','SYNTHETIC');return {items:[]};
      }};
    """,
      );
      await _install(session, package);
      await session.selectTrustedScriptSchool(package.manifest.id);
      final entered = Completer<void>();
      final consent = Completer<bool>();
      session.scriptStorageConsent = () {
        entered.complete();
        return consent.future;
      };
      final running = session.runCapability('notice.list');
      await entered.future;
      session.logout();
      consent.complete(true);
      expect((await running).ok, isFalse);
      expect(session.credentialRefs, isEmpty);
    },
  );

  test(
    'corrupt optional script registry grants no code and explicit reimport recovers',
    () async {
      final blobs = InMemoryBlobStore();
      await blobs.write(
        'trusted-scripts.json',
        utf8.encode('{malformed registry'),
      );
      final session = SessionController(
        blobStoreProvider: () async => blobs,
        initialSchools: [testSchool()],
      );
      await session.bootstrap();
      expect(session.scriptRegistryRecovered, isTrue);
      expect((await session.scriptRegistry).installations, isEmpty);
      expect(session.availableSchools.single.id, 'xidian');
      session.selectSchool(session.availableSchools.single);
      final legacy = await session.runCapability('notice.list');
      expect(
        legacy.ok,
        isFalse,
        reason:
            'No legacy service is injected, but optional corruption must not throw',
      );
      final package = _package();
      await _install(session, package);
      await session.selectTrustedScriptSchool(package.manifest.id);
      expect((await session.runCapability('notice.list')).ok, isTrue);
      await session.flush();
      session.dispose();
      final restored = SessionController(
        blobStoreProvider: () async => blobs,
        initialSchools: [testSchool()],
      );
      addTearDown(restored.dispose);
      await restored.bootstrap();
      expect(restored.scriptRegistryRecovered, isFalse);
      expect(
        restored.availableSchools.map((school) => school.id),
        containsAll(['xidian', 'example']),
      );
      expect(
        (await restored.scriptRegistry)
            .find(package.manifest.id)
            ?.package
            .digest,
        package.digest,
      );
    },
  );

  test(
    'real host fetch exposes Set-Cookie and script uses stored value for the next request',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final cookies = <String?>[];
      server.listen((request) {
        if (request.uri.path == '/login') {
          request.response.headers.add(
            HttpHeaders.setCookieHeader,
            'sid=SYNTHETIC_LOGIN; HttpOnly; Path=/',
          );
          request.response.write('signed in');
        } else {
          cookies.add(request.headers.value(HttpHeaders.cookieHeader));
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({'title': 'Authenticated local data'}),
          );
        }
        unawaited(request.response.close());
      });
      final origin = 'http://127.0.0.1:${server.port}';
      final package = _package(
        network: {
          'origins': [origin],
          'ipAllow': ['127.0.0.1/32'],
        },
        source:
            """
      export const capabilities={'notice.list':async(ctx)=>{try {
        const login=await ctx.fetch('$origin/login',{redirect:'manual'});
        const cookie=login.headers.getSetCookie()[0].split(';')[0];
        await ctx.credentials.set('session',cookie,{type:'cookie'});
        const saved=await ctx.credentials.get('session');
        const data=await (await ctx.fetch('$origin/private',{headers:{Cookie:saved.value}})).json();
        return {items:[{id:'auth',title:data.title,category:'academic',source:'Synthetic host'}]};
      }catch(e){ctx.log('error',String(e));throw e;}}};
    """,
      );
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      await _install(session, package);
      await session.selectTrustedScriptSchool(package.manifest.id);
      final logs = <String>[];
      final result = await session.runCapability(
        'notice.list',
        onLog: (_, message) => logs.add(message),
      );
      expect(result.ok, isTrue, reason: '${result.reason} $logs');
      expect(cookies, ['sid=SYNTHETIC_LOGIN']);
      expect(
        (result.data as Map)['items'][0]['title'],
        'Authenticated local data',
      );
    },
  );
}
