import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:elecon/core/debug/debug_adapter_inbox.dart';
import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/scripts/registry.dart';
import 'package:elecon/session/profile_controller.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'scripts/registry_test.dart' as fixture;

final class _GatedCommandRead extends IOOverrides {
  final entered = Completer<void>();
  final resume = Completer<void>();

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path.contains('/processing/') && path.endsWith('.json')
        ? _GatedFile(file, this)
        : file;
  }
}

class _GatedFile implements File {
  _GatedFile(this.file, this.gate);
  final File file;
  final _GatedCommandRead gate;

  @override
  String get path => file.path;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<int> length() => file.length();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);
  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    final text = await file.readAsString(encoding: encoding);
    gate.entered.complete();
    await gate.resume.future;
    return text;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('elecon-debug-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'Debug allows explicit same-version replacement without an environment flag',
    () async {
      final registry = await ScriptRegistry.open(null);
      final original = fixture.package();
      final replacement = fixture.package(
        source: 'export const capabilities = {changed:true};',
      );
      await registry.install(original, approvedDigest: original.digest);
      await expectLater(
        registry.install(replacement, approvedDigest: replacement.digest),
        throwsStateError,
      );
      if (kDebugMode) {
        await registry.install(
          replacement,
          approvedDigest: replacement.digest,
          debugReplace: true,
        );
        expect(registry.find('example')!.package.digest, replacement.digest);
      } else {
        await expectLater(
          registry.install(
            replacement,
            approvedDigest: replacement.digest,
            debugReplace: true,
          ),
          throwsStateError,
        );
      }
      for (final rejected in [
        fixture.package(version: '0.9.0'),
        fixture.package(school: 'other'),
      ]) {
        await expectLater(
          registry.install(
            rejected,
            approvedDigest: rejected.digest,
            debugReplace: true,
          ),
          throwsStateError,
        );
      }
      await expectLater(
        registry.install(
          replacement,
          approvedDigest: 'wrong',
          debugReplace: true,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'inbox isolates identity, validates bytes, replaces and removes without execution',
    () async {
      final blobs = InMemoryBlobStore();
      final profiles = ProfileController(
        blobStoreProvider: () async => blobs,
        createSession: (storage) =>
            SessionController(blobStoreProvider: () async => storage),
      );
      await profiles.bootstrap();
      final inbox = DebugAdapterInbox(root, profiles);
      addTearDown(() {
        inbox.close();
        profiles.dispose();
      });
      await inbox.start();
      if (!kDebugMode) {
        expect(await File('${root.path}/status.json').exists(), isFalse);
        return;
      }
      var sequence = 0;
      Future<String> command(Map<String, Object?> fields) async {
        final id = (++sequence).toRadixString(16).padLeft(32, '0');
        await File('${root.path}/inbox/$id.json').writeAsString(
          jsonEncode({'version': 1, 'profileId': 'default', ...fields}),
        );
        await inbox.poll();
        return (jsonDecode(
                  await File('${root.path}/results/$id.json').readAsString(),
                )
                as Map)['result']
            as String;
      }

      final original = fixture.package(
        source: 'throw new Error("must never execute on install")',
      );
      final replacement = fixture.package(
        source: 'throw new Error("replacement must not execute")',
      );
      Map<String, Object?> upload(String text) => {
        'operation': 'upsert',
        'package': text,
        'sha256': sha256.convert(utf8.encode(text)).toString(),
      };
      expect(
        await command({...upload(original.encode()), 'profileId': 'other'}),
        'debug_command_identity',
      );
      expect(
        await command({...upload(original.encode()), 'sha256': 'wrong'}),
        'debug_command_digest',
      );
      final registry = await profiles.active.session.scriptRegistry;
      expect(registry.installations, isEmpty);
      expect(await command(upload('not a package')), 'debug_command_rejected');
      expect(await command(upload(original.encode())), 'ok');
      await registry.setEnabled('example', false);
      final generation = profiles.active.session.trustedScriptViewGeneration;
      expect(await command(upload(replacement.encode())), 'ok');
      expect(registry.find('example')!.package.digest, replacement.digest);
      expect(registry.find('example')!.enabled, isFalse);
      expect(
        (await ScriptRegistry.open(blobs)).find('example')!.package.digest,
        replacement.digest,
      );
      expect(
        profiles.active.session.trustedScriptViewGeneration,
        greaterThan(generation),
      );
      expect(
        await command({'operation': 'execute', 'packageId': 'example'}),
        'debug_command_operation',
      );
      final interrupted = 'f' * 32;
      await File(
        '${root.path}/processing/$interrupted.json',
      ).writeAsString('{}');
      await File('${root.path}/inbox/$interrupted.json').writeAsString(
        jsonEncode({
          'version': 1,
          'profileId': 'default',
          'operation': 'remove',
          'packageId': 'example',
        }),
      );
      await inbox.poll();
      expect(registry.find('example'), isNotNull);
      expect(
        await command({'operation': 'remove', 'packageId': 'example'}),
        'ok',
      );
      expect(registry.installations, isEmpty);
    },
  );

  for (final operation in ['upsert', 'remove']) {
    for (final revocation in ['background', 'background-resume', 'close']) {
      test(
        '$operation rejects $revocation during command read without replay',
        () async {
          final profiles = ProfileController(
            createSession: (_) => SessionController(),
          );
          await profiles.bootstrap();
          final inbox = DebugAdapterInbox(root, profiles);
          addTearDown(() {
            inbox.close();
            profiles.dispose();
          });
          final package = fixture.package();
          if (operation == 'remove') {
            await profiles.active.session.installTrustedScript(
              package,
              approvedDigest: package.digest,
            );
          }
          final registry = await profiles.active.session.scriptRegistry;
          final epoch = registry.epoch;
          await inbox.start();
          final text = package.encode();
          final id = 'a' * 32;
          await File('${root.path}/inbox/$id.json').writeAsString(
            jsonEncode({
              'version': 1,
              'profileId': profiles.active.id,
              'operation': operation,
              if (operation == 'upsert') ...{
                'package': text,
                'sha256': sha256.convert(utf8.encode(text)).toString(),
              } else
                'packageId': package.manifest.id,
            }),
          );
          final gate = _GatedCommandRead();
          final polling = IOOverrides.runWithIOOverrides(inbox.poll, gate);
          await gate.entered.future.timeout(const Duration(seconds: 3));
          if (revocation == 'close') {
            inbox.close();
          } else {
            inbox.foreground = false;
            if (revocation == 'background-resume') inbox.foreground = true;
          }
          gate.resume.complete();
          await polling;
          final result = jsonDecode(
            await File('${root.path}/results/$id.json').readAsString(),
          );
          expect(result['result'], 'script_cancelled');
          expect(registry.epoch, epoch);
          expect(registry.find('example') != null, operation == 'remove');
          expect(
            await File('${root.path}/processing/$id.json').exists(),
            isFalse,
          );
          inbox.foreground = true;
          await inbox.poll();
          expect(registry.epoch, epoch);
        },
      );
    }
  }
}
