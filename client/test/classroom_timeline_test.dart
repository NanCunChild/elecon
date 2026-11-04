import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/ui/home/classroom_timeline.dart';
import 'package:elecon/ui/home/schema_decode.dart';
import 'package:elecon_contract/classroom_available.dart';
import 'package:flutter/material.dart';
import 'package:elecon_contract/output_validator_registry.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime at(String time) => DateTime.parse('2026-11-03T$time:00Z');
ClassroomAvailableItems room(List<(String, String, String)> values) =>
    ClassroomAvailableItems(
      building: 'Synthetic hall',
      room: 'Synthetic room',
      intervals: [
        for (final (start, end, status) in values)
          ClassroomAvailableItemsIntervals(
            startAt: at(start).toIso8601String(),
            endAt: at(end).toIso8601String(),
            status: status,
            reason: 'Synthetic source reason',
          ),
      ],
    );

void main() {
  test(
    '1.2 validates interval status while 1.1 retains its original open schema',
    () {
      final payload = {
        'items': [
          {
            'building': 'Synthetic hall',
            'room': 'Synthetic room',
            'intervals': [
              {
                'startAt': '2026-11-03T08:00:00Z',
                'endAt': '2026-11-03T09:00:00Z',
                'status': 'unsupported',
              },
            ],
          },
        ],
      };
      expect(
        outputValidatorFor('elecon.classroom.available', '1.2')!(payload),
        isFalse,
      );
      expect(
        outputValidatorFor('elecon.classroom.available', '1.1')!(payload),
        isTrue,
      );
      expect(outputValidatorFor('elecon.classroom.available', '1.3'), isNull);
    },
  );

  test(
    'exact filtering requires full available coverage and respects half-open ends',
    () {
      final continuous = room([
        ('08:00', '09:00', 'available'),
        ('09:00', '10:00', 'available'),
        ('10:00', '11:00', 'occupied'),
      ]);
      expect(
        classroomAvailableDuring(continuous, at('08:30'), at('10:00')),
        isTrue,
      );
      expect(
        classroomAvailableDuring(continuous, at('08:30'), at('10:01')),
        isFalse,
      );
      expect(
        classroomAvailableDuring(continuous, at('07:59'), at('09:00')),
        isFalse,
      );
      expect(
        classroomAvailableDuring(continuous, at('09:00'), at('09:00')),
        isFalse,
      );
      final gap = room([
        ('08:00', '09:00', 'available'),
        ('09:05', '10:00', 'available'),
      ]);
      expect(classroomAvailableDuring(gap, at('08:30'), at('09:30')), isFalse);
      expect(
        classroomAvailableDuring(
          room([('08:00', '10:00', 'unknown')]),
          at('08:30'),
          at('09:30'),
        ),
        isFalse,
      );
      final conflict = room([
        ('08:00', '10:00', 'available'),
        ('09:00', '09:30', 'occupied'),
      ]);
      expect(
        classroomAvailableDuring(conflict, at('08:00'), at('08:30')),
        isFalse,
      );
      expect(
        classroomIntervals(room([('10:00', '08:00', 'available')])),
        isEmpty,
      );
    },
  );

  test(
    'decoder preserves source reasons while old aggregate cannot prove precise availability',
    () {
      final decoded = classroomAvailableFromDynamic({
        'date': '2026-11-03',
        'items': [
          {
            'building': 'Synthetic hall',
            'room': '1',
            'status': 'available',
            'intervals': [
              {
                'startAt': '2026-11-03T08:00:00Z',
                'endAt': '2026-11-03T09:00:00Z',
                'status': 'available',
                'reason': 'Synthetic evidence',
              },
            ],
          },
          {'building': 'Synthetic hall', 'room': '2', 'status': 'available'},
        ],
      }, schemaVersion: '1.2')!;
      expect(
        decoded.items!.first.intervals!.single.reason,
        'Synthetic evidence',
      );
      expect(
        classroomAvailableDuring(decoded.items!.last, at('08:00'), at('09:00')),
        isFalse,
      );
    },
  );

  testWidgets(
    'all room bars share one current-time line and expose source reasons',
    (tester) async {
      final first = room([
        ('08:00', '09:00', 'available'),
        ('09:00', '10:00', 'occupied'),
      ]);
      final second = ClassroomAvailableItems(
        building: 'Synthetic hall',
        room: 'Second room',
        intervals: first.intervals,
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: ClassroomTimeline(
                rooms: [first, second],
                now: at('08:30'),
              ),
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('classroom-current-time-line')),
        findsOneWidget,
      );
      expect(find.textContaining('Current time:'), findsOneWidget);
      expect(find.textContaining('Synthetic source reason'), findsNWidgets(2));
      expect(find.textContaining('device local time'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Second room'));
      await tester.pump();
      expect(find.text('Synthetic hall Second room'), findsOneWidget);
    },
  );
}
