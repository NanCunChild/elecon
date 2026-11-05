import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/widgets/schedule_widget_controller.dart';
import 'package:elecon/core/widgets/schedule_widget_identity.dart';
import 'package:elecon/core/widgets/schedule_widget_snapshot.dart';
import 'package:elecon/session/profile_controller.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/school_fixture.dart';

Map<String, Object?> schedule() => {
  'term': 'synthetic',
  'week': 1,
  'timeZone': 'Asia/Shanghai',
  'teachingWeekStart': '2026-11-02',
  'teachingWeekEnd': '2026-11-08',
  'days': [
    {
      'dayOfWeek': 4,
      'slots': [
        <String, Object?>{
          'courseName': 'Synthetic lab',
          'date': '2026-11-05',
          'start': '1',
          'end': '2',
          'timeStart': '08:00',
          'timeEnd': '09:30',
          'location': 'Room A',
          'teacher': 'Must not export',
          'courseUrl': 'https://example.invalid/secret',
        },
      ],
    },
    {'dayOfWeek': 5, 'slots': <Object>[]},
  ],
};

ScriptCachedData cache(Map<String, Object?> raw) => ScriptCachedData(
  data: raw,
  fetchedAt: DateTime.utc(2026, 11, 4),
  freshUntil: DateTime.utc(2026, 11, 4, 1),
  isStale: true,
  params: const {},
);

Map<String, Object?>? project(
  Map<String, Object?> data, {
  String date = '2026-11-05',
  String version = '1.3',
}) => scheduleWidgetSnapshot(
  cache(data),
  schoolDate: date,
  schemaVersion: version,
);

ScriptPackage package(String id) => ScriptPackage.parse(
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
          'schemaVersion': '1.2',
        },
      ],
    },
    'source': 'export const capabilities = {};',
  }),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'minimal display retains original freshness, known empty and unknown days',
    () {
      final value = project(schedule())!;
      expect(
        value['fetchedAt'],
        DateTime.utc(2026, 11, 4).millisecondsSinceEpoch,
      );
      expect(
        value['freshUntil'],
        DateTime.utc(2026, 11, 4, 1).millisecondsSinceEpoch,
      );
      final days = value['days'] as List;
      expect(days.length, 7);
      expect(days[0]['known'], true);
      expect(days[0]['courses'].single, {
        'name': 'Synthetic lab',
        'location': 'Room A',
        'label': '08:00–09:30',
        'start': '08:00',
        'end': '09:30',
      });
      expect(days[1]['known'], true);
      expect(days[1]['courses'], isEmpty);
      expect(days[2]['known'], false);
      expect(jsonEncode(value), isNot(contains('Must not export')));
      expect(jsonEncode(value), isNot(contains('https://')));
    },
  );

  test(
    'no guessed timezone, older extension semantics or normalized bad date',
    () {
      expect(project(schedule()..remove('timeZone')), isNull);
      expect(project(schedule(), version: '1.2'), isNull);
      expect(project(schedule(), date: '2026-02-30'), isNull);
      expect(project(schedule(), date: '2026-2-5'), isNull);
    },
  );

  test(
    'maximum Unicode display stays within native budgets without losing courses or freshness',
    () {
      String repeat(String value, int count) =>
          List.filled(count, value).join();
      final raw = schedule();
      raw['days'] = [
        for (var day = 1; day <= 7; day++)
          {
            'dayOfWeek': day,
            'slots': [
              for (var index = 0; index < 32; index++)
                {
                  // BMP text maximizes UTF-8 bytes per UTF-16 unit. The first
                  // course also exercises odd-boundary and all-astral truncation.
                  'courseName': day == 1 && index == 0
                      ? '${repeat('漢', 119)}😺'
                      : repeat('漢', 120),
                  'location': day == 1 && index == 0
                      ? repeat('😺', 61)
                      : repeat('漢', 120),
                  'start': day == 1 && index == 0
                      ? repeat('😺', 40)
                      : repeat('漢', 40),
                  'end': day == 1 && index == 0
                      ? repeat('😺', 40)
                      : repeat('漢', 40),
                },
            ],
          },
      ];
      final value = project(raw, date: '2026-11-02')!;
      final days = value['days'] as List;
      expect(days, hasLength(7));
      for (final day in days) {
        expect(day['known'], true);
        expect(day['courses'], hasLength(32));
        for (final course in day['courses'] as List) {
          expect((course['name'] as String).length, lessThanOrEqualTo(120));
          expect((course['location'] as String).length, lessThanOrEqualTo(120));
          expect((course['label'] as String).length, lessThanOrEqualTo(81));
        }
      }
      final first = days[0]['courses'][0];
      expect(first['name'], repeat('漢', 119));
      expect(first['location'], repeat('😺', 60));
      expect(first['label'], '${repeat('😺', 20)}–${repeat('😺', 20)}');
      expect(utf8.encode(jsonEncode(value)).length, lessThan(256 * 1024));
      expect(
        value['fetchedAt'],
        DateTime.utc(2026, 11, 4).millisecondsSinceEpoch,
      );
      expect(
        value['freshUntil'],
        DateTime.utc(2026, 11, 4, 1).millisecondsSinceEpoch,
      );
    },
  );

  test(
    'section-only classes keep their label without a fabricated next-class time',
    () {
      final raw = schedule();
      final slot = ((raw['days'] as List).first as Map)['slots'][0] as Map;
      slot.remove('timeStart');
      slot.remove('timeEnd');
      final course = (project(raw)!['days'] as List)[0]['courses'][0] as Map;
      expect(course['label'], '1–2');
      expect(course.containsKey('start'), false);
    },
  );

  test(
    'inconsistent dates and oversized days stay unknown instead of silently empty',
    () {
      final raw = schedule();
      final first = (raw['days'] as List).first as Map;
      (first['slots'][0] as Map)['date'] = '2026-11-06';
      expect((project(raw)!['days'] as List)[0]['known'], false);
      first['slots'] = List.filled(33, {
        'courseName': 'Synthetic',
        'start': '1',
        'end': '2',
      });
      expect((project(raw)!['days'] as List)[0]['known'], false);
    },
  );

  test(
    'explicit complete term weeks support cross-week redraw without extending freshness',
    () {
      final raw = schedule();
      raw['termWeeks'] = [
        {
          'week': 2,
          'teachingWeekStart': '2026-11-09',
          'teachingWeekEnd': '2026-11-15',
          'days': <Object>[],
        },
      ];
      final value = project(raw, date: '2026-11-08')!;
      final days = value['days'] as List;
      expect(days[0]['known'], false);
      expect(days[1]['date'], '2026-11-09');
      expect(days[1]['known'], true);
      expect(days[1]['courses'], isEmpty);
      expect(
        value['fetchedAt'],
        DateTime.utc(2026, 11, 4).millisecondsSinceEpoch,
      );
    },
  );

  test('main and term-week exceptions use the course own week', () {
    final raw = schedule();
    final mainSlot =
        (((raw['days'] as List).first as Map)['slots'] as List).first as Map;
    mainSlot['weeks'] = [2];
    raw['termWeeks'] = [
      {
        'week': 2,
        'teachingWeekStart': '2026-11-09',
        'teachingWeekEnd': '2026-11-15',
        'days': [
          {
            'dayOfWeek': 1,
            'slots': [
              {
                'courseName': 'Term week two',
                'start': '1',
                'end': '2',
                'weeks': [2],
              },
              {
                'courseName': 'Excluded week two',
                'start': '3',
                'end': '4',
                'weekExceptions': [2],
              },
            ],
          },
        ],
      },
    ];
    final days = project(raw)!['days'] as List;
    expect(days[0]['courses'], isEmpty);
    expect(days[4]['courses'], hasLength(1));
    expect(days[4]['courses'][0]['name'], 'Term week two');
    mainSlot['weeks'] = [1];
    mainSlot['weekExceptions'] = [1];
    expect((project(raw)!['days'] as List)[0]['courses'], isEmpty);
  });

  test(
    'durable identity token is host-only and rotates on school login clearing',
    () {
      final backend = InMemorySecureStore();
      final store = CredentialStore(store: backend);
      final identities = ScheduleWidgetIdentityStore(store);
      final first = identities.token('synthetic');
      final other = identities.token('other');
      expect(
        ScheduleWidgetIdentityStore(
          CredentialStore(store: backend),
        ).token('synthetic'),
        first,
      );
      expect(
        ScriptCredentials(
          store: store,
          schoolId: 'synthetic',
          scriptId: 'synthetic-test',
          sdkVersion: 2,
        ).list(),
        isEmpty,
      );
      expect(identities.clearSchool('synthetic'), hasLength(1));
      expect(identities.token('synthetic'), isNot(first));
      expect(identities.token('other'), other);
    },
  );

  test(
    'widget metadata never counts as a logged-in account or public credential',
    () async {
      final session = SessionController(
        initialSchools: [testSchool(schoolId: 'synthetic')],
      );
      addTearDown(session.dispose);
      await session.bootstrap();
      final source = package('synthetic-one');
      await session.installTrustedScript(source, approvedDigest: source.digest);
      await session.selectTrustedScriptSchool(source.manifest.id);
      final first = await session.scheduleWidgetIdentity(
        source.manifest.id,
        source.digest,
      );
      expect(first, isNotNull);
      expect(session.isLoggedIn, false);
      expect(session.credentialMetadata, isEmpty);
      expect(session.scheduleWidgetPersistence, false);
      session.logout();
      expect(
        await session.scheduleWidgetIdentity(source.manifest.id, source.digest),
        isNot(first),
      );
      await session.enableTrustedScript(source.manifest.id, false);
      expect(
        await session.scheduleWidgetIdentity(source.manifest.id, source.digest),
        isNull,
      );
    },
  );

  test(
    'cold widget click waits for restoration, binds approved source, and invalidates on identity change',
    () async {
      const channel = MethodChannel('synthetic-schedule-widget');
      final calls = <MethodCall>[];
      List contexts = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            switch (call.method) {
              case 'beginSession':
                return 37;
              case 'synchronize':
                contexts = (call.arguments as Map)['contexts'] as List;
                return contexts.map((row) => row['scope']).toList();
              case 'widgetScope':
                return contexts.isEmpty ? null : contexts.first['scope'];
              default:
                return null;
            }
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final session = SessionController(
        initialSchools: [testSchool(schoolId: 'synthetic')],
      );
      await session.bootstrap();
      final source = package('synthetic-cold');
      await session.installTrustedScript(source, approvedDigest: source.digest);
      await session.selectTrustedScriptSchool(source.manifest.id);
      final profiles = ProfileController(
        initialSession: session,
        createSession: (_) => SessionController(),
      );
      addTearDown(profiles.dispose);
      final controller = ScheduleWidgetController(
        profiles: profiles,
        channel: channel,
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => c.method), ['beginSession']);
      await profiles.bootstrap();
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(controller.pending?.source.packageId, source.manifest.id);
      expect(controller.pending?.source.digest, source.digest);
      expect(contexts.single['persistent'], false);
      expect(jsonEncode(contexts), isNot(contains('schoolId')));
      final request = controller.pending!;
      session.logout();
      await Future<void>.delayed(Duration.zero);
      expect(controller.consume(request), false);
      expect(controller.pending, isNull);
      expect(calls.any((call) => call.method == 'invalidate'), true);
    },
  );

  test('late snapshot cannot publish after profile change', () async {
    const channel = MethodChannel('synthetic-schedule-widget-late');
    final blocked = Completer<List<String>>();
    final published = <Object?>[];
    var synchronized = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'synchronize' && !synchronized) {
            synchronized = true;
            return blocked.future;
          }
          if (call.method == 'publish') published.add(call.arguments);
          return call.method == 'synchronize' ? <String>[] : null;
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
    final source = package('synthetic-late');
    await session.installTrustedScript(source, approvedDigest: source.digest);
    await session.selectTrustedScriptSchool(source.manifest.id);
    final controller = ScheduleWidgetController(
      profiles: profiles,
      channel: channel,
    );
    addTearDown(controller.dispose);
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(synchronized, true);
    await profiles.add();
    blocked.complete(['untrusted-unknown-scope']);
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(published, isEmpty);
  });
}
