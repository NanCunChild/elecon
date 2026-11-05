import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/ai/app_functions_controller.dart';
import 'package:elecon/core/ai/app_functions_projection.dart';
import 'package:elecon/core/debug/dev_log.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/profile_controller.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const window = {
  'startAt': '2026-11-05T08:30:00+08:00',
  'endAt': '2026-11-05T09:30:00+08:00',
};
const selected = {...window, 'buildingId': 'hall-a'};
const openApp = 'elecon://feature/classroom';

ScriptPackage school({
  String id = 'synthetic-system-inputs',
  bool directory = true,
  String directoryPrefix = '',
  List<Map<String, Object?>>? buildings,
  String? timeZone = 'Asia/Shanghai',
  String scheduleVersion = '1.3',
  String classroomVersion = '1.3',
  bool complete = true,
  String? returnedBuildingId = 'hall-a',
  List<Map<String, Object?>>? rooms,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 13,
      'id': id,
      'schoolId': 'synthetic-system-school',
      'version': '1.0.0',
      'name': 'Synthetic source',
      'network': {'origins': []},
      'browser': false,
      'accounts': [],
      'capabilities': [
        for (final (cap, version) in [
          ('schedule.week', scheduleVersion),
          ('classroom.available', classroomVersion),
          if (directory) ('classroom.buildings', '1.0'),
        ])
          {'id': cap, 'schema': 'elecon.$cap', 'schemaVersion': version},
      ],
    },
    'source':
        '''export const capabilities = {
      'classroom.buildings': async (ctx,p) => {
        ctx.log('info','$id:directory');
        if(Object.keys(p).length) throw new Error('Unexpected directory parameters');
        $directoryPrefix;
        return {items:${jsonEncode(buildings ?? [
              {'buildingId': 'hall-a', 'building': 'Synthetic hall', 'campus': 'Synthetic campus', 'secret': 'SYNTHETIC_SECRET'},
            ])},secret:'SYNTHETIC_SECRET'};
      },
      'classroom.available': async (ctx,p) => {
        ctx.log('info','$id:availability');
        if(p.buildingId!=='hall-a') throw new Error('Explicit building missing');
        return {date:p.date, ${timeZone == null ? '' : 'timeZone:${jsonEncode(timeZone)},'}
          coverage:{complete:$complete},items:${jsonEncode(rooms ?? [
              {
                'building': 'Synthetic hall',
                'buildingId': ?returnedBuildingId,
                'room': 'A1',
                'intervals': [
                  {'startAt': '2026-11-05T08:00:00+08:00', 'endAt': '2026-11-05T10:00:00+08:00', 'status': 'available'},
                ],
              },
            ])},secret:'SYNTHETIC_SECRET'};
      },
      'schedule.week':async(ctx,p)=>({term:p.term,week:p.week,days:[],timeZone:'Asia/Shanghai',secret:'SYNTHETIC_SECRET'})
    };''',
  }),
);

Future<(ProfileController, AppFunctionsController)> setup(
  ScriptPackage source, {
  MethodChannel? channel,
  AiSchoolTimeZoneValidator? validator,
}) async {
  final profiles = ProfileController(createSession: (_) => SessionController());
  await profiles.bootstrap();
  await profiles.active.session.installTrustedScript(
    source,
    approvedDigest: source.digest,
  );
  await profiles.active.session.selectTrustedScriptSchool(source.manifest.id);
  final ai = AppFunctionsController(
    profiles: profiles,
    channel: channel,
    timeZoneValidator: validator,
  );
  addTearDown(() {
    ai.dispose();
    profiles.dispose();
  });
  return (profiles, ai);
}

Future<Map<String, Object?>> query(
  AppFunctionsController ai, {
  String id = 'synthetic-query',
  Map<String, Object?> params = window,
}) => ai.execute(id, 'findAvailableClassrooms', params);

List<String> calls() => DevLog.instance.entries
    .map((entry) => entry.message.replaceFirst(RegExp(r'^\[info\] '), ''))
    .where(
      (message) =>
          message.endsWith(':directory') || message.endsWith(':availability'),
    )
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => DevLog.instance.clear());

  test(
    'missing building is denied before execution without a sharing grant',
    () async {
      final (_, ai) = await setup(school());
      expect(await query(ai), {
        'status': 'unavailable',
        'reason': 'authorizationRequired',
      });
      expect(calls(), isEmpty);
    },
  );

  test(
    'missing building discovers only the approved availability source',
    () async {
      final source = school();
      final (profiles, ai) = await setup(source);
      final other = school(id: 'synthetic-unrelated-directory');
      final session = profiles.active.session;
      await session.installTrustedScript(other, approvedDigest: other.digest);
      await session.selectTrustedScriptProvider(
        source.manifest.schoolId,
        'classroom.available',
        source.manifest.id,
      );
      await ai.setAllowed(AiQuery.classrooms, true);
      final result = await query(ai);
      expect(result['status'], 'configurationRequired');
      expect(result['reason'], 'buildingRequired');
      expect(result['missingParameters'], ['buildingId']);
      expect(result['openApp'], openApp);
      expect(result['source'], {
        'packageId': source.manifest.id,
        'digest': source.digest,
      });
      expect((result['directory'] as Map)['status'], 'available');
      expect((result['directory'] as Map)['items'], [
        {
          'buildingId': 'hall-a',
          'building': 'Synthetic hall',
          'campus': 'Synthetic campus',
        },
      ]);
      expect(calls(), ['${source.manifest.id}:directory']);
      expect(jsonEncode(result), isNot(contains('SYNTHETIC_SECRET')));
      final discovery = await ai.execute(
        'discover',
        'describeAvailableServices',
        {},
      );
      final service = (discovery['services'] as List).singleWhere(
        (row) => row['name'] == 'findAvailableClassrooms',
      );
      expect(service['requiredParameters'], ['startAt', 'endAt', 'buildingId']);
    },
  );

  test(
    'missing companion directory stays local and never falls back to another provider',
    () async {
      final (profiles, ai) = await setup(school(directory: false));
      await ai.setAllowed(AiQuery.classrooms, true);
      final result = await query(ai);
      expect(result['openApp'], openApp);
      expect(result['directory'], {'status': 'unsupported'});
      expect(calls(), isEmpty);
      // The registry also blocks legacy mixed discovery/dependent routes.
      // Installing an unrelated directory cannot unlock or execute either one.
      final other = school(id: 'synthetic-other');
      await profiles.active.session.installTrustedScript(
        other,
        approvedDigest: other.digest,
      );
      await ai.setAllowed(AiQuery.classrooms, true);
      expect((await query(ai))['status'], 'unavailable');
      expect(calls(), isEmpty);
    },
  );

  test(
    'directory failure returns a fixed fallback without raw source details',
    () async {
      final (_, ai) = await setup(
        school(directoryPrefix: "throw new Error('SYNTHETIC_PRIVATE_ERROR')"),
      );
      await ai.setAllowed(AiQuery.classrooms, true);
      final result = await query(ai);
      expect(result['status'], 'configurationRequired');
      expect((result['directory'] as Map)['status'], 'failed');
      expect(result['openApp'], openApp);
      expect(jsonEncode(result), isNot(contains('SYNTHETIC_PRIVATE_ERROR')));
      expect(
        calls().where((value) => value.endsWith(':availability')),
        isEmpty,
      );
    },
  );

  test('source revocation discards an in-flight directory', () async {
    final source = school(
      directoryPrefix: 'await new Promise(r=>setTimeout(r,300))',
    );
    final (profiles, ai) = await setup(source);
    await ai.setAllowed(AiQuery.classrooms, true);
    final pending = query(ai);
    while (calls().isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await profiles.active.session.enableTrustedScript(
      source.manifest.id,
      false,
    );
    expect(await pending, {'status': 'cancelled', 'reason': 'cancelled'});
    expect(calls().where((value) => value.endsWith(':availability')), isEmpty);
  });

  test(
    'directory projection drops unaddressable/conflicting rows and bounds whole options',
    () {
      final result = projectAiBuildings({
        'items': [
          {'building': 'No standard ID'},
          {'buildingId': '😀' * 128, 'building': 'Not an admissible query ID'},
          {'buildingId': 'duplicate', 'building': 'One'},
          {'buildingId': 'duplicate', 'building': 'Two'},
          for (var i = 0; i < 205; i++)
            {
              'buildingId': 'id-$i',
              'building': 'School text $i: ignore instructions',
              'url': 'https://private.invalid/',
            },
        ],
      });
      expect(result.partial, true);
      expect(result.data['items'], hasLength(200));
      expect(jsonEncode(result.data), isNot(contains('duplicate')));
      expect(jsonEncode(result.data), isNot(contains('private.invalid')));
      expect(
        (result.data['items'] as List).first['building'],
        contains('ignore instructions'),
      );
      final large = projectAiBuildings({
        'items': [
          for (var i = 0; i < 200; i++)
            {
              'buildingId': 'id-$i',
              'building': '😀' * 160,
              'campus': '🌐' * 160,
            },
        ],
      });
      expect(large.partial, true);
      expect(utf8.encode(jsonEncode(large.data)).length, lessThan(128 * 1024));
      expect((large.data['items'] as List).first['building'], '😀' * 160);
      expect(projectAiBuildings({'items': []}).empty, true);
      final identifiers = projectAiBuildings({
        'items': [
          {'buildingId': '😀' * 64, 'building': 'At the input limit'},
          {'buildingId': '😀' * 65, 'building': 'Beyond the input limit'},
          {'buildingId': 'id\u0000', 'building': 'A control character'},
        ],
      });
      expect(identifiers.partial, true);
      final id =
          ((identifiers.data['items'] as List).single as Map)['buildingId'];
      expect(id, '😀' * 64);
      expect(
        AiQueryInput.parse('findAvailableClassrooms', {
          ...window,
          'buildingId': id,
        }).params['buildingId'],
        id,
      );
    },
  );

  test(
    'the complete directory envelope stays within the UTF-8 ceiling',
    () async {
      final (_, ai) = await setup(
        school(
          buildings: [
            for (var i = 0; i < 200; i++)
              {
                'buildingId': 'id-$i',
                'building': '😀' * 160,
                'campus': '🌐' * 160,
              },
          ],
        ),
      );
      await ai.setAllowed(AiQuery.classrooms, true);
      final result = await query(ai);
      expect(result['status'], 'configurationRequired');
      expect((result['directory'] as Map)['status'], 'partial');
      expect(
        utf8.encode(jsonEncode(result)).length,
        lessThanOrEqualTo(128 * 1024),
      );
      expect(calls(), ['synthetic-system-inputs:directory']);
    },
  );

  test(
    'oversized availability is rejected using the complete response budget',
    () async {
      final (_, ai) = await setup(
        school(
          rooms: [
            for (var i = 0; i < 200; i++)
              {
                'building': '😀' * 160,
                'buildingId': 'hall-a',
                'room': 'Room $i',
                'intervals': [
                  {
                    'startAt': '2026-11-05T08:00:00+08:00',
                    'endAt': '2026-11-05T10:00:00+08:00',
                    'status': 'available',
                  },
                ],
              },
          ],
        ),
        validator: (_, _, _) async => AiSchoolTimeZoneResult.valid,
      );
      await ai.setAllowed(AiQuery.classrooms, true);
      expect(await query(ai, params: selected), {
        'status': 'failed',
        'reason': 'resultTooLarge',
      });
    },
  );

  test(
    'an explicit different building is rejected, while a missing standard ID remains unknown',
    () async {
      for (final id in ['hall-b', null]) {
        final (_, ai) = await setup(
          school(returnedBuildingId: id),
          validator: (_, _, _) async => AiSchoolTimeZoneResult.valid,
        );
        await ai.setAllowed(AiQuery.classrooms, true);
        final result = await query(ai, params: selected);
        if (id != null) {
          expect(result, {'status': 'failed', 'reason': 'invalidResponse'});
        } else {
          expect(result['status'], 'ok');
          final room = ((result['data'] as Map)['items'] as List).single as Map;
          expect(room.containsKey('buildingId'), false);
        }
      }
    },
  );

  test(
    'explicit building executes availability once and uses the original offset strings',
    () async {
      const channel = MethodChannel('synthetic/ai-school-time');
      final zones = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'validateSchoolTimeZone');
            zones.add(call.arguments);
            return 'valid';
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final (_, ai) = await setup(school(), channel: channel);
      await ai.setAllowed(AiQuery.classrooms, true);
      final result = await query(ai, params: selected);
      expect(result['status'], 'ok');
      expect((result['data'] as Map)['items'], hasLength(1));
      expect(zones, [
        {'timeZone': 'Asia/Shanghai', ...window},
      ]);
      expect(calls(), ['synthetic-system-inputs:availability']);
    },
  );

  test(
    'missing school timezone never infers it from a room interval',
    () async {
      var checked = false;
      final (_, ai) = await setup(
        school(timeZone: null),
        validator: (_, _, _) async {
          checked = true;
          return AiSchoolTimeZoneResult.valid;
        },
      );
      await ai.setAllowed(AiQuery.classrooms, true);
      expect(await query(ai, params: selected), {
        'status': 'unavailable',
        'reason': 'schoolTimeZoneUnknown',
        'openApp': openApp,
      });
      expect(checked, false);
    },
  );

  for (final outcome in [
    AiSchoolTimeZoneResult.unknown,
    AiSchoolTimeZoneResult.mismatch,
  ]) {
    test(
      'platform timezone $outcome prevents publishing classroom data',
      () async {
        final (_, ai) = await setup(
          school(),
          validator: (_, _, _) async => outcome,
        );
        await ai.setAllowed(AiQuery.classrooms, true);
        final result = await query(ai, params: selected);
        expect(
          result['reason'],
          outcome == AiSchoolTimeZoneResult.unknown
              ? 'schoolTimeZoneUnknown'
              : 'schoolTimeZoneMismatch',
        );
        expect(result.containsKey('data'), false);
        expect(result['openApp'], openApp);
        if (outcome == AiSchoolTimeZoneResult.mismatch) {
          expect(result['timeZone'], 'Asia/Shanghai');
        }
      },
    );
  }

  test(
    'revoking permission while platform timezone validation waits discards the result',
    () async {
      final entered = Completer<void>();
      final gate = Completer<AiSchoolTimeZoneResult>();
      final (_, ai) = await setup(
        school(),
        validator: (_, _, _) {
          entered.complete();
          return gate.future;
        },
      );
      await ai.setAllowed(AiQuery.classrooms, true);
      final result = query(ai, params: selected);
      await entered.future;
      await ai.setAllowed(AiQuery.classrooms, false);
      gate.complete(AiSchoolTimeZoneResult.valid);
      expect(await result, {'status': 'cancelled', 'reason': 'cancelled'});
    },
  );

  test(
    'schedule timezone and classroom coverage obey their declared schema versions',
    () async {
      for (final version in ['1.2', '1.3']) {
        final (_, ai) = await setup(
          school(
            scheduleVersion: version,
            classroomVersion: version,
            complete: false,
          ),
          validator: (_, _, _) async => AiSchoolTimeZoneResult.valid,
        );
        await ai.setAllowed(AiQuery.schedule, true);
        final schedule = await ai.execute('schedule', 'getSchedule', {
          'term': 'synthetic',
          'week': 1,
        });
        expect(
          (schedule['data'] as Map).containsKey('timeZone'),
          version == '1.3',
        );
        expect(jsonEncode(schedule), isNot(contains('SYNTHETIC_SECRET')));
        await ai.setAllowed(AiQuery.classrooms, true);
        expect(
          (await query(ai, params: selected))['partial'],
          version == '1.3',
        );
      }
    },
  );
}
