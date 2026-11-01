import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/adapter_service.dart';
import 'package:elecon/core/loader/diagnostics.dart';
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

void main() {
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
