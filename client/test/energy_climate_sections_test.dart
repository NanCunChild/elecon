// ADR-040: fixed schema cards, adaptive layout and no optimistic device changes.
import 'package:elecon/core/adapter_service.dart';
import 'package:elecon/core/loader/diagnostics.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/energy_climate_sections.dart';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/editable_card_board.dart';
import 'package:elecon/ui/home/card_layout_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/climate_fixture.dart';

class EnergySession extends SessionController {
  bool fail = false;
  Map<String, dynamic>? lastParams;
  @override
  Future<CapabilityRun> runCapability(
    String capability, {
    Map<String, dynamic>? params,
    bool interactive = true,
    String? htmlStdlib,
    void Function(String, String)? onLog,
    void Function(AdapterDiagnostic)? onDiagnostic,
  }) async {
    if (fail) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'synthetic-failure',
      );
    }
    if (capability == 'energy.meters') {
      return const CapabilityRun.ok({
        'items': [
          {
            'meterId': 'SYNTHETIC-WATER',
            'type': 'water',
            'label': 'Synthetic water meter',
            'unit': 'm³',
            'remaining': 12.5,
            'lastReadDate': '2026-10-30',
          },
        ],
      });
    }
    lastParams = params;
    return const CapabilityRun.ok({
      'items': [
        {
          'meterId': 'SYNTHETIC-WATER',
          'type': 'water',
          'unit': 'm³',
          'usage': 2.5,
          'reading': 12.5,
          'previousReading': 10,
          'readAt': '2026-10-30T00:00:00Z',
        },
      ],
    });
  }
}

Widget app(SessionController session, Widget child, {double scale = 1}) =>
    SessionScope(
      controller: session,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );
Future<void> until(WidgetTester tester, bool Function() ready) async {
  for (var n = 0; n < 300; n++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Synthetic UI did not settle');
}

Future<SessionController> prepare(WidgetTester tester) async {
  final session = (await tester.runAsync(() async {
    final session = SessionController();
    final p = syntheticClimatePackage();
    await session.installTrustedScript(p, approvedDigest: p.digest);
    await session.selectTrustedScriptSchool(p.manifest.id);
    expect((await session.runCapability('profile.me')).ok, isTrue);
    expect((await session.runCapability('climate.devices')).ok, isTrue);
    expect(
      (await session.runCapability(
        'climate.status',
        params: {'deviceId': syntheticDeviceId},
      )).ok,
      isTrue,
    );
    return session;
  }))!;
  addTearDown(session.dispose);
  return session;
}

Finder powerSwitch() => find.byWidgetPredicate(
  (w) => w is SwitchListTile && (w.title as Text).data == 'Power',
);

void androidTest(String name, WidgetTesterCallback callback) => testWidgets(
  name,
  callback,
  variant: TargetPlatformVariant.only(TargetPlatform.android),
);
void iosTest(String name, WidgetTesterCallback callback) => testWidgets(
  name,
  callback,
  variant: TargetPlatformVariant.only(TargetPlatform.iOS),
);

class _LayoutMemory extends CardLayoutStore {
  HomeCardLayout value = HomeCardLayout();
  @override
  Future<HomeCardLayout> load(String scope) async => value;
  @override
  Future<void> save(String scope, HomeCardLayout layout) async {
    value = layout;
  }
}

void main() {
  androidTest(
    'launcher summaries expand without querying and retain meter selection and history',
    (tester) async {
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = EnergySession();
      addTearDown(session.dispose);
      final store = _LayoutMemory();
      await tester.pumpWidget(
        app(
          session,
          EditableCardBoard(
            scopeId: 'synthetic',
            store: store,
            cards: [
              HomeCardEntry(
                id: 'energy',
                label: 'Energy',
                icon: Icons.bolt,
                builder: (_) => const EnergySection(),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.text('View meters'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('home-card:energy')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View meters'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('Synthetic water meter · SYNTHETIC-WATER').last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('View usage history'));
      await tester.pumpAndSettle();
      expect(find.byType(DataTable), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-card-close:energy')));
      await tester.pumpAndSettle();
      expect(find.text('12.5 m³'), findsOneWidget);
      expect(find.byType(DataTable), findsNothing);
      await tester.longPress(find.byKey(const ValueKey('home-card:energy')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('home-card:energy')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('home-card-size:compact')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('12.5 m³'), findsNothing);
      session.fail =
          true; // Expanding must use the mounted result, not query again.
      await tester.tap(find.byKey(const ValueKey('home-card-open:energy')));
      await tester.pumpAndSettle();
      expect(find.byType(DataTable), findsOneWidget);
      expect(session.lastParams, {'meterId': 'SYNTHETIC-WATER'});
      expect(
        find.text(
          'Could not load data. Check your connection or sign in and retry.',
        ),
        findsNothing,
      );
      expect(store.value.sizes['energy'], HomeCardSize.compact);
      expect(tester.takeException(), isNull);
    },
  );

  androidTest('climate summary opens existing confirmed control path', (
    tester,
  ) async {
    final session = await prepare(tester);
    await tester.pumpWidget(
      app(
        session,
        EditableCardBoard(
          scopeId: 'synthetic',
          store: _LayoutMemory(),
          cards: [
            HomeCardEntry(
              id: 'climate',
              label: 'Climate',
              icon: Icons.ac_unit,
              builder: (_) => const ClimateSection(),
            ),
          ],
        ),
      ),
    );
    await until(tester, () => find.text('26 ℃').evaluate().isNotEmpty);
    expect(powerSwitch(), findsNothing);
    await tester.tap(find.byKey(const ValueKey('home-card:climate')));
    await until(
      tester,
      () =>
          powerSwitch().evaluate().isNotEmpty &&
          tester.widget<SwitchListTile>(powerSwitch()).onChanged != null,
    );
    expect(tester.widget<SwitchListTile>(powerSwitch()).value, isFalse);
    await tester.pumpAndSettle();
    await tester.ensureVisible(powerSwitch());
    await tester.pumpAndSettle();
    await tester.tap(powerSwitch());
    await until(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(powerSwitch()).value, isFalse);
    expect(tester.takeException(), isNull);
  });

  androidTest(
    'water card selects an actual meter and keeps values visible after read failure',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = EnergySession();
      addTearDown(session.dispose);
      await tester.pumpWidget(app(session, const EnergySection(), scale: 1.5));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View meters'));
      await tester.pumpAndSettle();
      expect(find.text('Remaining'), findsNothing);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('Synthetic water meter · SYNTHETIC-WATER').last,
      );
      await tester.pumpAndSettle();
      expect(find.text('12.5 m³'), findsOneWidget);
      await tester.tap(find.text('View usage history'));
      await tester.pumpAndSettle();
      expect(session.lastParams, {'meterId': 'SYNTHETIC-WATER'});
      expect(find.byType(DataTable), findsOneWidget);
      session.fail = true;
      await tester.tap(find.text('View meters'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Could not load data. Check your connection or sign in and retry.',
        ),
        findsOneWidget,
      );
      expect(find.text('12.5 m³'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  androidTest(
    'power stays unchanged through confirmation and cancelled control',
    (tester) async {
      final session = await prepare(tester);
      await tester.pumpWidget(app(session, const ClimateSection()));
      await until(
        tester,
        () =>
            powerSwitch().evaluate().isNotEmpty &&
            tester.widget<SwitchListTile>(powerSwitch()).onChanged != null,
      );
      expect(tester.widget<SwitchListTile>(powerSwitch()).value, isFalse);
      await tester.tap(powerSwitch());
      await until(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
      expect(tester.widget<SwitchListTile>(powerSwitch()).value, isFalse);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(powerSwitch()).value, isFalse);
      expect(find.textContaining('Operation cancelled'), findsOneWidget);
    },
  );
  androidTest(
    'mode selection keeps verified old value while showing every coupled setting',
    (tester) async {
      final session = await prepare(tester);
      await tester.pumpWidget(app(session, const ClimateSection()));
      await until(
        tester,
        () =>
            find.byType(DropdownButton<String>).evaluate().length >= 2 &&
            powerSwitch().evaluate().isNotEmpty &&
            tester.widget<SwitchListTile>(powerSwitch()).onChanged != null,
      );
      final mode = find.byWidgetPredicate(
        (w) => w is DropdownButton<String> && w.value == 'cool',
      );
      await tester.ensureVisible(mode);
      await tester.tap(mode);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Heat').last);
      await until(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
      expect(tester.widget<DropdownButton<String>>(mode).value, 'cool');
      final dialog = find.byType(AlertDialog);
      for (final label in [
        'Target temperature',
        'Fan speed',
        'Turbo',
        'Auxiliary heat',
        'Indoor cleaning',
        'Outdoor cleaning',
      ]) {
        expect(
          find.descendant(of: dialog, matching: find.text(label)),
          findsOneWidget,
        );
      }
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.widget<DropdownButton<String>>(mode).value, 'cool');
      expect(tester.takeException(), isNull);
    },
  );
  androidTest('logout closes pending confirmation and hides old device state', (
    tester,
  ) async {
    final session = await prepare(tester);
    await tester.pumpWidget(app(session, const ClimateSection()));
    await until(
      tester,
      () =>
          powerSwitch().evaluate().isNotEmpty &&
          tester.widget<SwitchListTile>(powerSwitch()).onChanged != null,
    );
    await tester.tap(powerSwitch());
    await until(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
    session.logout();
    await tester.pump();
    await until(
      tester,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(powerSwitch(), findsNothing);
    expect(tester.takeException(), isNull);
    await until(
      tester,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );
  });
  iosTest(
    'non Android still reads device state but exposes disabled controls',
    (tester) async {
      final session = await prepare(tester);
      await tester.pumpWidget(app(session, const ClimateSection()));
      await until(
        tester,
        () =>
            powerSwitch().evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(tester.widget<SwitchListTile>(powerSwitch()).onChanged, isNull);
      expect(
        find.text('This platform supports viewing device state only.'),
        findsOneWidget,
      );
    },
  );
}
