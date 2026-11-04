import 'dart:async';
import 'package:elecon/core/adapter_service.dart';
import 'package:elecon/core/loader/diagnostics.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/capability_sections.dart';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/models.dart';
import 'package:elecon/ui/home/schedule_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD0sAAAAASUVORK5CYII=';

class FeatureSession extends SessionController {
  final calls = <String>[];
  final interactiveCalls = <bool>[];
  bool expired = false;
  int validitySeconds = 30;
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
    calls.add(capability);
    interactiveCalls.add(interactive);
    if (gate != null) return gate!.future;
    if (capability == 'classroom.buildings') {
      return const CapabilityRun.ok({
        'items': [
          {'buildingId': 'test', 'building': 'Synthetic hall'},
        ],
      });
    }
    if (capability == 'classroom.available') {
      return const CapabilityRun.ok({
        'items': [
          {
            'building': 'Synthetic hall',
            'room': 'Room 1',
            'occupied': false,
            'status': 'available',
          },
        ],
      });
    }
    final now = DateTime.now().toUtc();
    return CapabilityRun.ok({
      'imageBase64': png,
      'issuedAt': now.subtract(const Duration(seconds: 10)).toIso8601String(),
      'expiresAt': now
          .add(Duration(seconds: expired ? -1 : validitySeconds))
          .toIso8601String(),
    });
  }
}

Widget app(Widget child, {FeatureSession? session, double scale = 1}) {
  Widget result = MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: child is CardQrPage
        ? child
        : Scaffold(body: SingleChildScrollView(child: child)),
  );
  return session == null
      ? result
      : SessionScope(controller: session, child: result);
}

ScheduleWeek schedule({String? start = '2026-11-02'}) => ScheduleWeek(
  term: 'synthetic',
  week: 2,
  teachingWeekStart: start,
  days: const [
    ScheduleWeekDays(
      dayOfWeek: 1,
      slots: [
        ScheduleWeekDaysSlots(
          start: '1',
          end: '2',
          timeStart: '08:00',
          timeEnd: '10:00',
          courseName: 'Morning',
          location: 'Room A',
        ),
        ScheduleWeekDaysSlots(
          start: '2',
          end: '3',
          timeStart: '09:00',
          timeEnd: '11:00',
          courseName: 'Overlap',
          location: 'Room B',
        ),
      ],
    ),
    ScheduleWeekDays(
      dayOfWeek: 2,
      slots: [
        ScheduleWeekDaysSlots(start: '1', end: '2', courseName: 'Tuesday'),
      ],
    ),
  ],
);
void main() {
  test('today excludes historical weeks and unknown dates', () {
    expect(
      todaySlots(schedule(), DateTime(2026, 11, 2)).map((e) => e.courseName),
      ['Morning', 'Overlap'],
    );
    expect(todaySlots(schedule(), DateTime(2026, 11, 9)), isEmpty);
    expect(todaySlots(schedule(start: null), DateTime(2026, 11, 2)), isEmpty);
  });
  testWidgets(
    'weekly grid retains seven days and overlapping courses at large scale',
    (tester) async {
      await tester.pumpWidget(
        app(WeekScheduleView(data: schedule()), scale: 2),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Morning'), findsOneWidget);
      expect(find.textContaining('Overlap'), findsOneWidget);
      expect(find.textContaining('Sun'), findsOneWidget);
      await tester.tap(find.textContaining('Overlap'));
      await tester.pumpAndSettle();
      expect(find.text('Overlapping classes'), findsOneWidget);
      await tester.tap(find.text('Morning'));
      await tester.pumpAndSettle();
      expect(find.text('Room A'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('expanded schedule is today timeline, not other weekdays', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(ScheduleCard(schedule(), now: DateTime(2026, 11, 2))),
    );
    expect(find.text('Morning'), findsOneWidget);
    expect(find.text('Overlap'), findsOneWidget);
    expect(find.text('Tuesday'), findsNothing);
  });
  testWidgets(
    'QR-only campus card has no balance or transaction layout at narrow large text',
    (tester) async {
      final session = FeatureSession();
      addTearDown(session.dispose);
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          const CardSection(
            balanceEnabled: false,
            transactionsEnabled: false,
            qrEnabled: true,
          ),
          session: session,
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Show QR code'), findsOneWidget);
      expect(find.text('Transactions'), findsNothing);
      expect(session.calls, ['card.qr']);
      expect(find.byKey(const ValueKey('card-qr-panel')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'QR refreshes without interaction, clears in background and remasks on return',
    (tester) async {
      final session = FeatureSession();
      addTearDown(session.dispose);
      await tester.pumpWidget(app(const CardQrPage(), session: session));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(find.byKey(const ValueKey('card-qr-reveal')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('card-qr-reveal')));
      await tester.pump();
      expect(find.byKey(const ValueKey('card-qr-reveal')), findsNothing);
      await tester.pump(const Duration(seconds: 25));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(session.calls, ['card.qr', 'card.qr']);
      expect(session.interactiveCalls, [true, false]);
      expect(find.byKey(const ValueKey('card-qr-reveal')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      await tester.pump(const Duration(seconds: 90));
      expect(session.calls.length, 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(session.calls.length, 3);
      expect(find.byKey(const ValueKey('card-qr-reveal')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('QR pauses when covered by another route and reloads on return', (
    tester,
  ) async {
    final session = FeatureSession();
    addTearDown(session.dispose);
    await tester.pumpWidget(app(const CardQrPage(), session: session));
    await tester.pumpAndSettle();
    final navigator = Navigator.of(tester.element(find.byType(CardQrPage)));
    navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => const Scaffold(body: Text('Other page')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image, skipOffstage: false), findsNothing);
    await tester.pump(const Duration(seconds: 90));
    expect(session.calls, ['card.qr']);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(session.calls, ['card.qr', 'card.qr']);
    expect(session.interactiveCalls, [true, false]);
    expect(find.byKey(const ValueKey('card-qr-reveal')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sub-two-second QR is rejected without a renewal loop', (
    tester,
  ) async {
    final session = FeatureSession()..validitySeconds = 1;
    addTearDown(session.dispose);
    await tester.pumpWidget(app(const CardQrPage(), session: session));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(find.text('Unable to display QR code. Try again.'), findsOneWidget);
    await tester.pump(const Duration(minutes: 2));
    expect(session.calls, ['card.qr']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'expired QR and a late result after source change never display',
    (tester) async {
      final session = FeatureSession()..expired = true;
      addTearDown(session.dispose);
      await tester.pumpWidget(app(const CardQrPage(), session: session));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(
        find.text('Unable to display QR code. Try again.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      session.gate = Completer<CapabilityRun>();
      await tester.pumpWidget(app(const CardQrPage(), session: session));
      await tester.pump();
      session.cancelTrustedScriptRuns();
      session.gate!.complete(
        CapabilityRun.ok({
          'imageBase64': png,
          'issuedAt': DateTime.now().toUtc().toIso8601String(),
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(seconds: 30))
              .toIso8601String(),
        }),
      );
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'classroom opens with prepared search instead of a manual directory button',
    (tester) async {
      final session = FeatureSession();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        app(
          const HomeCardPresentation(
            size: HomeCardSize.expanded,
            isPage: true,
            child: ClassroomSection(),
          ),
          session: session,
        ),
      );
      await tester.pumpAndSettle();
      expect(session.calls, ['classroom.buildings']);
      expect(find.text('Synthetic hall'), findsOneWidget);
      expect(find.text('加载教学楼'), findsNothing);
      await tester.tap(find.byTooltip('Refresh').first);
      await tester.pumpAndSettle();
      expect(session.calls, ['classroom.buildings', 'classroom.available']);
      expect(find.textContaining('Room 1'), findsOneWidget);
    },
  );
}
