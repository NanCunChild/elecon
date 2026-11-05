// ADR-046: ordinary commands, target validation and retired-install migration.
import 'dart:convert';
import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/registry.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/home/climate_controls.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/climate_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('missing unrelated capability metadata does not block power', () {
    final device = <String, dynamic>{
      'deviceId': syntheticDeviceId,
      'label': 'Power only',
      'commands': ['power'],
    };
    final status = {'deviceId': syntheticDeviceId, 'power': false};
    expect(climateCommandReady(device, status, 'power'), isTrue);
    expect(climateCommandReady(device, status, 'temperature'), isFalse);
    expect(climateTarget(device, 'power', true), {'power': true});
    expect(
      climateCommandReady(device, {
        'deviceId': 'other',
        'power': false,
      }, 'power'),
      isFalse,
    );
    for (final command in ['temperature', 'mode', 'fanSpeed']) {
      final unsupported = {
        ...device,
        'commands': [command],
      };
      expect(
        () => climateTarget(
          unsupported,
          command,
          command == 'temperature' ? 26 : 'auto',
        ),
        throwsA(isA<ClimateControlException>()),
      );
    }
  });
  test('unverified command output does not establish applied state', () {
    for (final status in ['accepted', 'applied', 'rejected', 'unknown']) {
      expect(
        climateCommandOutcome(ok: true, output: {'status': status}),
        status == 'applied' ? 'accepted' : status,
      );
    }
    expect(climateCommandOutcome(ok: false), 'unknown');
    expect(climateCommandOutcome(ok: true, output: {}), 'unknown');
  });
  test(
    'target normalization retains coupled effects and rejects invalid input',
    () {
      final device = syntheticClimateDevice();
      expect(climateTarget(device, 'mode', 'heat'), {
        'mode': 'heat',
        'targetTemperature': 23,
        'fanSpeed': 'auto',
        'turbo': false,
        'auxiliaryHeat': false,
        'indoorClean': false,
        'outdoorClean': false,
      });
      expect(climateTarget(device, 'power', false), {
        'power': false,
        'auxiliaryHeat': false,
        'indoorClean': false,
        'outdoorClean': false,
      });
      for (final value in [17, 33, 26.5]) {
        expect(
          () => climateTarget(device, 'temperature', value),
          throwsA(isA<ClimateControlException>()),
        );
      }
      expect(
        () => climateTarget(device, 'mode', 'unsafe'),
        throwsA(isA<ClimateControlException>()),
      );
    },
  );
  test(
    'session and workbench use ordinary command invocation without grants',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      final p = syntheticClimatePackage();
      await session.installTrustedScript(p, approvedDigest: p.digest);
      await session.selectTrustedScriptSchool(p.manifest.id);
      final params = {
        'deviceId': syntheticDeviceId,
        'command': 'power',
        'settings': {'power': true},
      };
      expect(
        (await session.runCapability(
          'climate.command',
          params: params,
          interactive: false,
        )).data,
        {'status': 'accepted'},
      );
      expect(
        (await session.runTrustedScript(
          p.manifest.id,
          'climate.command',
          params: params,
        )).ok,
        isTrue,
      );
    },
  );
  test(
    'retired installs retain bytes/digest and other packages until explicit update',
    () async {
      final raw =
          jsonDecode(syntheticClimatePackage().encode())
              as Map<String, dynamic>;
      (raw['manifest'] as Map)['actions'] = [
        {
          'capability': 'climate.command',
          'method': 'POST',
          'url': 'https://device.example.invalid/command',
        },
      ];
      final retired = ScriptPackage.restore(jsonEncode(raw));
      final other = syntheticClimatePackage(id: 'other-climate');
      final blobs = InMemoryBlobStore();
      await blobs.write(
        'trusted-scripts.json',
        utf8.encode(
          jsonEncode({
            'version': 1,
            'entries': [
              {
                'package': retired.encode(),
                'digest': retired.digest,
                'enabled': true,
              },
              {
                'package': other.encode(),
                'digest': other.digest,
                'enabled': true,
              },
            ],
          }),
        ),
      );
      var registry = await ScriptRegistry.open(blobs);
      expect(registry.installations, hasLength(2));
      expect(
        registry.find(retired.manifest.id)!.package.encode(),
        retired.encode(),
      );
      expect(
        registry.provider(retired.manifest.schoolId, 'climate.command'),
        isNull,
      );
      expect(
        registry.blocksLegacyFallback(
          retired.manifest.schoolId,
          'climate.command',
        ),
        isTrue,
      );
      expect(
        registry.provider(other.manifest.schoolId, 'climate.command')!.digest,
        other.digest,
      );
      await expectLater(
        registry.install(retired, approvedDigest: retired.digest),
        throwsStateError,
      );
      await registry.setEnabled(other.manifest.id, false);
      registry = await ScriptRegistry.open(blobs);
      expect(
        registry.find(retired.manifest.id)!.package.digest,
        retired.digest,
      );
      final updated = syntheticClimatePackage(version: '1.0.1');
      await registry.install(updated, approvedDigest: updated.digest);
      registry = await ScriptRegistry.open(blobs);
      expect(
        registry.provider(updated.manifest.schoolId, 'climate.command')!.digest,
        updated.digest,
      );
      expect(registry.find(other.manifest.id), isNotNull);
    },
  );
}
