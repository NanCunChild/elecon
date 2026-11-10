import 'dart:convert';
import 'package:elecon/core/schedule/calendar_export.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/ui/home/models.dart';
import 'package:elecon/ui/home/personal_schedule.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';

PersonalCourse personal({String date = '2026-11-10'}) => PersonalCourse(
  id: '0123456789abcdef0123456789abcdef',
  name: 'Local lab',
  date: date,
  start: '14:00',
  end: '15:35',
  location: 'Room B',
);
ScheduleWeek schedule({String? zone = 'Asia/Shanghai'}) => ScheduleWeek(
  term: 'synthetic',
  week: 1,
  timeZone: zone,
  teachingWeekStart: '2026-11-09',
  days: [
    ScheduleWeekDays(
      dayOfWeek: 2,
      slots: [
        const ScheduleWeekDaysSlots(
          courseId: 'math',
          courseName: 'Math, lab; A\nB',
          start: '1',
          end: '2',
          timeStart: '08:30',
          timeEnd: '10:05',
          location: 'Room A',
        ),
        const ScheduleWeekDaysSlots(
          courseName: 'Cancelled',
          start: '3',
          end: '4',
          timeStart: '10:25',
          timeEnd: '12:00',
          changeType: 'cancelled',
        ),
        const ScheduleWeekDaysSlots(
          courseName: 'Exception',
          start: '3',
          end: '4',
          timeStart: '10:25',
          timeEnd: '12:00',
          weekExceptions: [1],
        ),
        const ScheduleWeekDaysSlots(
          courseName: 'Other week',
          start: '3',
          end: '4',
          timeStart: '10:25',
          timeEnd: '12:00',
          weeks: [2],
        ),
        const ScheduleWeekDaysSlots(
          courseName: 'Unknown time',
          start: '3',
          end: '4',
        ),
      ],
    ),
  ],
  termWeeks: [
    const ScheduleWeekTermWeeks(
      week: 2,
      teachingWeekStart: '2026-11-16',
      teachingWeekEnd: '2026-11-22',
      days: [
        ScheduleWeekTermWeeksDays(
          dayOfWeek: 1,
          slots: [
            ScheduleWeekTermWeeksDaysSlots(
              courseName: 'Next week',
              start: '1',
              end: '2',
              timeStart: '08:30',
              timeEnd: '10:05',
            ),
          ],
        ),
      ],
    ),
  ],
);

ScriptPackage package(String school) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 4,
      'id': 'school.$school',
      'schoolId': school,
      'name': school,
      'version': '1.0.0',
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
    'source':
        'export const capabilities={"notice.list":async()=>({items:[]})};',
  }),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('personal course editor saves, edits and removes locally', (
    tester,
  ) async {
    final session = SessionController();
    addTearDown(session.dispose);
    await tester.runAsync(() async {
      await session.bootstrap();
      final p = package('alpha');
      await session.installTrustedScript(p, approvedDigest: p.digest);
      await session.selectTrustedScriptSchool(p.manifest.id);
    });
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showPersonalCourses(context, session),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Local test');
    await tester.ensureVisible(find.text('保存课程'));
    await tester.tap(find.text('保存课程'));
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(session.personalCourses.single.name, 'Local test');
    await tester.ensureVisible(find.text('Local test'));
    await tester.tap(find.text('Local test'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Edited course');
    await tester.ensureVisible(find.text('保存课程'));
    await tester.tap(find.text('保存课程'));
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(session.personalCourses.single.name, 'Edited course');
    await tester.ensureVisible(find.byTooltip('删除'));
    await tester.tap(find.byTooltip('删除'));
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(session.personalCourses, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'export applies explicit school zone, omissions, alarms and escaping',
    () {
      final result = exportScheduleCalendar(
        schedule(),
        sourceId: 'school.synthetic',
        reminderMinutes: 15,
        personal: [personal()],
        stamp: DateTime.utc(2026, 11, 9),
      );
      expect(result.count, 2);
      expect(result.skipped, 1);
      expect(result.text, contains('DTSTART:20261110T003000Z\r\n'));
      expect(result.text, contains(r'SUMMARY:Math\, lab\; A\nB'));
      expect(result.text, contains('TRIGGER:-PT15M'));
      expect(result.text, isNot(contains('Cancelled')));
      expect(result.text, isNot(contains('Exception')));
      final full = exportScheduleCalendar(
        schedule(),
        sourceId: 'school.synthetic',
        wholeTerm: true,
      );
      expect(full.count, 2);
      expect(full.text, contains('Next week'));
      final localOutsideTerm = exportScheduleCalendar(
        schedule(),
        sourceId: 's',
        wholeTerm: true,
        personal: [personal(date: '2027-05-01')],
      );
      expect(localOutsideTerm.text, isNot(contains('Local lab')));
      final uid = result.text
          .split('\r\n')
          .where((e) => e.startsWith('UID:'))
          .first;
      expect(full.text, contains(uid));
    },
  );
  test('unknown zone and invalid clocks never use device timezone', () {
    expect(
      () => exportScheduleCalendar(schedule(zone: null), sourceId: 's'),
      throwsFormatException,
    );
    expect(
      () => exportScheduleCalendar(
        schedule(zone: 'Invalid/Nowhere'),
        sourceId: 's',
      ),
      throwsFormatException,
    );
    expect(
      () => PersonalCourse(
        id: personal().id,
        name: 'Invalid',
        date: '2026-02-30',
        start: '08:00',
        end: '09:00',
      ),
      throwsFormatException,
    );
    expect(
      () => PersonalCourse(
        id: personal().id,
        name: 'Invalid',
        date: '2026-11-10',
        start: '10:00',
        end: '09:00',
      ),
      throwsFormatException,
    );
  });
  test('folds long unicode lines at 75 UTF-8 bytes and preserves text', () {
    final name = List.filled(70, '课程😺').join();
    final data = ScheduleWeek(
      term: 't',
      week: 1,
      timeZone: 'Asia/Shanghai',
      days: [
        ScheduleWeekDays(
          dayOfWeek: 2,
          slots: [
            ScheduleWeekDaysSlots(
              courseName: name,
              start: '1',
              end: '2',
              date: '2026-11-10',
              timeStart: '08:30',
              timeEnd: '10:05',
            ),
          ],
        ),
      ],
    );
    final result = exportScheduleCalendar(data, sourceId: 's');
    for (final line in result.text.split('\r\n')) {
      expect(utf8.encode(line).length, lessThanOrEqualTo(75));
    }
    expect(result.text.replaceAll('\r\n ', ''), contains('SUMMARY:$name\r\n'));
  });
  test(
    'local composition preserves source and does not mutate cached courses',
    () {
      final original = schedule();
      final combined = withPersonalCourses(original, [
        personal(),
        personal(date: '2026-11-25'),
      ]);
      expect(combined.days.expand((e) => e.slots).length, 6);
      expect(original.days.single.slots.length, 5);
      expect(combined.termWeeks, same(original.termWeeks));
      expect(combined.timeZone, original.timeZone);
    },
  );
  test(
    'protected local courses persist and stay isolated by school and profile',
    () async {
      final blobs = InMemoryBlobStore();
      final session = SessionController(blobStoreProvider: () async => blobs);
      await session.bootstrap();
      for (final school in ['alpha', 'beta']) {
        final p = package(school);
        await session.installTrustedScript(p, approvedDigest: p.digest);
      }
      await session.selectTrustedScriptSchool('school.alpha');
      await session.ensurePersistentStore(
        confirmSoftwareFallback: () async => true,
      );
      await session.savePersonalCourse(personal());
      await session.selectTrustedScriptSchool('school.beta');
      expect(session.personalCourses, isEmpty);
      await session.selectTrustedScriptSchool('school.alpha');
      expect(session.personalCourses.single.name, 'Local lab');
      await session.flush();
      session.dispose();
      final restored = SessionController(blobStoreProvider: () async => blobs);
      addTearDown(restored.dispose);
      await restored.bootstrap();
      expect(restored.personalCourses.single.name, 'Local lab');
      final other = SessionController();
      addTearDown(other.dispose);
      await other.bootstrap();
      final p = package('alpha');
      await other.installTrustedScript(p, approvedDigest: p.digest);
      await other.selectTrustedScriptSchool(p.manifest.id);
      expect(other.personalCourses, isEmpty);
      await restored.removePersonalCourse(personal().id);
      expect(restored.personalCourses, isEmpty);
    },
  );
}
