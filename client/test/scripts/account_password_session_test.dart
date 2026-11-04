import 'dart:async';
import 'dart:convert';
import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/software_secure_store.dart';
import 'package:elecon/core/scripts/account_auth.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'account_password_test.dart' show passwordPackage;

class GatedPasswordBlobs extends InMemoryBlobStore {
  Completer<void>? entered;
  Completer<void>? gate;
  @override
  Future<void> write(String name, List<int> bytes) async {
    if (name == 'store.enc' && gate != null) {
      final wait = gate!;
      gate = null;
      entered?.complete();
      await wait.future;
    }
    await super.write(name, bytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final transition in ['logout', 'switchSchool', 'revokePackage']) {
    test(
      'password commit interrupted by $transition cannot persist late new secret',
      () async {
        final blobs = GatedPasswordBlobs();
        final session = SessionController(blobStoreProvider: () async => blobs);
        addTearDown(session.dispose);
        final p = passwordPackage(
          source: '''export const capabilities={'account.session':async ctx=>{
        const pair=await ctx.accounts.password('school',{mode:'manual'});
        await ctx.accounts.completePassword('school',{attemptId:pair.attemptId,outcome:'authenticated'});
        return {status:'authenticated'};
      }};''',
        );
        final raw = jsonDecode(p.encode()) as Map<String, dynamic>;
        (raw['manifest'] as Map)['id'] = 'synthetic.other';
        (raw['manifest'] as Map)['schoolId'] = 'other';
        final other = ScriptPackage.parse(jsonEncode(raw));
        await session.installTrustedScript(p, approvedDigest: p.digest);
        await session.installTrustedScript(other, approvedDigest: other.digest);
        await session.selectTrustedScriptSchool(p.manifest.id);
        await session.ensurePersistentStore(
          confirmSoftwareFallback: () async => true,
        );
        session.scriptStorageConsent = () async => true;
        final prior = await session.runTrustedScript(
          p.manifest.id,
          'account.session',
          expectedDigest: p.digest,
          params: const {'account': 'school', 'operation': 'login'},
          passwordCall: (_) async => const ScriptPasswordInput(
            username: 'EXAMPLE_OLD',
            password: 'EXAMPLE_OLD_PASSWORD',
            remember: true,
          ),
        );
        expect(prior.ok, isTrue);
        final wait = Completer<void>();
        blobs.gate = wait;
        blobs.entered = Completer<void>();
        final operation = session.runTrustedScript(
          p.manifest.id,
          'account.session',
          expectedDigest: p.digest,
          params: const {'account': 'school', 'operation': 'login'},
          passwordCall: (_) async => const ScriptPasswordInput(
            username: 'EXAMPLE_NEW',
            password: 'EXAMPLE_NEW_PASSWORD',
            remember: true,
          ),
        );
        await blobs.entered!.future;
        if (transition == 'logout') {
          session.logout();
        } else if (transition == 'switchSchool') {
          await session.selectTrustedScriptSchool(other.manifest.id);
        } else {
          await session.enableTrustedScript(p.manifest.id, false);
        }
        wait.complete();
        final result = await operation;
        expect(result.ok, isFalse);
        final persisted = await SoftwareSecureStore.open(blobs);
        final values = persisted
            .list()
            .where((entry) => entry.type == ScriptAccountStore.type)
            .toList();
        if (transition == 'logout') {
          expect(values, isEmpty);
        } else {
          expect(values, hasLength(1));
          expect(values.single.value, contains('EXAMPLE_OLD_PASSWORD'));
          expect(values.single.value, isNot(contains('EXAMPLE_NEW_PASSWORD')));
        }
        expect(session.scriptAccountEvent(p, 'school'), isNull);
      },
    );
  }
}
