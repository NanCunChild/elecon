import 'dart:convert';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/registry.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage package({
  String version = '1.0.0',
  String school = 'school-a',
  String source = 'export const capabilities = {};',
  String id = 'example',
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 1,
      'id': id,
      'version': version,
      'schoolId': school,
      'name': 'Synthetic School',
      'network': {'origins': []},
      'browser': false,
      'capabilities': [
        {
          'id': 'notice.list',
          'schema': 'elecon.notice.list',
          'schemaVersion': '1.1',
        },
      ],
    },
    'source': source,
  }),
);

class FailingBlobs extends InMemoryBlobStore {
  bool fail = false;
  @override
  Future<void> write(String name, List<int> bytes) async {
    if (fail) throw StateError('synthetic_write_failure');
    await super.write(name, bytes);
  }
}

void main() {
  test(
    'install requires consent for exact content, parsing never runs source',
    () async {
      final registry = await ScriptRegistry.open(null);
      final script = package(
        source: 'throw new Error("must not run on install")',
      );
      await expectLater(
        registry.install(script, approvedDigest: 'other'),
        throwsStateError,
      );
      expect(registry.installations, isEmpty);
      await registry.install(script, approvedDigest: script.digest);
      expect(registry.find('example')!.package.digest, script.digest);
      expect(registry.provider('school-b', 'notice.list'), isNull);
    },
  );

  test(
    'updates are monotonic and bind school; identical imports are idempotent',
    () async {
      final registry = await ScriptRegistry.open(null);
      Future<void> install(ScriptPackage p) =>
          registry.install(p, approvedDigest: p.digest);
      final initial = package(version: '1.9.0');
      await install(initial);
      await install(initial);
      await install(package(version: '1.10.0'));
      await expectLater(install(initial), throwsStateError);
      await expectLater(
        install(package(version: '1.10.0', source: 'different')),
        throwsStateError,
      );
      await expectLater(
        install(package(version: '2.0.0', school: 'other')),
        throwsStateError,
      );
      expect(registry.find('example')!.package.manifest.version, '1.10.0');
    },
  );

  test(
    'serialized writes survive a failure without changing active package',
    () async {
      final blobs = FailingBlobs();
      final registry = await ScriptRegistry.open(blobs);
      final first = package();
      await registry.install(first, approvedDigest: first.digest);
      final epoch = registry.epoch;
      blobs.fail = true;
      final next = package(version: '2.0.0');
      await expectLater(
        registry.install(next, approvedDigest: next.digest),
        throwsStateError,
      );
      expect(registry.epoch, epoch);
      expect(registry.find('example')!.package.digest, first.digest);
      blobs.fail = false;
      await registry.install(next, approvedDigest: next.digest);
      expect(
        (await ScriptRegistry.open(blobs)).find('example')!.package.digest,
        next.digest,
      );
    },
  );

  test('disable/remove persist across restart and invalidate grants', () async {
    final blobs = InMemoryBlobStore();
    final registry = await ScriptRegistry.open(blobs);
    final script = package();
    await registry.install(script, approvedDigest: script.digest);
    final epoch = registry.epoch;
    await registry.setEnabled('example', false);
    expect(registry.epoch, greaterThan(epoch));
    expect(registry.provider('school-a', 'notice.list'), isNull);
    final restored = await ScriptRegistry.open(blobs);
    expect(restored.find('example')!.enabled, false);
    await restored.remove('example');
    expect((await ScriptRegistry.open(blobs)).installations, isEmpty);
  });

  test(
    'changed stored package bytes cannot inherit prior digest trust',
    () async {
      final blobs = InMemoryBlobStore();
      final registry = await ScriptRegistry.open(blobs);
      final script = package();
      await registry.install(script, approvedDigest: script.digest);
      final raw =
          jsonDecode(utf8.decode((await blobs.read('trusted-scripts.json'))!))
              as Map;
      final entries = raw['entries'] as List;
      entries.first['package'] = package(source: 'changed').encode();
      await blobs.write('trusted-scripts.json', utf8.encode(jsonEncode(raw)));
      await expectLater(ScriptRegistry.open(blobs), throwsFormatException);
    },
  );

  test(
    'most recently installed enabled provider wins without hiding other capabilities',
    () async {
      final registry = await ScriptRegistry.open(null);
      final first = package(id: 'first');
      final second = package(id: 'second');
      await registry.install(first, approvedDigest: first.digest);
      await registry.install(second, approvedDigest: second.digest);
      expect(
        registry.provider('school-a', 'notice.list')!.manifest.id,
        'second',
      );
      await registry.setEnabled('second', false);
      expect(
        registry.provider('school-a', 'notice.list')!.manifest.id,
        'first',
      );
    },
  );
}
