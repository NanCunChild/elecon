import 'dart:async';
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

class ClimateSession extends SessionController {
  final calls = <String>[];
  Map<String, dynamic>? commandParams;
  Completer<CapabilityRun>? sendGate, readGate;
  bool failSend = false, failRead = false, loggedOut = false;
  Map<String, dynamic> device = syntheticClimateDevice();
  Map<String, dynamic> state = {
    'deviceId': syntheticDeviceId,
    'power': false,
    'mode': 'cool',
    'fanSpeed': 'auto',
    'targetTemperature': 26,
  };
  @override
  void logout() {
    loggedOut = true;
    super.logout();
  }

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
    if (capability == 'climate.devices') {
      return CapabilityRun.ok({
        'items': loggedOut ? [] : [device],
      });
    }
    if (capability == 'climate.command') {
      commandParams = params;
      if (failSend) throw TimeoutException('synthetic send timeout');
      return sendGate == null
          ? const CapabilityRun.ok({'status': 'accepted'})
          : await sendGate!.future;
    }
    if (failRead) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'synthetic read failure',
      );
    }
    return readGate == null
        ? CapabilityRun.ok(Map<String, dynamic>.from(state))
        : await readGate!.future;
  }
}

class UnconfiguredClimateSession extends ClimateSession {
  bool configured = false;
  final setupRequests = <Map<String, dynamic>?>[];

  @override
  Future<CapabilityRun> runCapability(
    String capability, {
    Map<String, dynamic>? params,
    bool interactive = true,
    String? htmlStdlib,
    void Function(String, String)? onLog,
    void Function(AdapterDiagnostic)? onDiagnostic,
  }) {
    if (capability == 'climate.devices') {
      setupRequests.add(params);
      if (params?['configure'] == true) configured = true;
      if (!configured) {
        return Future.value(
          const CapabilityRun.failed(
            CapabilityFailureKind.configuration,
            'configuration_required',
          ),
        );
      }
    }
    return super.runCapability(
      capability,
      params: params,
      interactive: interactive,
    );
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
  androidTest('power-only device operates without unrelated thermostat state', (
    tester,
  ) async {
    final session = ClimateSession()
      ..device = {
        'deviceId': syntheticDeviceId,
        'label': 'Synthetic power-only device',
        'commands': ['power'],
      }
      ..state = {'deviceId': syntheticDeviceId, 'power': false};
    addTearDown(session.dispose);
    await tester.pumpWidget(app(session, const ClimateSection()));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(powerSwitch()).onChanged, isNotNull);
    expect(find.byTooltip('Increase target temperature'), findsNothing);
    session.calls.clear();
    tester.widget<SwitchListTile>(powerSwitch()).onChanged!(true);
    await tester.pumpAndSettle();
    expect(session.calls, ['climate.command', 'climate.status']);
    expect(session.commandParams!['settings'], {'power': true});
    expect(tester.widget<SwitchListTile>(powerSwitch()).value, isFalse);
    expect(tester.takeException(), isNull);
  });

  androidTest('offline device retains its binding and unknown readings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = ClimateSession()..failRead = true;
    addTearDown(session.dispose);
    await tester.pumpWidget(app(session, const ClimateSection(), scale: 2));
    await tester.pumpAndSettle();
    expect(find.textContaining('Synthetic room'), findsOneWidget);
    expect(find.text('Indoor temperature'), findsOneWidget);
    expect(find.text('— ℃'), findsOneWidget);
    expect(find.byTooltip('Increase target temperature'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton &&
                  widget.tooltip == 'Increase target temperature',
            ),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  androidTest(
    'climate shows incomplete setup and only the setup button opens configuration',
    (tester) async {
      final session = UnconfiguredClimateSession();
      addTearDown(session.dispose);
      await tester.pumpWidget(app(session, const ClimateSection()));
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ClimateSection)),
      );
      expect(find.text(l10n.capabilityConfigurationRequired), findsOneWidget);
      expect(find.text(l10n.campusLoadFailed), findsNothing);
      expect(session.setupRequests, [<String, dynamic>{}]);
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(session.configured, isFalse);
      await tester.tap(find.text(l10n.capabilityCompleteConfiguration));
      await tester.pumpAndSettle();
      expect(session.setupRequests.last, {'configure': true});
      expect(find.text(l10n.capabilityConfigurationRequired), findsNothing);
      expect(powerSwitch(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  androidTest(
    'launcher opens feature page without querying and retain meter selection and history',
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
      await tester.tap(find.byTooltip('Refresh').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('Synthetic water meter · SYNTHETIC-WATER').last,
      );
      await tester.pumpAndSettle();
      expect(find.byType(DataTable), findsOneWidget);
      await tester.pageBack();
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

  androidTest(
    'climate summary triggers an ordinary command without a confirmation dialog',
    (tester) async {
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
      await until(
        tester,
        () => find
            .textContaining('Target temperature: 26 ℃')
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text('Synthetic room'), findsOneWidget);
      expect(find.textContaining('Indoor temperature: — ℃'), findsOneWidget);
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
      await until(
        tester,
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.widget<SwitchListTile>(powerSwitch()).value, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

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
      await tester.tap(find.byTooltip('Refresh').first);
      await tester.pumpAndSettle();
      expect(find.text('Remaining'), findsNothing);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('Synthetic water meter · SYNTHETIC-WATER').last,
      );
      await tester.pumpAndSettle();
      expect(find.text('12.5 m³'), findsNWidgets(2));
      expect(session.lastParams, {'meterId': 'SYNTHETIC-WATER'});
      expect(find.byType(DataTable), findsOneWidget);
      session.fail = true;
      await tester.tap(find.byTooltip('Refresh').first);
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
    'one event sends once then reads once, without optimistic state',
    (tester) async {
      final session = ClimateSession();
      addTearDown(session.dispose);
      await tester.pumpWidget(app(session, const ClimateSection()));
      await tester.pumpAndSettle();
      session.calls.clear();
      session.sendGate = Completer<CapabilityRun>();
      session.readGate = Completer<CapabilityRun>();
      final trigger = tester.widget<SwitchListTile>(powerSwitch()).onChanged!;
      trigger(true);
      trigger(true);
      await tester.pump();
      expect(session.calls, ['climate.command']);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.widget<SwitchListTile>(powerSwitch()).value, isFalse);
      expect(tester.widget<SwitchListTile>(powerSwitch()).onChanged, isNull);
      session.sendGate!.complete(
        const CapabilityRun.ok({'status': 'accepted'}),
      );
      await tester.pump();
      expect(session.calls, ['climate.command', 'climate.status']);
      expect(tester.widget<SwitchListTile>(powerSwitch()).value, isFalse);
      session.readGate!.complete(
        CapabilityRun.ok({...session.state, 'power': true}),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(powerSwitch()).value, isTrue);
      expect(session.commandParams, {
        'deviceId': syntheticDeviceId,
        'command': 'power',
        'settings': {'power': true},
      });
      expect(tester.takeException(), isNull);
    },
  );
  for (final failure in ['send', 'read', 'rejected']) {
    androidTest(
      '$failure failure never resends control and synchronizes once',
      (tester) async {
        final session = ClimateSession();
        addTearDown(session.dispose);
        await tester.pumpWidget(app(session, const ClimateSection()));
        await tester.pumpAndSettle();
        session.calls.clear();
        session.failSend = failure == 'send';
        session.failRead = failure == 'read';
        if (failure == 'rejected') {
          session.sendGate = Completer<CapabilityRun>()
            ..complete(const CapabilityRun.ok({'status': 'rejected'}));
        }
        tester.widget<SwitchListTile>(powerSwitch()).onChanged!(true);
        await tester.pumpAndSettle();
        expect(session.calls, ['climate.command', 'climate.status']);
        expect(find.byType(AlertDialog), findsNothing);
        if (failure == 'read') {
          expect(powerSwitch(), findsNothing);
          expect(
            find.text('State unknown. Refresh before operating.'),
            findsWidgets,
          );
        } else {
          expect(tester.widget<SwitchListTile>(powerSwitch()).value, isFalse);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  androidTest(
    'mode sends complete coupled settings through ordinary capability',
    (tester) async {
      final session = ClimateSession();
      addTearDown(session.dispose);
      await tester.pumpWidget(app(session, const ClimateSection()));
      await tester.pumpAndSettle();
      session.calls.clear();
      final mode = find.byWidgetPredicate(
        (w) => w is DropdownButton<String> && w.value == 'cool',
      );
      tester.widget<DropdownButton<String>>(mode).onChanged!('heat');
      await tester.pumpAndSettle();
      expect(session.calls, ['climate.command', 'climate.status']);
      expect(session.commandParams!['settings'], {
        'mode': 'heat',
        'targetTemperature': 23,
        'fanSpeed': 'auto',
        'turbo': false,
        'auxiliaryHeat': false,
        'indoorClean': false,
        'outdoorClean': false,
      });
      expect(tester.widget<DropdownButton<String>>(mode).value, 'cool');
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
  for (final leave in ['logout', 'page']) {
    androidTest(
      '$leave invalidates a pending send and prevents its follow-up read',
      (tester) async {
        final session = ClimateSession();
        addTearDown(session.dispose);
        await tester.pumpWidget(app(session, const ClimateSection()));
        await tester.pumpAndSettle();
        session.calls.clear();
        session.sendGate = Completer<CapabilityRun>();
        tester.widget<SwitchListTile>(powerSwitch()).onChanged!(true);
        await tester.pump();
        if (leave == 'logout') {
          session.logout();
        } else {
          await tester.pumpWidget(app(session, const SizedBox()));
        }
        await tester.pump();
        session.sendGate!.complete(
          const CapabilityRun.ok({'status': 'accepted'}),
        );
        await tester.pumpAndSettle();
        expect(
          session.calls.where((c) => c == 'climate.command'),
          hasLength(1),
        );
        expect(session.calls.where((c) => c == 'climate.status'), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
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
