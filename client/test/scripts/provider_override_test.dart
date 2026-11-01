import 'dart:convert';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/registry.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage package(
  String id, {
  String school = 'school-a',
  String version = '1.0.0',
  Map<String, String> capabilities = const {'notice.list': '1.1'},
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': capabilities.containsKey('climate.command') ? 5 : 2,
      'id': id,
      'version': version,
      'schoolId': school,
      'name': 'Synthetic School',
      'network': {
        'origins': [
          if (capabilities.containsKey('climate.command'))
            'https://device.example.invalid',
        ],
      },
      'browser': false,
      'capabilities': [
        for (final cap in capabilities.entries)
          {
            'id': cap.key,
            'schema': 'elecon.${cap.key}',
            'schemaVersion': cap.value,
          },
      ],
    },
    'source': 'export const capabilities = {};',
  }),
);

Future<void> install(ScriptRegistry registry, ScriptPackage p) =>
    registry.install(p, approvedDigest: p.digest);

Future<void> writeV1(InMemoryBlobStore blobs, List<ScriptPackage> packages) =>
    blobs.write(
      'trusted-scripts.json',
      utf8.encode(
        jsonEncode({
          'version': 1,
          'entries': [
            for (final p in packages)
              {'package': p.encode(), 'digest': p.digest, 'enabled': true},
          ],
        }),
      ),
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
    'approved base schema upgrade follows the same source across restart',
    () async {
      final blobs = InMemoryBlobStore();
      final registry = await ScriptRegistry.open(blobs);
      await install(
        registry,
        package('base', capabilities: {'schedule.week': '1.0'}),
      );
      final upgraded = package(
        'base',
        version: '1.1.0',
        capabilities: {'schedule.week': '1.1'},
      );
      await install(registry, upgraded);
      final restored = await ScriptRegistry.open(blobs);
      expect(
        restored.provider('school-a', 'schedule.week')?.digest,
        upgraded.digest,
      );
      expect(
        restored
            .baseProvider('school-a', 'schedule.week')
            ?.manifest
            .capability('schedule.week')
            ?.schemaVersion,
        '1.1',
      );
    },
  );

  test(
    'v2 stale binding is repaired without changing approval or explicit override',
    () async {
      final blobs = InMemoryBlobStore();
      final base = package('base', capabilities: {'schedule.week': '1.1'});
      final extra = package('extra', capabilities: {'schedule.week': '1.0'});
      await blobs.write(
        'trusted-scripts.json',
        utf8.encode(
          jsonEncode({
            'version': 2,
            'entries': [
              for (final p in [base, extra])
                {'package': p.encode(), 'digest': p.digest, 'enabled': true},
            ],
            'bindings': [
              {
                'schoolId': 'school-a',
                'capability': 'schedule.week',
                'baseId': 'base',
                'schema': 'elecon.schedule.week',
                'schemaVersion': '1.0',
                'overrideId': 'extra',
              },
            ],
          }),
        ),
      );
      final registry = await ScriptRegistry.open(blobs);
      expect(
        registry.baseProvider('school-a', 'schedule.week')?.digest,
        base.digest,
      );
      expect(
        registry.isProviderOverride('school-a', 'schedule.week', 'extra'),
        isTrue,
      );
      expect(registry.provider('school-a', 'schedule.week'), isNull);
      expect(
        registry.blocksLegacyFallback('school-a', 'schedule.week'),
        isTrue,
      );
      await registry.setProviderOverride('school-a', 'schedule.week', null);
      final restored = await ScriptRegistry.open(blobs);
      expect(
        restored.provider('school-a', 'schedule.week')?.digest,
        base.digest,
      );
      final stored =
          jsonDecode(utf8.decode((await blobs.read('trusted-scripts.json'))!))
              as Map;
      expect(stored['version'], 3);
      expect((stored['entries'] as List).first['package'], base.encode());
      expect((stored['entries'] as List).first['digest'], base.digest);
    },
  );

  test(
    'failed schema upgrade leaves the previous contract and installation intact',
    () async {
      final blobs = FailingBlobs();
      final registry = await ScriptRegistry.open(blobs);
      final original = package('base', capabilities: {'schedule.week': '1.0'});
      await install(registry, original);
      blobs.fail = true;
      await expectLater(
        install(
          registry,
          package(
            'base',
            version: '1.1.0',
            capabilities: {'schedule.week': '1.1'},
          ),
        ),
        throwsStateError,
      );
      expect(
        registry.provider('school-a', 'schedule.week')?.digest,
        original.digest,
      );
      expect(
        registry
            .find('base')
            ?.package
            .manifest
            .capability('schedule.week')
            ?.schemaVersion,
        '1.0',
      );
    },
  );

  test(
    'base upgrade preserves incompatible override selection until explicit removal',
    () async {
      final registry = await ScriptRegistry.open(null);
      await install(
        registry,
        package('base', capabilities: {'schedule.week': '1.0'}),
      );
      await install(
        registry,
        package('extra', capabilities: {'schedule.week': '1.0'}),
      );
      await registry.setProviderOverride('school-a', 'schedule.week', 'extra');
      await install(
        registry,
        package(
          'base',
          version: '1.1.0',
          capabilities: {'schedule.week': '1.1'},
        ),
      );
      expect(
        registry.isProviderOverride('school-a', 'schedule.week', 'extra'),
        isTrue,
      );
      expect(registry.provider('school-a', 'schedule.week'), isNull);
      await registry.setProviderOverride('school-a', 'schedule.week', null);
      expect(
        registry.provider('school-a', 'schedule.week')?.manifest.id,
        'base',
      );
      await registry.setEnabled('base', false);
      expect(registry.provider('school-a', 'schedule.week'), isNull);
    },
  );

  test('disabling a base does not promote an unselected candidate', () async {
    final registry = await ScriptRegistry.open(null);
    await install(registry, package('base'));
    await install(registry, package('candidate'));
    await registry.setEnabled('base', false);
    expect(registry.provider('school-a', 'notice.list'), isNull);
    await registry.setProviderOverride('school-a', 'notice.list', 'candidate');
    expect(
      registry.provider('school-a', 'notice.list')!.manifest.id,
      'candidate',
    );
    await registry.setProviderOverride('school-a', 'notice.list', null);
    expect(registry.provider('school-a', 'notice.list'), isNull);
    await registry.remove('base');
    expect(registry.provider('school-a', 'notice.list'), isNull);
  });

  test(
    'explicit source persists and base updates cannot steal the selection',
    () async {
      final blobs = InMemoryBlobStore();
      final registry = await ScriptRegistry.open(blobs);
      await install(registry, package('base'));
      await install(registry, package('extra'));
      expect(registry.provider('school-a', 'notice.list')!.manifest.id, 'base');
      await registry.setProviderOverride('school-a', 'notice.list', 'extra');
      expect(
        registry.baseProvider('school-a', 'notice.list')!.manifest.id,
        'base',
      );
      await install(registry, package('base', version: '1.1.0'));
      final restored = await ScriptRegistry.open(blobs);
      expect(
        restored.provider('school-a', 'notice.list')!.manifest.id,
        'extra',
      );
      await restored.setEnabled('extra', false);
      expect(restored.provider('school-a', 'notice.list')!.manifest.id, 'base');
      await restored.setEnabled('extra', true);
      expect(
        restored.provider('school-a', 'notice.list')!.manifest.id,
        'extra',
      );
      await restored.remove('extra');
      expect(restored.provider('school-a', 'notice.list')!.manifest.id, 'base');
    },
  );

  test(
    'v1 migration preserves the actual source independently per capability',
    () async {
      final blobs = InMemoryBlobStore();
      await writeV1(blobs, [
        package(
          'first',
          capabilities: {'notice.list': '1.1', 'grades.list': '1.1'},
        ),
        package('second'),
      ]);
      final registry = await ScriptRegistry.open(blobs);
      expect(
        registry.provider('school-a', 'notice.list')!.manifest.id,
        'second',
      );
      expect(
        registry.provider('school-a', 'grades.list')!.manifest.id,
        'first',
      );
      await install(
        registry,
        package(
          'first',
          version: '1.1.0',
          capabilities: {'notice.list': '1.1', 'grades.list': '1.1'},
        ),
      );
      final restored = await ScriptRegistry.open(blobs);
      expect(
        restored.provider('school-a', 'notice.list')!.manifest.id,
        'second',
      );
      expect(
        restored.provider('school-a', 'grades.list')!.manifest.id,
        'first',
      );
      final raw =
          jsonDecode(utf8.decode((await blobs.read('trusted-scripts.json'))!))
              as Map;
      expect(raw['version'], 3);
    },
  );

  test(
    'cross-school disabled and undeclared selections are rejected',
    () async {
      final registry = await ScriptRegistry.open(null);
      await install(registry, package('base'));
      await install(registry, package('foreign', school: 'school-b'));
      await expectLater(
        registry.setProviderOverride('school-a', 'notice.list', 'foreign'),
        throwsStateError,
      );
      await registry.setEnabled('base', false);
      await expectLater(
        registry.setProviderOverride('school-a', 'notice.list', 'base'),
        throwsStateError,
      );
      await expectLater(
        registry.setProviderOverride('school-a', 'grades.list', 'base'),
        throwsStateError,
      );
    },
  );

  test(
    'notice selection is atomic and legacy mixed detail stays unavailable',
    () async {
      const notices = {'notice.list': '1.1', 'notice.detail': '1.0'};
      final registry = await ScriptRegistry.open(null);
      final base = package('base', capabilities: notices);
      final listOnly = package('list-only');
      await install(registry, base);
      await install(registry, listOnly);
      await install(registry, package('extra', capabilities: notices));
      await expectLater(
        registry.setProviderOverride('school-a', 'notice.list', 'list-only'),
        throwsStateError,
      );
      expect(registry.provider('school-a', 'notice.list')!.manifest.id, 'base');
      await registry.setProviderOverride('school-a', 'notice.list', 'extra');
      expect(
        registry.provider('school-a', 'notice.detail')!.manifest.id,
        'extra',
      );
      await registry.setProviderOverride('school-a', 'notice.detail', null);
      expect(registry.provider('school-a', 'notice.list')!.manifest.id, 'base');
      expect(
        registry.provider('school-a', 'notice.detail')!.manifest.id,
        'base',
      );

      final blobs = InMemoryBlobStore();
      await writeV1(blobs, [base, listOnly]);
      final migrated = await ScriptRegistry.open(blobs);
      expect(
        migrated.provider('school-a', 'notice.list')!.manifest.id,
        'list-only',
      );
      expect(migrated.provider('school-a', 'notice.detail'), isNull);
      expect(
        migrated.blocksLegacyFallback('school-a', 'notice.detail'),
        isTrue,
      );
    },
  );

  for (final group in [
    ['classroom.buildings', 'classroom.available'],
    ['energy.meters', 'energy.usage'],
    ['climate.devices', 'climate.status', 'climate.command'],
  ]) {
    test(
      '${group.first} keeps entity consumers on the discovery source',
      () async {
        final capabilities = {
          for (final cap in group)
            cap: cap == 'classroom.available' ? '1.1' : '1.0',
        };
        final registry = await ScriptRegistry.open(null);
        final base = package('base', capabilities: capabilities);
        final extra = package('extra', capabilities: capabilities);
        final discoveryOnly = package(
          'discovery-only',
          capabilities: {group.first: '1.0'},
        );
        await install(registry, base);
        await install(registry, extra);
        await install(registry, discoveryOnly);
        await expectLater(
          registry.setProviderOverride(
            'school-a',
            group.first,
            'discovery-only',
          ),
          throwsStateError,
        );
        await registry.setProviderOverride('school-a', group.last, 'extra');
        for (final cap in group) {
          expect(registry.provider('school-a', cap)!.manifest.id, 'extra');
        }
        await registry.setProviderOverride('school-a', group.first, null);
        for (final cap in group) {
          expect(registry.provider('school-a', cap)!.manifest.id, 'base');
        }
        final blobs = InMemoryBlobStore();
        await writeV1(blobs, [base, discoveryOnly]);
        final migrated = await ScriptRegistry.open(blobs);
        expect(
          migrated.provider('school-a', group.first)!.manifest.id,
          'discovery-only',
        );
        for (final cap in group.skip(1)) {
          expect(migrated.provider('school-a', cap), isNull);
          expect(migrated.blocksLegacyFallback('school-a', cap), isTrue);
        }
      },
    );
  }

  test('failed storage preserves the active source and can recover', () async {
    final blobs = FailingBlobs();
    final registry = await ScriptRegistry.open(blobs);
    await install(registry, package('base'));
    await install(registry, package('extra'));
    final epoch = registry.epoch;
    blobs.fail = true;
    await expectLater(
      registry.setProviderOverride('school-a', 'notice.list', 'extra'),
      throwsStateError,
    );
    expect(registry.epoch, epoch);
    expect(registry.provider('school-a', 'notice.list')!.manifest.id, 'base');
    blobs.fail = false;
    await registry.setProviderOverride('school-a', 'notice.list', 'extra');
    expect(registry.provider('school-a', 'notice.list')!.manifest.id, 'extra');
  });

  test(
    'incompatible updates cannot inherit a selected output contract',
    () async {
      final registry = await ScriptRegistry.open(null);
      await install(
        registry,
        package('base', capabilities: {'energy.usage': '1.0'}),
      );
      await install(
        registry,
        package('extra', capabilities: {'energy.usage': '1.0'}),
      );
      await registry.setProviderOverride('school-a', 'energy.usage', 'extra');
      await install(
        registry,
        package(
          'extra',
          version: '1.1.0',
          capabilities: {'energy.usage': '1.1'},
        ),
      );
      expect(registry.provider('school-a', 'energy.usage'), isNull);
      expect(registry.blocksLegacyFallback('school-a', 'energy.usage'), isTrue);
      await expectLater(
        registry.setProviderOverride('school-a', 'energy.usage', 'extra'),
        throwsStateError,
      );
      await registry.setProviderOverride('school-a', 'energy.usage', null);
      expect(
        registry.provider('school-a', 'energy.usage')!.manifest.id,
        'base',
      );
    },
  );

  test(
    'stored cross-school binding is rejected before it can select a source',
    () async {
      final blobs = InMemoryBlobStore();
      final registry = await ScriptRegistry.open(blobs);
      await install(registry, package('base'));
      await install(registry, package('foreign', school: 'school-b'));
      final raw =
          jsonDecode(utf8.decode((await blobs.read('trusted-scripts.json'))!))
              as Map;
      (raw['bindings'] as List).first['overrideId'] = 'foreign';
      await blobs.write('trusted-scripts.json', utf8.encode(jsonEncode(raw)));
      await expectLater(ScriptRegistry.open(blobs), throwsFormatException);
    },
  );
}
