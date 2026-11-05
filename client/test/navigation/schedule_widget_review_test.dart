// Independent ADR-090 review regressions. Synthetic sources, no device or network.
import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/widgets/schedule_widget_controller.dart';
import 'package:elecon/core/widgets/schedule_widget_snapshot.dart';
import 'package:elecon/session/profile_controller.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/school_fixture.dart';

ScriptPackage _source(
  String id, {
  String source = 'export const capabilities = {};',
  bool cache = false,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 16,
      'id': id,
      'schoolId': 'synthetic',
      'version': '1.0.0',
      'name': id,
      'browser': false,
      'network': {'origins': []},
      'accounts': [],
      'capabilities': [
        {
          'id': 'schedule.week',
          'schema': 'elecon.schedule.week',
          'schemaVersion': '1.3',
        },
      ],
      if (cache)
        'home': [
          {'capability': 'schedule.week', 'ttlSeconds': 900},
        ],
    },
    'source': source,
  }),
);

Future<void> _drain() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'historical latest cache keeps the known current day and original cache age',
    () async {
      const channel = MethodChannel('synthetic-widget-review-history');
      final publications = <Map>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'synchronize') {
              return ((call.arguments as Map)['contexts'] as List)
                  .map((row) => row['scope'])
                  .toList();
            }
            if (call.method == 'schoolDate') return '2026-11-05';
            if (call.method == 'publish') {
              publications.add(call.arguments as Map);
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final session = SessionController(
        initialSchools: [testSchool(schoolId: 'synthetic')],
      );
      final profiles = ProfileController(
        initialSession: session,
        createSession: (_) => SessionController(),
      );
      addTearDown(profiles.dispose);
      await profiles.bootstrap();
      final source = _source(
        'synthetic-widget-history',
        cache: true,
        source: '''export const capabilities = {
          'schedule.week': async (ctx, p) => ({
            term: 'synthetic', week: p.week || 2, timeZone: 'Asia/Shanghai',
            teachingWeekStart: p.week ? '2026-10-26' : '2026-11-02',
            teachingWeekEnd: p.week ? '2026-11-01' : '2026-11-08',
            days: [{dayOfWeek: 4, slots: [{
              start: '1', end: '2', timeStart: '08:00', timeEnd: '09:30',
              courseName: p.week ? 'Historical class' : 'Current class'
            }]}]
          })
        };''',
      );
      await session.installTrustedScript(source, approvedDigest: source.digest);
      await session.selectTrustedScriptSchool(source.manifest.id);
      session.scriptStorageConsent = () async => true;
      expect((await session.runCapability('schedule.week')).ok, true);
      final current = await session.cachedCapability('schedule.week');
      expect(current, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(
        (await session.runCapability('schedule.week', params: {'week': 1})).ok,
        true,
      );
      expect((await session.latestCachedCapability('schedule.week'))?.params, {
        'week': 1,
      });
      final controller = ScheduleWidgetController(
        profiles: profiles,
        channel: channel,
      );
      addTearDown(controller.dispose);
      await _drain();
      expect(publications, hasLength(1));
      final snapshot = publications.single['snapshot'] as Map;
      expect(snapshot['fetchedAt'], current!.fetchedAt.millisecondsSinceEpoch);
      expect(
        snapshot['freshUntil'],
        current.freshUntil!.millisecondsSinceEpoch,
      );
      final day = (snapshot['days'] as List).first as Map;
      expect(day['known'], true);
      expect((day['courses'] as List).single['name'], 'Current class');
    },
  );

  test(
    'ordinary cache notifications do not discard an approved pending widget click',
    () async {
      const channel = MethodChannel('synthetic-widget-review-pending');
      List contexts = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'beginSession') return 17;
            if (call.method == 'synchronize') {
              contexts = (call.arguments as Map)['contexts'] as List;
              return <String>[];
            }
            if (call.method == 'widgetScope') return contexts.first['scope'];
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final session = SessionController(
        initialSchools: [testSchool(schoolId: 'synthetic')],
      );
      final profiles = ProfileController(
        initialSession: session,
        createSession: (_) => SessionController(),
      );
      addTearDown(profiles.dispose);
      await profiles.bootstrap();
      final source = _source('synthetic-widget-pending');
      await session.installTrustedScript(source, approvedDigest: source.digest);
      await session.selectTrustedScriptSchool(source.manifest.id);
      final controller = ScheduleWidgetController(
        profiles: profiles,
        channel: channel,
      );
      addTearDown(controller.dispose);
      await _drain();
      final request = controller.pending;
      expect(request, isNotNull);
      session.onCredentialsChanged();
      await _drain();
      expect(controller.consume(request!), true);
      expect(controller.pending, isNull);
    },
  );

  test(
    'revoking one same-school source invalidates native data before a blocked old sync completes',
    () async {
      const channel = MethodChannel('synthetic-widget-review-revoke');
      final blocked = Completer<List<String>>();
      final calls = <MethodCall>[];
      var synchronizations = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'synchronize') {
              synchronizations++;
              if (synchronizations == 2) return blocked.future;
              return <String>[];
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final session = SessionController(
        initialSchools: [testSchool(schoolId: 'synthetic')],
      );
      final profiles = ProfileController(
        initialSession: session,
        createSession: (_) => SessionController(),
      );
      addTearDown(profiles.dispose);
      await profiles.bootstrap();
      final first = _source('synthetic-widget-first'),
          second = _source('synthetic-widget-second');
      await session.installTrustedScript(first, approvedDigest: first.digest);
      await session.installTrustedScript(second, approvedDigest: second.digest);
      await session.selectTrustedScriptSchool(first.manifest.id);
      final controller = ScheduleWidgetController(
        profiles: profiles,
        channel: channel,
      );
      addTearDown(controller.dispose);
      await _drain();
      expect(synchronizations, 1);
      session.onCredentialsChanged();
      await _drain();
      expect(synchronizations, 2);
      calls.clear();
      try {
        await session.enableTrustedScript(first.manifest.id, false);
        expect(session.selectedSchool?.id, 'synthetic');
        await _drain();
        expect(
          calls.where((call) => call.method == 'invalidate'),
          isNotEmpty,
          reason:
              'Source revocation must not await the older native synchronization.',
        );
        expect(blocked.isCompleted, false);
      } finally {
        blocked.complete([]);
        await _drain();
      }
    },
  );

  test(
    'conflicting complete-week date coverage stays unknown instead of overwriting courses with no classes',
    () {
      final raw = <String, Object?>{
        'term': 'synthetic',
        'week': 3,
        'timeZone': 'Asia/Shanghai',
        'teachingWeekStart': '2026-11-16',
        'teachingWeekEnd': '2026-11-22',
        'days': [],
        'termWeeks': [
          {
            'week': 1,
            'teachingWeekStart': '2026-11-02',
            'teachingWeekEnd': '2026-11-08',
            'days': [
              {
                'dayOfWeek': 4,
                'slots': [
                  {
                    'start': '1',
                    'end': '2',
                    'courseName': 'Synthetic class',
                    'timeStart': '08:00',
                    'timeEnd': '09:30',
                  },
                ],
              },
            ],
          },
          {
            'week': 2,
            'teachingWeekStart': '2026-11-02',
            'teachingWeekEnd': '2026-11-08',
            'days': [],
          },
        ],
      };
      final result = scheduleWidgetSnapshot(
        ScriptCachedData(
          data: raw,
          fetchedAt: DateTime.utc(2026, 11, 4),
          isStale: false,
          params: const {},
        ),
        schoolDate: '2026-11-05',
        schemaVersion: '1.3',
      )!;
      expect((result['days'] as List).first['known'], false);
    },
  );
}
