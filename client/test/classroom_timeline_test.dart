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
      expect(
        outputValidatorFor('elecon.classroom.available', '1.3')!(payload),
        isFalse,
      );
      expect(outputValidatorFor('elecon.classroom.available', '1.4'), isNull);
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
    'room rows expose occupancy reasons in their intervals with no second filter or selected-room footer',
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
      expect(find.byType(FilterChip), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Synthetic hall Synthetic room'), findsOneWidget);
      expect(find.text('Synthetic hall Second room'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Synthetic source reason').first);
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          ' · Occupied\nSynthetic source reason',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('Synthetic hall Second room'), findsOneWidget);
    },
  );

  testWidgets(
    'narrow dark layout keeps each room attributes beside its bar without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final first = room([('08:00', '09:00', 'occupied')]);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ClassroomTimeline(
                  now: at('08:30'),
                  rooms: [
                    ClassroomAvailableItems(
                      building: 'Synthetic hall',
                      room: 'Room 101',
                      floor: '3',
                      capacity: 80,
                      roomType: const ClassroomAvailableItemsRoomType(
                        label: 'Laboratory',
                      ),
                      teachingCapacity: 80,
                      examCapacity: 40,
                      intervals: first.intervals,
                    ),
                    const ClassroomAvailableItems(
                      building: 'Synthetic hall',
                      room: 'Room 102',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('Teaching seats: 80'), findsOneWidget);
      expect(find.textContaining('Floor: 3 · Seats: 80'), findsOneWidget);
      expect(find.text('Synthetic hall Room 102'), findsOneWidget);
      expect(find.textContaining('reliable exact times'), findsOneWidget);
      expect(find.byType(FilterChip), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow intervals omit clipped labels but retain their tap details',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ClassroomTimeline(
              now: at('12:00'),
              rooms: [
                ClassroomAvailableItems(
                  building: 'Hall',
                  room: '101',
                  intervals: [
                    ClassroomAvailableItemsIntervals(
                      startAt: at('08:00').toIso8601String(),
                      endAt: at('08:15').toIso8601String(),
                      status: 'occupied',
                      reason: 'Narrow source reason',
                    ),
                    ClassroomAvailableItemsIntervals(
                      startAt: at('08:15').toIso8601String(),
                      endAt: at('18:00').toIso8601String(),
                      status: 'occupied',
                      reason: 'Wide source reason',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Narrow source reason'), findsNothing);
      expect(find.text('Wide source reason'), findsOneWidget);
      final narrowInterval = find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            widget.message?.contains('Narrow source reason') == true,
      );
      expect(narrowInterval, findsOneWidget);
      await tester.tap(narrowInterval);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Narrow source reason', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing precise intervals still show room entries and their attributes',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ClassroomTimeline(
              now: at('08:30'),
              rooms: const [
                ClassroomAvailableItems(
                  building: 'Hall',
                  room: '101',
                  floor: '2',
                  capacity: 50,
                  intervals: [],
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Hall 101'), findsOneWidget);
      expect(find.textContaining('Floor: 2 · Seats: 50'), findsOneWidget);
      expect(find.textContaining('reliable exact times'), findsOneWidget);
    },
  );
}
