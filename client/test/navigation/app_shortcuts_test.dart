import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/navigation/app_feature.dart';
import 'package:elecon/core/navigation/app_shortcuts_controller.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/registry.dart';
import 'package:elecon/session/profile_controller.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/home/native_feature.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/school_fixture.dart';

ProfileController profiles() {
  final controller = ProfileController(
    createSession: (_) => SessionController(
      initialSchools: [
        testSchool(schoolId: 'first'),
        testSchool(schoolId: 'second'),
      ],
    ),
  );
  addTearDown(controller.dispose);
  return controller;
}

AppShortcutsController shortcuts(
  ProfileController profiles, {
  MethodChannel? channel,
}) {
  final controller = AppShortcutsController(
    profiles: profiles,
    channel: channel,
  );
  addTearDown(controller.dispose);
  return controller;
}

ScriptPackage package(String id, List<String> capabilities) =>
    ScriptPackage.parse(
      jsonEncode({
        'format': 'elecon-script/1',
        'manifest': {
          'sdkVersion': 16,
          'id': id,
          'schoolId': 'synthetic',
          'version': '1.0.0',
          'name': 'Synthetic feature',
          'browser': false,
          'network': {'origins': []},
          'accounts': [],
          'capabilities': [
            for (final id in capabilities)
              {'id': id, 'schema': 'elecon.$id', 'schemaVersion': '1.0'},
          ],
        },
        'source': 'export const capabilities = {};',
      }),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'feature URIs accept only canonical fixed destinations without arguments',
    () {
      for (final feature in AppFeature.values) {
        expect(AppFeature.fromUri(feature.uri), feature);
      }
      for (final value in [
        'elecon://feature/schedule?profile=other',
        'elecon://feature/climate?command=on',
        'elecon://feature/directory#call',
        'elecon://feature/%73chedule',
        'elecon://feature/schedule/',
        'elecon://other/schedule',
        'elecon://feature:123/schedule',
        'elecon://user@feature/schedule',
        'elecon://feature/../schedule',
        'elecon://feature/account.session',
        'https://feature/schedule',
        'elecon://feature/execute',
        'elecon://feature/web',
        'schedule',
      ]) {
        expect(AppFeature.fromUri(value), isNull, reason: value);
      }
    },
  );

  test(
    'cold request waits through restoration and first school selection, then consumes once',
    () async {
      final p = profiles();
      final s = shortcuts(p);
      s.receive(AppFeature.schedule.uri);
      await p.bootstrap();
      expect(p.active.session.selectedSchool, isNull);
      expect(s.pending!.feature, AppFeature.schedule);
      p.active.session.selectSchool(p.active.session.availableSchools.first);
      final request = s.pending!;
      expect(s.consume(request), isTrue);
      expect(s.consume(request), isFalse);
      expect(s.pending, isNull);
    },
  );

  test(
    'switching an already bound school or Profile discards its pending request',
    () async {
      final p = profiles();
      await p.bootstrap();
      final s = shortcuts(p);
      p.active.session.selectSchool(p.active.session.availableSchools.first);
      s.receive(AppFeature.grades.uri);
      p.active.session.selectSchool(p.active.session.availableSchools.last);
      expect(s.pending, isNull);
      s.receive(AppFeature.exam.uri);
      await p.add();
      expect(s.pending, isNull);
    },
  );

  test(
    'latest valid request wins; invalid URI does not replace or execute it',
    () async {
      final p = profiles();
      await p.bootstrap();
      final s = shortcuts(p);
      s.receive(AppFeature.schedule.uri);
      final old = s.pending!;
      s.receive(AppFeature.exam.uri);
      s.receive('elecon://feature/climate?command=on');
      expect(s.pending!.feature, AppFeature.exam);
      expect(s.consume(old), isFalse);
    },
  );

  test(
    'late initial reply cannot overwrite a new warm-start request, and pinning stays explicit',
    () async {
      const channel = MethodChannel('synthetic-shortcuts');
      final initial = Completer<String?>();
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return switch (call.method) {
              'getInitialFeature' => initial.future,
              'pinState' => {'supported': true, 'pinned': <String>[]},
              'pinFeature' => 'failed',
              _ => null,
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final p = profiles();
      await p.bootstrap();
      final s = shortcuts(p, channel: channel);
      s.receive(AppFeature.directory.uri);
      initial.complete(AppFeature.schedule.uri);
      await Future<void>.delayed(Duration.zero);
      expect(s.pending!.feature, AppFeature.directory);
      expect(s.supported, isTrue);
      expect(calls, ['getInitialFeature', 'pinState']);
      expect(await s.pin(AppFeature.schedule), isFalse);
      expect(calls, [
        'getInitialFeature',
        'pinState',
        'pinState',
        'pinFeature',
        'pinState',
      ]);
    },
  );

  test(
    'missing platform pin handler returns unavailable without granting navigation',
    () async {
      final p = profiles();
      final s = shortcuts(p, channel: const MethodChannel('missing-shortcuts'));
      await Future<void>.delayed(Duration.zero);
      expect(s.supported, isFalse);
      expect(await s.pin(AppFeature.grades), isFalse);
      expect(s.pending, isNull);
    },
  );

  test(
    'feature resolver respects the chosen default provider, and never joins partial sources',
    () async {
      final registry = ScriptRegistry.empty(null);
      final base = package('synthetic-primary', ['directory.phones']);
      final extra = package('synthetic-secondary', ['directory.phones']);
      await registry.install(base, approvedDigest: base.digest);
      await registry.install(extra, approvedDigest: extra.digest);
      expect(
        nativeFeatureProvider(
          registry,
          'synthetic',
          AppFeature.directory,
        )?.digest,
        base.digest,
      );
      await registry.setProviderOverride(
        'synthetic',
        'directory.phones',
        extra.manifest.id,
      );
      expect(
        nativeFeatureProvider(
          registry,
          'synthetic',
          AppFeature.directory,
        )?.digest,
        extra.digest,
      );
      expect(
        nativeFeatureProvider(registry, 'other-school', AppFeature.directory),
        isNull,
      );
      expect(
        nativeFeatureProvider(registry, 'synthetic', AppFeature.climate),
        isNull,
      );
      final meters = package('synthetic-meters', ['energy.meters']);
      final usage = package('synthetic-usage', ['energy.usage']);
      await registry.install(meters, approvedDigest: meters.digest);
      await registry.install(usage, approvedDigest: usage.digest);
      expect(
        nativeFeatureProvider(registry, 'synthetic', AppFeature.energy),
        isNull,
      );
    },
  );

  test(
    'pin request remains unconfirmed until callback state, resume rechecks removal and failure',
    () async {
      const channel = MethodChannel('synthetic-shortcuts-observation');
      var supported = true;
      var pinned = <String>[];
      var failing = false;
      var requests = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'pinState') {
          if (failing) throw PlatformException(code: 'unavailable');
          return {'supported': supported, 'pinned': pinned};
        }
        if (call.method == 'pinFeature') {
          requests++;
          return 'requested';
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final p = profiles();
      await p.bootstrap();
      final s = shortcuts(p, channel: channel);
      await Future<void>.delayed(Duration.zero);
      expect(
        await s.requestPin(AppFeature.schedule),
        ShortcutPinResult.requested,
      );
      expect(s.pinned, isEmpty);
      expect(s.pinResult(AppFeature.schedule), ShortcutPinResult.requested);
      pinned = ['schedule', 'untrusted-id'];
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('pinStateChanged'),
        ),
        (_) {},
      );
      expect(s.pinned, {AppFeature.schedule});
      expect(await s.requestPin(AppFeature.schedule), ShortcutPinResult.pinned);
      expect(requests, 1);
      pinned = [];
      s.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(s.pinned, isEmpty);
      pinned = ['schedule'];
      await s.refreshPinState();
      expect(s.pinned, isNotEmpty);
      failing = true;
      await s.refreshPinState();
      expect(s.pinned, isEmpty);
      expect(s.supported, false);
      expect(
        await s.requestPin(AppFeature.exam),
        ShortcutPinResult.unavailable,
      );
      failing = false;
      supported = false;
      expect(
        await s.requestPin(AppFeature.exam),
        ShortcutPinResult.unsupported,
      );
      expect(requests, 1);
      expect(s.pending, isNull);
    },
  );
}
