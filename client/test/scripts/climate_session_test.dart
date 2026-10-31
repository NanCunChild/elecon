// ADR-040 session proof, fixed confirmation, cancellation and identity tests.
import 'dart:async';
import 'package:elecon/core/scripts/action.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/climate_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  test(
    'transport uncertainty is preserved until an independent observation',
    () {
      for (final status in ['accepted', 'applied', 'rejected', 'unknown']) {
        expect(
          climateCommandOutcome(
            requestStarted: true,
            ok: true,
            output: {'status': status},
          ),
          status == 'applied' ? 'accepted' : status,
        );
      }
      expect(climateCommandOutcome(requestStarted: true, ok: false), 'unknown');
      expect(
        climateCommandOutcome(
          requestStarted: false,
          ok: true,
          output: {'status': 'applied'},
        ),
        'rejected',
      );
    },
  );
  Future<SessionController> prepare() async {
    final session = SessionController();
    addTearDown(session.dispose);
    final p = syntheticClimatePackage();
    await session.installTrustedScript(p, approvedDigest: p.digest);
    await session.selectTrustedScriptSchool(p.manifest.id);
    expect((await session.runCapability('profile.me')).ok, isTrue);
    expect((await session.runCapability('climate.devices')).ok, isTrue);
    expect(
      (await session.runCapability(
        'climate.status',
        params: {'deviceId': syntheticDeviceId},
      )).ok,
      isTrue,
    );
    return session;
  }

  test(
    'normalization exposes complete mode/power effects and rejects unsupported values',
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
          throwsA(isA<ScriptActionException>()),
        );
      }
      expect(
        () => climateTarget(device, 'mode', 'unsafe'),
        throwsA(isA<ScriptActionException>()),
      );
    },
  );
  test(
    'unverified device and non-Android cannot obtain a reviewable action',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      await expectLater(
        session.prepareClimateCommand(syntheticDeviceId, 'power', true),
        throwsA(isA<ScriptActionException>()),
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await expectLater(
        session.prepareClimateCommand(syntheticDeviceId, 'power', true),
        throwsA(isA<ScriptActionException>()),
      );
    },
  );
  test(
    'cancelled confirmation and replay cannot run command or alter old state',
    () async {
      final session = await prepare();
      final request = await session.prepareClimateCommand(
        syntheticDeviceId,
        'power',
        true,
      );
      var confirmations = 0;
      final cancelled = await session.runClimateCommand(
        request,
        confirm: (_) async {
          confirmations++;
          return false;
        },
        isCurrent: () => true,
      );
      expect(cancelled.status, 'rejected');
      expect(cancelled.observed, isNull);
      final replay = await session.runClimateCommand(
        request,
        confirm: (_) async {
          confirmations++;
          return true;
        },
        isCurrent: () => true,
      );
      expect(replay.status, 'rejected');
      expect(confirmations, 1);
    },
  );
  test(
    'one pending action blocks a second confirmation for the same device',
    () async {
      final session = await prepare();
      final first = await session.prepareClimateCommand(
            syntheticDeviceId,
            'power',
            true,
          ),
          second = await session.prepareClimateCommand(
            syntheticDeviceId,
            'power',
            true,
          );
      final gate = Completer<bool>();
      var confirmations = 0;
      final pending = session.runClimateCommand(
        first,
        confirm: (_) async {
          confirmations++;
          return gate.future;
        },
        isCurrent: () => true,
      );
      final duplicate = await session.runClimateCommand(
        second,
        confirm: (_) async {
          confirmations++;
          return true;
        },
        isCurrent: () => true,
      );
      expect(duplicate.status, 'rejected');
      expect(confirmations, 1);
      gate.complete(false);
      expect((await pending).status, 'rejected');
    },
  );
  for (final change in ['logout', 'update', 'switch', 'dispose']) {
    test('confirmation is invalidated by $change', () async {
      final session = await prepare();
      final request = await session.prepareClimateCommand(
        syntheticDeviceId,
        'power',
        true,
      );
      final gate = Completer<bool>();
      final pending = session.runClimateCommand(
        request,
        confirm: (_) => gate.future,
        isCurrent: () => true,
      );
      if (change == 'logout') session.logout();
      if (change == 'update') {
        final p = syntheticClimatePackage(version: '1.0.1');
        await session.installTrustedScript(p, approvedDigest: p.digest);
      }
      if (change == 'switch') {
        final p = syntheticClimatePackage(id: 'other-climate');
        await session.installTrustedScript(p, approvedDigest: p.digest);
        await session.selectTrustedScriptSchool(p.manifest.id);
        expect((await session.runCapability('profile.me')).ok, isTrue);
      }
      if (change == 'dispose') {
        session.cancelTrustedScriptRuns();
      }
      gate.complete(true);
      final result = await pending;
      expect(result.status, 'rejected');
      expect(result.observed, isNull);
    });
  }
  test(
    'no-request script is rejected and followed by independent real-state read',
    () async {
      final session = await prepare();
      final request = await session.prepareClimateCommand(
        syntheticDeviceId,
        'power',
        true,
      );
      final result = await session.runClimateCommand(
        request,
        confirm: (_) async => true,
        isCurrent: () => true,
      );
      expect(result.status, 'rejected');
      expect(result.observed!.ok, isTrue);
      expect((result.observed!.data as Map)['power'], isFalse);
    },
  );
  test('caller leaving the page invalidates a confirmed operation', () async {
    final session = await prepare();
    final request = await session.prepareClimateCommand(
      syntheticDeviceId,
      'power',
      true,
    );
    var current = true;
    final result = await session.runClimateCommand(
      request,
      confirm: (_) async {
        current = false;
        return true;
      },
      isCurrent: () => current,
    );
    expect(result.status, 'rejected');
  });
}
