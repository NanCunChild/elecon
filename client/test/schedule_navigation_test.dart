import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:elecon/core/adapter_service.dart';
import 'package:elecon/core/loader/diagnostics.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/capability_sections.dart';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/schedule_view.dart';
import 'package:elecon/ui/home/schema_decode.dart';
import 'package:elecon_contract/output_validator_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> payload(int week) => {
  'term': 'synthetic',
  'week': week,
  'teachingWeekStart': '2026-11-02',
  'days': [
    {
      'dayOfWeek': 1,
      'slots': <Map<String, dynamic>>[
        <String, dynamic>{
          'start': '1',
          'end': '2',
          'timeStart': '08:00',
          'timeEnd': '10:00',
          'courseName': 'First course',
          'room': 'Room A',
        },
        {
          'start': '2',
          'end': '3',
          'timeStart': '09:00',
          'timeEnd': '11:00',
          'courseName': 'Second course',
          'room': 'Room B',
        },
      ],
    },
  ],
  'timeSegments': [
    {'label': 'Period A', 'timeStart': '08:00', 'timeEnd': '09:00'},
    {'label': 'Period B', 'timeStart': '09:10', 'timeEnd': '10:00'},
  ],
  'weekPreviews': [
    {
      'week': 1,
      'days': [
        for (var day = 1; day <= 7; day++)
          {'dayOfWeek': day, 'courseCount': day == 1 ? 2 : 0},
      ],
    },
  ],
};

Widget app(
  Widget child, {
  SessionController? session,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) {
  final result = MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: ThemeData(brightness: brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
  return session == null
      ? result
      : SessionScope(controller: session, child: result);
}

class ScheduleSession extends SessionController {
  final requestedWeeks = <int>[];
  Completer<CapabilityRun>? gate;
  @override
  Future<CapabilityRun> runCapability(
    String capability, {
    Map<String, dynamic>? params,
    bool interactive = true,
    String? htmlStdlib,
    void Function(String, String)? onLog,
    void Function(AdapterDiagnostic)? onDiagnostic,
  }) async {
    expect(capability, 'schedule.week');
    final week = params!['week'] as int;
    requestedWeeks.add(week);
    if (gate != null) return gate!.future;
    return CapabilityRun.ok(payload(week));
  }
}

class CachedScheduleSession extends SessionController {
  final requests = <({int week, bool interactive})>[];
  final refresh = Completer<CapabilityRun>();
  @override
  Future<CapabilityRun> runCapability(
    String capability, {
    Map<String, dynamic>? params,
    bool interactive = true,
    String? htmlStdlib,
    void Function(String, String)? onLog,
    void Function(AdapterDiagnostic)? onDiagnostic,
  }) {
    expect(capability, 'schedule.week');
    requests.add((week: params!['week'] as int, interactive: interactive));
    return refresh.future;
  }
}

class CalendarScheduleSession extends ScheduleSession {
  int calendarRequests = 0;

  @override
  Future<CapabilityRun> runCapability(
    String capability, {
    Map<String, dynamic>? params,
    bool interactive = true,
    String? htmlStdlib,
    void Function(String, String)? onLog,
    void Function(AdapterDiagnostic)? onDiagnostic,
  }) {
    if (capability == 'calendar.academic') {
      calendarRequests++;
      return Future.value(
        CapabilityRun.ok({'term': 'synthetic', 'currentWeek': 12}),
      );
    }
    return super.runCapability(capability, params: params);
  }
}

void main() {
  test(
    'rest hints retain courses and reject invalid or conflicting ranges',
    () {
      final course = <String, dynamic>{
        'start': '1',
        'end': '2',
        'timeStart': '11:00',
        'timeEnd': '14:30',
        'courseName': 'Spans the break',
      };
      final raw = {
        ...payload(1),
        'timeZone': 'Asia/Shanghai',
        'days': [
          {
            'dayOfWeek': 1,
            'slots': [course],
          },
        ],
        'timeSegments': [
          {'label': 'Morning', 'timeStart': '10:00', 'timeEnd': '12:00'},
          {'label': 'Afternoon', 'timeStart': '14:00', 'timeEnd': '16:00'},
        ],
        'breakSegments': [
          {'label': 'Lunch break', 'timeStart': '12:00', 'timeEnd': '14:00'},
        ],
      };
      final valid = scheduleWeekFromDynamic(raw)!;
      expect(valid.breakSegments!.single.label, 'Lunch break');
      expect(valid.timeZone, 'Asia/Shanghai');
      for (final bad in [
        [
          {'label': 'Reverse', 'timeStart': '14:00', 'timeEnd': '12:00'},
        ],
        [
          {
            'label': 'Overlaps lesson',
            'timeStart': '11:30',
            'timeEnd': '14:00',
          },
        ],
        [
          {'label': 'First', 'timeStart': '12:00', 'timeEnd': '13:00'},
          {'label': 'Second', 'timeStart': '12:30', 'timeEnd': '14:00'},
        ],
        [
          {'label': 'Later', 'timeStart': '13:00', 'timeEnd': '14:00'},
          {'label': 'Earlier', 'timeStart': '12:00', 'timeEnd': '13:00'},
        ],
        [
          {'label': 'Broken clock', 'timeStart': 'noon', 'timeEnd': '14:00'},
        ],
      ]) {
        final decoded = scheduleWeekFromDynamic({
          ...raw,
          'breakSegments': bad,
        })!;
        expect(decoded.breakSegments, isNull);
        expect(decoded.days.single.slots.single.courseName, 'Spans the break');
      }
      expect(
        scheduleWeekFromDynamic({...raw, 'timeSegments': []})!.breakSegments,
        isNull,
      );
      expect(scheduleWeekFromDynamic(payload(1))!.breakSegments, isNull);
      expect(scheduleWeekFromDynamic(payload(1))!.timeZone, isNull);
      expect(
        scheduleWeekFromDynamic({...raw, 'timeZone': 'not a zone'})!.timeZone,
        isNull,
      );
    },
  );

  testWidgets('school axis has no unrelated fallback outer hours', (
    tester,
  ) async {
    final raw = {
      ...payload(1),
      'days': [],
      'timeSegments': [
        {
          'label': 'Only school period',
          'timeStart': '10:15',
          'timeEnd': '11:45',
        },
      ],
    };
    await tester.pumpWidget(
      app(WeekScheduleView(data: scheduleWeekFromDynamic(raw)!)),
    );
    await tester.pumpAndSettle();
    // One day header and one teaching segment; no fabricated 08:00/18:00 edge.
    expect(
      tester.getSize(find.byKey(const ValueKey('schedule-grid'))).height,
      120,
    );
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('break hints respect complete overlaps at 320px $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final raw = {
        ...payload(1),
        'timeSegments': [
          {'label': 'Morning', 'timeStart': '10:00', 'timeEnd': '12:00'},
          {'label': 'Afternoon', 'timeStart': '14:00', 'timeEnd': '16:00'},
        ],
        'breakSegments': [
          {'label': 'Lunch break', 'timeStart': '12:00', 'timeEnd': '14:00'},
        ],
        'days': [
          {
            'dayOfWeek': 1,
            'slots': [
              {
                'start': '1',
                'end': '2',
                'timeStart': '11:00',
                'timeEnd': '15:00',
                'courseName': 'Spans the entire lunch interval',
              },
            ],
          },
          {
            'dayOfWeek': 2,
            'slots': [
              {
                'start': '1',
                'end': '1',
                'timeStart': '10:00',
                'timeEnd': '12:00',
                'courseName': 'Ends at the boundary',
              },
            ],
          },
        ],
      };
      await tester.pumpWidget(
        app(
          WeekScheduleView(data: scheduleWeekFromDynamic(raw)!),
          scale: 2,
          brightness: brightness,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('schedule-break-1-0')), findsNothing);
      expect(find.byKey(const ValueKey('schedule-break-2-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('schedule-break-3-0')), findsNothing);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('schedule-course-1-0')))
            .height,
        greaterThan(400),
      );
      final hint = tester.widget<Tooltip>(
        find.descendant(
          of: find.byKey(const ValueKey('schedule-break-2-0')),
          matching: find.byType(Tooltip),
        ),
      );
      expect(hint.message, contains('No classes in the loaded schedule'));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'current week outline keeps the full thumbnail while browsing another week',
    (tester) async {
      await tester.pumpWidget(
        app(
          ScheduleWeekPicker(
            week: 2,
            currentWeek: 1,
            maxWeek: 4,
            onChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final current = tester.widget<Material>(
        find.byKey(const ValueKey('schedule-current-week-1')),
      );
      expect((current.shape as RoundedRectangleBorder).side.width, 2);
      final colors = Theme.of(
        tester.element(find.byType(ScheduleWeekPicker)),
      ).colorScheme;
      expect(
        (current.shape as RoundedRectangleBorder).side.color,
        colors.primary,
      );
      expect(current.color, colors.surfaceContainerLow);
      expect(
        tester.getSize(find.byKey(const ValueKey('schedule-preview-1'))).height,
        tester.getSize(find.byKey(const ValueKey('schedule-preview-2'))).height,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('week thumbnail paints all-day labs from top to bottom', (
    tester,
  ) async {
    final raw = <String, dynamic>{
      ...payload(1),
      'termWeeks': [
        {
          'week': 1,
          'teachingWeekStart': '2026-11-02',
          'teachingWeekEnd': '2026-11-08',
          'days': [
            {
              'dayOfWeek': 1,
              'slots': [
                {
                  'start': '1',
                  'end': '12',
                  'courseName': 'All-day lab',
                  'timeStart': '08:00',
                  'timeEnd': '18:00',
                },
              ],
            },
            {
              'dayOfWeek': 2,
              'slots': [
                {
                  'start': '1',
                  'end': '2',
                  'courseName': 'Short course',
                  'timeStart': '08:00',
                  'timeEnd': '10:00',
                },
              ],
            },
          ],
        },
      ],
    };
    final data = scheduleWeekFromDynamic(raw)!;
    expect(
      data.termWeeks!.single.days.first.slots.single.courseName,
      'All-day lab',
    );
    // Both full-term responses and the current week's older response preserve duration.
    final currentOnly = scheduleWeekFromDynamic({
      ...raw,
      'days': (raw['termWeeks'] as List).first['days'],
      'termWeeks': null,
    })!;
    for (final data in [data, currentOnly]) {
      await tester.pumpWidget(
        app(
          ScheduleWeekPicker(
            week: 1,
            maxWeek: 1,
            schedule: data,
            previews: data.weekPreviews!,
            onChanged: (_) {},
          ),
        ),
      );
      final painter = tester
          .widget<CustomPaint>(find.byKey(const ValueKey('schedule-preview-1')))
          .painter!;
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        painter.paint(Canvas(recorder), const Size(70, 100));
        final picture = recorder.endRecording();
        final image = await picture.toImage(70, 100);
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        int alpha(int x, int y) => bytes.getUint8((y * 70 + x) * 4 + 3);
        expect(alpha(5, 5), greaterThan(180));
        expect(alpha(5, 95), greaterThan(180));
        expect(alpha(15, 5), greaterThan(180));
        expect(alpha(15, 95), lessThan(80));
        image.dispose();
        picture.dispose();
      });
    }
  });

  testWidgets('today date is highlighted only in its actual teaching week', (
    tester,
  ) async {
    final raw = payload(1);
    for (final brightness in Brightness.values) {
      for (final day in [2, 9]) {
        await tester.pumpWidget(
          app(
            WeekScheduleView(
              data: scheduleWeekFromDynamic(raw)!,
              now: DateTime(2026, 11, day),
            ),
            brightness: brightness,
          ),
        );
        final header = tester.widget<Container>(
          find.byKey(const ValueKey('schedule-day-1')),
        );
        final colors = Theme.of(
          tester.element(find.byType(WeekScheduleView)),
        ).colorScheme;
        expect(
          (header.decoration as BoxDecoration).color,
          day == 2 ? colors.primaryContainer : isNull,
        );
        expect(tester.takeException(), isNull);
      }
    }
    raw.remove('teachingWeekStart');
    await tester.pumpWidget(
      app(
        WeekScheduleView(
          data: scheduleWeekFromDynamic(raw)!,
          now: DateTime(2026, 11, 2),
        ),
      ),
    );
    final unknown = tester.widget<Container>(
      find.byKey(const ValueKey('schedule-day-1')),
    );
    expect((unknown.decoration as BoxDecoration).color, isNull);
  });

  testWidgets('script current week opens centered and refreshes from an icon', (
    tester,
  ) async {
    final session = CalendarScheduleSession();
    addTearDown(session.dispose);
    await tester.pumpWidget(
      app(
        const HomeCardPresentation(
          size: HomeCardSize.expanded,
          isPage: true,
          child: ScheduleSection(calendarEnabled: true),
        ),
        session: session,
      ),
    );
    await tester.pumpAndSettle();
    expect(session.requestedWeeks, [12]);
    expect(
      find.byKey(const ValueKey('schedule-current-week-12')),
      findsOneWidget,
    );
    final strip = tester.getRect(
      find.byKey(const ValueKey('schedule-week-strip')),
    );
    final selected = tester.getRect(
      find.byKey(const ValueKey('schedule-week-12')),
    );
    expect(selected.center.dx, closeTo(strip.center.dx, 1));
    expect(
      find.widgetWithIcon(FilledButton, Icons.download_outlined),
      findsNothing,
    );
    final refresh = find.byKey(const ValueKey('schedule-refresh'));
    expect(tester.widget<IconButton>(refresh).tooltip, 'Refresh');
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(session.requestedWeeks, [12, 12]);
    await tester.tap(find.byKey(const ValueKey('schedule-week-13')));
    await tester.pumpAndSettle();
    expect(session.requestedWeeks, [12, 12, 13]);
    expect(
      find.byKey(const ValueKey('schedule-current-week-12')),
      findsOneWidget,
    );
    expect(
      tester.widget<WeekScheduleView>(find.byType(WeekScheduleView)).data.week,
      13,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('first and last weeks can both be centered', (tester) async {
    for (final week in [1, 25]) {
      await tester.pumpWidget(
        app(ScheduleWeekPicker(week: week, maxWeek: 25, onChanged: (_) {})),
      );
      await tester.pumpAndSettle();
      final strip = tester.getRect(
        find.byKey(const ValueKey('schedule-week-strip')),
      );
      final selected = tester.getRect(
        find.byKey(ValueKey('schedule-week-$week')),
      );
      expect(selected.center.dx, closeTo(strip.center.dx, 1));
    }
  });

  testWidgets(
    'reopening the borrowed card returns to the script current week',
    (tester) async {
      final session = CalendarScheduleSession();
      addTearDown(session.dispose);
      Widget page(bool opened) => app(
        HomeCardPresentation(
          size: HomeCardSize.expanded,
          isPage: opened,
          child: const ScheduleSection(calendarEnabled: true),
        ),
        session: session,
      );
      await tester.pumpWidget(page(true));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-week-13')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(page(false));
      await tester.pumpAndSettle();
      await tester.pumpWidget(page(true));
      await tester.pumpAndSettle();
      expect(session.requestedWeeks, [12, 13, 12]);
      expect(
        tester
            .widget<WeekScheduleView>(find.byType(WeekScheduleView))
            .data
            .week,
        12,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'arriving weeks animate in the navigation direction after loading',
    (tester) async {
      Widget transition(int? week) => app(
        ScheduleWeekTransition(
          week: week,
          child: Text(week == null ? 'Loading' : 'Week $week'),
        ),
      );
      final slide = find.descendant(
        of: find.byType(ScheduleWeekTransition),
        matching: find.byType(SlideTransition),
      );
      await tester.pumpWidget(transition(2));
      await tester.pumpWidget(transition(null));
      expect(find.text('Week 2'), findsNothing);
      await tester.pumpWidget(transition(3));
      expect(
        tester.widget<SlideTransition>(slide).position.value.dx,
        greaterThan(0),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<SlideTransition>(slide).position.value, Offset.zero);
      await tester.pumpWidget(transition(2));
      expect(
        tester.widget<SlideTransition>(slide).position.value.dx,
        lessThan(0),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'term cache switches weeks offline while one expired refresh runs',
    (tester) async {
      final session = CachedScheduleSession();
      addTearDown(session.dispose);
      final data = {
        ...payload(1),
        'termWeeks': [
          for (var week = 1; week <= 3; week++)
            {...payload(week), 'teachingWeekEnd': '2026-11-08'},
        ],
      };
      final package = ScriptPackage.parse(
        jsonEncode({
          'format': 'elecon-script/1',
          'manifest': {
            'sdkVersion': 4,
            'id': 'synthetic-schedule',
            'schoolId': 'synthetic',
            'version': '1.0.0',
            'name': 'Synthetic',
            'network': {'origins': []},
            'browser': false,
            'capabilities': [
              {
                'id': 'schedule.week',
                'schema': 'elecon.schedule.week',
                'schemaVersion': '1.2',
              },
            ],
            'home': [
              {'capability': 'schedule.week', 'ttlSeconds': 30},
            ],
          },
          'source':
              'export const capabilities={"schedule.week":async(_,params={})=>{'
              'const data=${jsonEncode(data)};'
              'return params.week ? {...data,...data.termWeeks.find(w=>w.week===params.week)} : data;}};',
        }),
      );
      await tester.runAsync(() async {
        await session.installTrustedScript(
          package,
          approvedDigest: package.digest,
        );
        await session.selectTrustedScriptSchool(package.manifest.id);
        expect(
          (await session.runTrustedScript(
            package.manifest.id,
            'schedule.week',
            interactive: false,
          )).ok,
          isTrue,
        );
        expect(
          await session.cachedCapability(
            'schedule.week',
            params: {'week': 2, 'term': 'synthetic'},
          ),
          isNotNull,
        );
        // A newer historical query must not determine the initial page week.
        await session.runTrustedScript(
          package.manifest.id,
          'schedule.week',
          params: {'week': 3, 'term': 'synthetic'},
          interactive: false,
        );
      });
      await tester.pumpWidget(
        app(
          const HomeCardPresentation(
            size: HomeCardSize.expanded,
            isPage: true,
            child: ScheduleSection(),
          ),
          session: session,
        ),
      );
      await tester.runAsync(() async {});
      await tester.pumpAndSettle();
      expect(session.requests, isEmpty);
      expect(
        tester
            .widget<WeekScheduleView>(find.byType(WeekScheduleView))
            .data
            .week,
        1,
      );
      await tester.tap(find.byKey(const ValueKey('schedule-week-2')));
      await tester.runAsync(() async {});
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<WeekScheduleView>(find.byType(WeekScheduleView))
            .data
            .week,
        2,
      );
      expect(session.requests, isEmpty);
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      expect(session.requests, [(week: 2, interactive: false)]);
      expect(find.byType(WeekScheduleView), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('schedule-week-3')));
      await tester.runAsync(() async {});
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<WeekScheduleView>(find.byType(WeekScheduleView))
            .data
            .week,
        3,
      );
      expect(session.requests, hasLength(1));
      session.refresh.complete(
        const CapabilityRun.failed(CapabilityFailureKind.run, 'offline'),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<WeekScheduleView>(find.byType(WeekScheduleView))
            .data
            .week,
        3,
      );
      expect(session.requests, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  test('shared Dart/TypeScript versioned schedule output cases', () {
    final golden =
        jsonDecode(
              File('../contract/golden/schedule/week.json').readAsStringSync(),
            )
            as Map;
    for (final entry in golden['cases'] as List) {
      expect(
        outputValidatorFor('elecon.schedule.week', entry['version'] as String)!(
          entry['data'],
        ),
        entry['valid'],
        reason: entry['name'] as String,
      );
    }
  });

  test(
    '1.0 remains accepted and 1.1 validates explicit wall clocks and preview counts',
    () {
      final old = {'term': 'synthetic', 'week': 1, 'days': <Object>[]};
      expect(outputValidatorFor('elecon.schedule.week', '1.0')!(old), isTrue);
      final validate = outputValidatorFor('elecon.schedule.week', '1.1')!;
      expect(validate(old), isTrue);
      expect(validate(payload(1)), isTrue);
      expect(
        validate({
          ...old,
          'timeSegments': [
            {'label': 'A', 'timeStart': '25:00', 'timeEnd': '26:00'},
          ],
        }),
        isFalse,
      );
      expect(
        validate({
          ...old,
          'weekPreviews': [
            {
              'week': 1,
              'days': [
                {'dayOfWeek': 1, 'courseCount': -1},
              ],
            },
          ],
        }),
        isFalse,
      );
      expect(outputValidatorFor('elecon.schedule.week', '2.0'), isNull);
    },
  );

  test(
    'decoder preserves dates/exceptions and safely ignores invalid time hints',
    () {
      final valid = payload(1);
      final rawSlot =
          ((valid['days'] as List).first['slots'] as List).first as Map;
      rawSlot['weekExceptions'] = [1];
      rawSlot['weeks'] = [1, 2];
      final data = scheduleWeekFromDynamic(valid)!;
      expect(data.teachingWeekStart, '2026-11-02');
      expect(data.timeSegments!.length, 2);
      expect(todaySlots(data, DateTime(2026, 11, 2)).map((s) => s.courseName), [
        'Second course',
      ]);
      final invalid = {
        ...valid,
        'timeSegments': [
          {'label': 'Late', 'timeStart': '10:00', 'timeEnd': '11:00'},
          {'label': 'Early', 'timeStart': '08:00', 'timeEnd': '09:00'},
        ],
      };
      final fallback = scheduleWeekFromDynamic(invalid)!;
      expect(fallback.timeSegments, isNull);
      expect(fallback.days.single.slots.length, 2);
      expect(
        scheduleWeekFromDynamic({
          ...valid,
          'timeSegments': [
            {'label': 'Reverse', 'timeStart': '10:00', 'timeEnd': '09:00'},
          ],
        })!.timeSegments,
        isNull,
      );
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      '320px $brightness grid fills width and overlays retain every course at 2x text',
      (tester) async {
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          app(
            WeekScheduleView(data: scheduleWeekFromDynamic(payload(1))!),
            scale: 2,
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(const ValueKey('schedule-grid'))).width,
          320,
        );
        final first = tester.getRect(
          find.byKey(const ValueKey('schedule-course-1-0')),
        );
        final second = tester.getRect(
          find.byKey(const ValueKey('schedule-course-1-1')),
        );
        expect(first.left, second.left);
        expect(first.width, second.width);
        expect(second.right, lessThanOrEqualTo(320));
        expect(find.textContaining('classes overlap'), findsOneWidget);
        expect(find.textContaining('Period A'), findsOneWidget);
        expect(find.textContaining('Second course'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('schedule-course-1-1')));
        await tester.pumpAndSettle();
        expect(find.text('First course'), findsOneWidget);
        expect(find.text('Second course'), findsOneWidget);
        await tester.tap(find.text('First course'));
        await tester.pumpAndSettle();
        expect(find.text('Room A'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'week strip previews distinguish unknown and tapping selects the week',
    (tester) async {
      int? selected;
      final previews = scheduleWeekFromDynamic(payload(1))!.weekPreviews!;
      await tester.pumpWidget(
        app(
          ScheduleWeekPicker(
            week: 1,
            maxWeek: 25,
            previews: previews,
            onChanged: (w) => selected = w,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('schedule-preview-1')), findsOneWidget);
      expect(
        tester
            .widget<Tooltip>(
              find.ancestor(
                of: find.byKey(const ValueKey('schedule-week-1')),
                matching: find.byType(Tooltip),
              ),
            )
            .message,
        '2 classes',
      );
      expect(
        tester
            .widget<Tooltip>(
              find.ancestor(
                of: find.byKey(const ValueKey('schedule-week-2')),
                matching: find.byType(Tooltip),
              ),
            )
            .message,
        'Preview unavailable',
      );
      await tester.tap(find.byKey(const ValueKey('schedule-week-2')));
      expect(selected, 2);
    },
  );

  testWidgets(
    'swipes select adjacent weeks and respect the first week boundary',
    (tester) async {
      final selected = <int>[];
      await tester.pumpWidget(
        app(
          WeekScheduleView(
            data: scheduleWeekFromDynamic(payload(2))!,
            onWeekChanged: selected.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final origin =
          tester.getTopLeft(find.byKey(const ValueKey('schedule-grid'))) +
          const Offset(250, 70);
      await tester.dragFrom(origin, const Offset(-140, 0));
      await tester.pumpAndSettle();
      await tester.dragFrom(origin, const Offset(140, 0));
      await tester.pumpAndSettle();
      expect(selected, [3, 1]);
      selected.clear();
      await tester.pumpWidget(
        app(
          WeekScheduleView(
            data: scheduleWeekFromDynamic(payload(1))!,
            onWeekChanged: selected.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.dragFrom(origin, const Offset(140, 0));
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
    },
  );

  testWidgets('school segments retain courses entirely outside their times', (
    tester,
  ) async {
    final raw = payload(1);
    ((raw['days'] as List).first['slots'] as List).add({
      'start': '0',
      'end': '0',
      'timeStart': '06:00',
      'timeEnd': '07:00',
      'courseName': 'Early course',
    });
    await tester.pumpWidget(
      app(WeekScheduleView(data: scheduleWeekFromDynamic(raw)!)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Early course'), findsOneWidget);
    expect(find.textContaining('Period A'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty weeks retain the school time segments', (tester) async {
    final raw = payload(1)..['days'] = <Object>[];
    await tester.pumpWidget(
      app(WeekScheduleView(data: scheduleWeekFromDynamic(raw)!)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Period A'), findsOneWidget);
    expect(find.textContaining('Period B'), findsOneWidget);
    expect(find.byKey(const ValueKey('schedule-course-1-0')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Sunday-start teaching weeks retain the correct weekday dates', (
    tester,
  ) async {
    final raw = payload(1)..['teachingWeekStart'] = '2025-08-31';
    final data = scheduleWeekFromDynamic(raw)!;
    expect(todaySlots(data, DateTime(2025, 9, 1)).length, 2);
    expect(todaySlots(data, DateTime(2025, 8, 31)), isEmpty);
    await tester.pumpWidget(app(WeekScheduleView(data: data)));
    await tester.pumpAndSettle();
    expect(find.text('Mon\n9/1'), findsOneWidget);
    expect(find.text('Sun\n8/31'), findsOneWidget);
    final termOnly = payload(2)
      ..remove('teachingWeekStart')
      ..['termStartDate'] = '2025-08-31';
    expect(
      todaySlots(
        scheduleWeekFromDynamic(termOnly)!,
        DateTime(2025, 9, 8),
      ).length,
      2,
    );
    expect(
      todaySlots(scheduleWeekFromDynamic(termOnly)!, DateTime(2025, 9, 1)),
      isEmpty,
    );
  });

  testWidgets(
    'selecting a week queries it once and leaving discards its pending result',
    (tester) async {
      final session = ScheduleSession();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        app(
          const HomeCardPresentation(
            size: HomeCardSize.expanded,
            isPage: true,
            child: ScheduleSection(),
          ),
          session: session,
        ),
      );
      await tester.pumpAndSettle();
      expect(session.requestedWeeks, [1]);
      session.gate = Completer<CapabilityRun>();
      await tester.tap(find.byKey(const ValueKey('schedule-week-2')));
      await tester.pump();
      expect(session.requestedWeeks, [1, 2]);
      expect(find.byType(WeekScheduleView), findsNothing);
      await tester.pumpWidget(app(const Text('Left page'), session: session));
      session.gate!.complete(CapabilityRun.ok(payload(2)));
      await tester.pumpAndSettle();
      expect(find.text('Left page'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
