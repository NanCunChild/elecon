import 'dart:async';
import 'dart:convert';
import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/profile_controller.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/profile_fixture.dart';

SessionController session(BlobStore? blobs) =>
    SessionController(blobStoreProvider: () async => blobs);
ProfileController profiles(BlobStore blobs) => ProfileController(
  blobStoreProvider: () async => blobs,
  createSession: session,
);
Future<void> install(SessionController s) async {
  final p = school();
  await s.installTrustedScript(p, approvedDigest: p.digest);
  await s.selectTrustedScriptSchool(p.manifest.id);
  await s.ensurePersistentStore(confirmSoftwareFallback: () async => true);
}

Future<String> query(SessionController s, [String? value]) async {
  final run = await s.runCapability('notice.list', params: {'value': ?value});
  expect(run.ok, isTrue, reason: run.reason);
  return (run.data as Map)['sourceSystem'] as String;
}

class FailingIndex extends InMemoryBlobStore {
  bool fail = false;
  @override
  Future<void> write(String name, List<int> bytes) async {
    if (fail && name == 'profiles.json') {
      throw StateError('synthetic disk error');
    }
    await super.write(name, bytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'migrate legacy root; same school accounts, caches and installs survive restart independently',
    () async {
      final blobs = InMemoryBlobStore();
      final legacy = session(blobs);
      await legacy.bootstrap();
      await install(legacy);
      expect(await query(legacy, 'SYNTHETIC_ALPHA'), 'SYNTHETIC_ALPHA');
      await legacy.flush();
      legacy.dispose();

      final controller = profiles(blobs);
      await controller.bootstrap();
      expect(controller.active.id, 'default');
      final alpha = controller.active.session;
      expect(alpha.isLoggedIn, isTrue);
      expect(await query(alpha), 'SYNTHETIC_ALPHA');
      await controller.add();
      final betaId = controller.active.id;
      final beta = controller.active.session;
      expect(beta.selectedSchool, isNull);
      expect(beta.isLoggedIn, isFalse);
      expect((await beta.scriptRegistry).installations, isEmpty);
      await install(beta);
      expect(await query(beta), 'EMPTY');
      expect(await query(beta, 'SYNTHETIC_BETA'), 'SYNTHETIC_BETA');
      expect(
        (await alpha.latestCachedCapability('notice.list'))!.data,
        isNot((await beta.latestCachedCapability('notice.list'))!.data),
      );
      await controller.activate('default');
      expect(await query(alpha), 'SYNTHETIC_ALPHA');
      await controller.activate(betaId);
      controller.dispose();

      final restarted = profiles(blobs);
      addTearDown(restarted.dispose);
      await restarted.bootstrap();
      expect(restarted.active.id, betaId);
      expect(restarted.profiles, hasLength(2));
      expect(await query(restarted.active.session), 'SYNTHETIC_BETA');
      restarted.active.session.logout();
      await restarted.active.session.flush();
      expect(restarted.active.session.isLoggedIn, isFalse);
      await restarted.activate('default');
      expect(await query(restarted.active.session), 'SYNTHETIC_ALPHA');
    },
  );

  test('index failures do not add or activate a Profile', () async {
    final blobs = FailingIndex();
    final controller = profiles(blobs);
    addTearDown(controller.dispose);
    await controller.bootstrap();
    blobs.fail = true;
    await expectLater(controller.add(), throwsStateError);
    expect(controller.profiles, hasLength(1));
    expect(controller.active.id, 'default');
    expect(controller.busy, isFalse);
    blobs.fail = false;
    await controller.add();
    final id = controller.active.id;
    blobs.fail = true;
    await expectLater(controller.activate('default'), throwsStateError);
    expect(controller.active.id, id);
  });

  test(
    'corrupt index fails closed and does not reinterpret legacy credentials',
    () async {
      final blobs = InMemoryBlobStore();
      await blobs.write(
        'profiles.json',
        utf8.encode('{"version":99,"profiles":[]}'),
      );
      final controller = profiles(blobs);
      addTearDown(controller.dispose);
      await expectLater(controller.bootstrap(), throwsFormatException);
      expect(controller.active.session.isLoggedIn, isFalse);
    },
  );

  test(
    'switching revokes an in-flight input and rejects its late result',
    () async {
      final controller = profiles(InMemoryBlobStore());
      addTearDown(controller.dispose);
      await controller.bootstrap();
      await controller.add();
      await controller.activate('default');
      final old = controller.active.session;
      final raw = jsonDecode(school().encode()) as Map<String, dynamic>;
      raw['source'] = '''export const capabilities={'notice.list':async(ctx)=>{
      const r=await ctx.ui.requestInput({title:'Synthetic',fields:[{id:'value',label:'Value'}]});
      await ctx.credentials.set('session',r.value); return {items:[]};
    }};''';
      final p = ScriptPackage.parse(jsonEncode(raw));
      await old.installTrustedScript(p, approvedDigest: p.digest);
      await old.selectTrustedScriptSchool(p.manifest.id);
      await old.ensurePersistentStore(
        confirmSoftwareFallback: () async => true,
      );
      final opened = Completer<void>();
      final answer = Completer<Object?>();
      old.scriptInputPresenter = (_, execute) => execute((_) {
        opened.complete();
        return answer.future;
      });
      final pending = old.runCapability('notice.list');
      await opened.future;
      await controller.activate(controller.profiles.last.id);
      answer.complete({'value': 'SYNTHETIC_LATE'});
      expect((await pending).ok, isFalse);
      expect(old.isLoggedIn, isFalse);
      expect(controller.active.session.isLoggedIn, isFalse);
    },
  );
}
