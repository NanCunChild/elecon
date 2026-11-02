import 'dart:async';
import 'dart:typed_data';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class FailingBlobs implements BlobStore {
  final backing = InMemoryBlobStore();
  bool fail = false;
  @override
  Future<Uint8List?> read(String name) => backing.read(name);
  @override
  Future<void> delete(String name) => backing.delete(name);
  @override
  Future<void> write(String name, List<int> bytes) {
    if (fail && name == 'store.enc') throw StateError('synthetic_disk_failure');
    return backing.write(name, bytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'session binds message account before execution and denies all background chat',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      final package = chatPackage();
      await prepareChat(session, package);
      var sends = 0;
      final invalid = await session.runTrustedScript(
        package.manifest.id,
        'messages.send',
        params: {
          ...chatTarget,
          'accountId': 'wrong',
          'clientId': '123',
          'text': 'Synthetic',
        },
        onLog: (_, text) {
          if (text == 'synthetic_send_once') sends++;
        },
      );
      expect(invalid.reason, 'input_invalid_request');
      expect(sends, 0);
      for (final cap in [
        'messages.conversations',
        'messages.history',
        'messages.send',
      ]) {
        expect(
          (await session.runTrustedScript(
            package.manifest.id,
            cap,
            params: chatTarget,
            interactive: false,
          )).reason,
          'foreground_required',
        );
      }
    },
  );
  test(
    'cancelled late history never enters archive; local reads execute no scripts',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      final package = chatPackage();
      await prepareChat(session, package);
      final started = Completer<void>();
      final cancellation = ScriptRunCancellation();
      addTearDown(cancellation.dispose);
      final pending = session.runTrustedScript(
        package.manifest.id,
        'messages.history',
        params: {...chatTarget, 'cursor': 'wait'},
        cancellation: cancellation,
        onLog: (_, text) {
          if (text == 'synthetic_waiting') started.complete();
        },
      );
      await started.future.timeout(const Duration(seconds: 5));
      cancellation.cancel();
      expect((await pending).ok, isFalse);
      expect(
        (await session.messageArchive(
          package,
          conversationId: 'group-1',
          conversationKind: 'group',
        ))!.messages,
        isEmpty,
      );
      expect(
        (await session.runTrustedScript(
          package.manifest.id,
          'messages.history',
          params: chatTarget,
        )).ok,
        isTrue,
      );
      final view = await session.messageArchive(
        package,
        conversationId: 'group-1',
        conversationKind: 'group',
      );
      expect(view!.messages.single.content!.text, 'Synthetic homework summary');
    },
  );
  test(
    'logout, expiry, disabling and approved update clear archive access',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      final package = chatPackage();
      await prepareChat(session, package);
      Future<void> populate() async {
        expect(
          (await session.runTrustedScript(
            package.manifest.id,
            'messages.session',
            params: {'operation': 'login'},
          )).ok,
          isTrue,
        );
        expect(
          (await session.runTrustedScript(
            package.manifest.id,
            'messages.history',
            params: chatTarget,
          )).ok,
          isTrue,
        );
      }

      await populate();
      await session.runTrustedScript(
        package.manifest.id,
        'messages.session',
        params: {'operation': 'logout'},
      );
      expect(await session.messageArchive(package), isNull);
      await populate();
      final expired = await session.runTrustedScript(
        package.manifest.id,
        'messages.history',
        params: {...chatTarget, 'cursor': 'expired'},
      );
      expect(expired.reason, 'authentication_required');
      expect(await session.messageArchive(package), isNull);
      await populate();
      await session.enableTrustedScript(package.manifest.id, false);
      expect(await session.messageArchive(package), isNull);
      await session.enableTrustedScript(package.manifest.id, true);
      await session.selectTrustedScriptSchool(package.manifest.id);
      expect(await session.messageArchive(package), isNull);
      await populate();
      final updated = chatPackage(version: '2.0.0');
      await session.installTrustedScript(
        updated,
        approvedDigest: updated.digest,
      );
      expect(await session.messageArchive(package), isNull);
      expect(await session.messageArchive(updated), isNull);
    },
  );
  test('disk failure does not downgrade confirmed send or resend it', () async {
    final blobs = FailingBlobs();
    final session = SessionController(blobStoreProvider: () async => blobs)
      ..scriptStorageConsent = () async => true;
    addTearDown(session.dispose);
    final package = chatPackage();
    await prepareChat(session, package);
    blobs.fail = true;
    var sends = 0;
    final result = await session.runTrustedScript(
      package.manifest.id,
      'messages.send',
      params: {...chatTarget, 'clientId': '123', 'text': 'Synthetic outgoing'},
      onLog: (_, text) {
        if (text == 'synthetic_send_once') sends++;
      },
    );
    expect(result.ok, isTrue);
    expect((result.data as Map)['status'], 'sent');
    expect(result.localStorageFailed, isTrue);
    expect(sends, 1);
    blobs.fail = false;
  });
}
