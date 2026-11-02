import 'dart:async';
import 'dart:convert';
import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/profile_controller.dart';
import 'package:elecon/ui/home/campus_snapshot_loader.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/profile_fixture.dart';

class CountingSession extends SessionController {
  int boots = 0;
  @override
  Future<void> bootstrap() async {
    boots++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'restored script desktop avoids distribution and query execution',
    () async {
      final blobs = InMemoryBlobStore();
      final raw = jsonDecode(school().encode()) as Map<String, dynamic>;
      (raw['manifest'] as Map).remove('home');
      raw['source'] =
          "export const capabilities={'notice.list':async(ctx)=>{await ctx.credentials.set('executed','yes');return {items:[]};}}";
      final p = ScriptPackage.parse(jsonEncode(raw));
      final previous = SessionController(blobStoreProvider: () async => blobs);
      await previous.bootstrap();
      await previous.installTrustedScript(p, approvedDigest: p.digest);
      await previous.selectTrustedScriptSchool(p.manifest.id);
      await previous.flush();
      previous.dispose();
      var catalogLoads = 0;
      final session = SessionController(
        blobStoreProvider: () async => blobs,
        adapterServiceProvider: () async {
          catalogLoads++;
          return null;
        },
      );
      addTearDown(session.dispose);
      await session.bootstrap();
      final snapshot = await loadCampusSnapshot(session, preferCacheOnly: true);
      expect(snapshot.supportedCapabilities, contains('notice.list'));
      expect(snapshot.notices, isNull);
      expect(session.credentialRefs, isEmpty);
      expect(catalogLoads, 0);
    },
  );
  test('bootstrap callers share the same pending restoration', () async {
    final storage = Completer<BlobStore?>();
    var opens = 0;
    final session = SessionController(
      blobStoreProvider: () {
        opens++;
        return storage.future;
      },
    );
    addTearDown(session.dispose);
    final first = session.bootstrap();
    final second = session.bootstrap();
    expect(identical(first, second), isTrue);
    expect(opens, 1);
    var done = false;
    second.then((_) => done = true);
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse);
    storage.complete(null);
    await first;
    expect(done, isTrue);
  });
  test(
    'only active profile boots; other profiles restore on selection',
    () async {
      final blobs = InMemoryBlobStore();
      const secondId = '11111111111111111111111111111111';
      await blobs.write(
        'profiles.json',
        utf8.encode(
          jsonEncode({
            'version': 1,
            'activeId': secondId,
            'profiles': [
              {'id': 'default', 'name': 'First'},
              {'id': secondId, 'name': 'Second'},
            ],
          }),
        ),
      );
      final profiles = ProfileController(
        blobStoreProvider: () async => blobs,
        createSession: (_) => CountingSession(),
      );
      addTearDown(profiles.dispose);
      await profiles.bootstrap();
      final first = profiles.profiles.first.session as CountingSession;
      final second = profiles.profiles.last.session as CountingSession;
      expect(first.boots, 0);
      expect(second.boots, 1);
      await profiles.activate('default');
      expect(first.boots, 1);
    },
  );
}
