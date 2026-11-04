// Synthetic rooms through the real script runtime and parameterized cache.
import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/capability_sections.dart';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/capability_source.dart';
import 'package:elecon/ui/home/classroom_timeline.dart';
import 'package:elecon_contract/classroom_buildings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage _school({
  String schemaVersion = '1.1',
  bool includeIntervals = false,
  bool controls = false,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 4,
      'id': 'classroom-cache-synthetic',
      'schoolId': 'classroom-cache-synthetic',
      'version': '1.0.0',
      'name': 'Synthetic classroom school',
      'browser': false,
      'network': {'origins': []},
      'capabilities': [
        for (final capability in [
          'classroom.buildings',
          'classroom.available',
          if (controls) 'query.controls',
        ])
          {
            'id': capability,
            'schema': 'elecon.$capability',
            'schemaVersion': capability == 'classroom.available'
                ? schemaVersion
                : '1.0',
          },
      ],
      'home': [
        for (final capability in ['classroom.buildings', 'classroom.available'])
          {'capability': capability, 'ttlSeconds': 3600, 'preload': false},
      ],
    },
    'source':
        '''
      const buildings = [
        {buildingId:'synthetic-a',building:'Synthetic hall A',campus:'Synthetic campus'},
        {buildingId:'synthetic-b',building:'Synthetic hall B',campus:'Synthetic campus'}
      ];
      export const capabilities = {
        ${controls ? "'query.controls': async () => ({target:'classroom.available',title:'School room conditions',submitLabel:'Find school rooms',controls:[{id:'date',kind:'date',parameter:'date',label:'School date'},{id:'room',kind:'text',parameter:'room',label:'Room name'},{id:'time',kind:'timeRange',parameter:'start',label:'School local time'}]})," : ""}
        'classroom.buildings': async () => ({items:buildings}),
        'classroom.available': async (ctx, params) => {
          const building = buildings.find(item => item.buildingId === params.buildingId);
          if (!building || building.building !== params.building || building.campus !== params.campus) {
            throw new Error('synthetic_building_parameters_mismatch');
          }
          return {
            date:params.date,
            items:[{...building,room:params.room ? params.room+' '+params.start+'–'+params.end : 'Synthetic room '+params.buildingId,occupied:false,status:'available',
              ...($includeIntervals ? {intervals:[{
                startAt:params.date+'T08:00:00Z',endAt:params.date+'T09:00:00Z',
                status:'available',reason:'Synthetic interval evidence'
              }]} : {})}]
          };
        }
      };
    ''',
  }),
);

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var count = 0; count < 300; count++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Synthetic classroom cache did not settle');
}

void main() {
  for (final version in ['1.1', '1.2']) {
    for (final bound in [false, true]) {
      testWidgets(
        '$version ${bound ? 'bound' : 'default'} source interprets intervals by approved schema in cache and fresh query',
        (tester) async {
          rootBundle.clear();
          tester.view.physicalSize = const Size(480, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final now = DateTime.now();
          final date =
              '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
          final params = {
            'date': date,
            'buildingId': 'synthetic-a',
            'building': 'Synthetic hall A',
            'campus': 'Synthetic campus',
          };
          final package = _school(
            schemaVersion: version,
            includeIntervals: true,
          );
          final session = (await tester.runAsync(() async {
            final session = SessionController();
            await session.bootstrap();
            await session.installTrustedScript(
              package,
              approvedDigest: package.digest,
            );
            await session.selectTrustedScriptSchool(package.manifest.schoolId);
            expect(
              (await session.runCapability('classroom.buildings')).ok,
              isTrue,
            );
            expect(
              (await session.runCapability(
                'classroom.available',
                params: params,
              )).ok,
              isTrue,
            );
            final cached = await session.cachedCapability(
              'classroom.available',
              params: params,
            );
            expect(
              ((cached!.data as Map)['items'] as List).single['intervals'],
              isNotEmpty,
            );
            return session;
          }))!;
          addTearDown(session.dispose);
          final content = const HomeCardPresentation(
            size: HomeCardSize.expanded,
            isPage: true,
            child: ClassroomSection(),
          );
          await tester.pumpWidget(
            SessionScope(
              controller: session,
              child: MaterialApp(
                locale: const Locale('en'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: SingleChildScrollView(
                    child: bound
                        ? CapabilitySourceScope(
                            source: CapabilitySource(
                              packageId: package.manifest.id,
                              digest: package.digest,
                            ),
                            child: content,
                          )
                        : content,
                  ),
                ),
              ),
            ),
          );
          await _until(
            tester,
            () => find
                .textContaining('Synthetic room synthetic-a')
                .evaluate()
                .isNotEmpty,
          );
          expect(
            find.byType(ClassroomTimeline),
            version == '1.2' ? findsOneWidget : findsNothing,
          );
          final revision = session.homeDataRevision;
          await tester.ensureVisible(find.byTooltip('Refresh').first);
          await tester.tap(find.byTooltip('Refresh').first);
          await _until(tester, () => session.homeDataRevision > revision);
          await tester.pumpAndSettle();
          expect(
            find.byType(ClassroomTimeline),
            version == '1.2' ? findsOneWidget : findsNothing,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'script conditions submit exact room and same-day times to the classroom query and cache',
    (tester) async {
      tester.view.physicalSize = const Size(480, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final p = _school(controls: true);
      final initial = {
        'date': '2026-11-03',
        'buildingId': 'synthetic-a',
        'building': 'Synthetic hall A',
        'campus': 'Synthetic campus',
      };
      final session = (await tester.runAsync(() async {
        final s = SessionController();
        await s.bootstrap();
        await s.installTrustedScript(p, approvedDigest: p.digest);
        await s.selectTrustedScriptSchool(p.manifest.id);
        expect((await s.runCapability('classroom.buildings')).ok, isTrue);
        expect(
          (await s.runCapability('classroom.available', params: initial)).ok,
          isTrue,
        );
        return s;
      }))!;
      addTearDown(session.dispose);
      await tester.pumpWidget(
        SessionScope(
          controller: session,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: SingleChildScrollView(
                child: HomeCardPresentation(
                  size: HomeCardSize.expanded,
                  isPage: true,
                  child: ClassroomSection(),
                ),
              ),
            ),
          ),
        ),
      );
      await _until(
        tester,
        () =>
            find.text('Filters').evaluate().isNotEmpty &&
            find
                .textContaining('Synthetic room synthetic-a')
                .evaluate()
                .isNotEmpty,
      );
      await tester.tap(find.text('Filters'));
      await _until(
        tester,
        () => find.text('School room conditions').evaluate().isNotEmpty,
      );
      for (final entry in {
        'date': '2026-11-05',
        'room': 'Chosen room',
        'start': '09:15',
        'end': '10:35',
      }.entries) {
        await tester.enterText(
          find.byKey(ValueKey('query-control-${entry.key}')),
          entry.value,
        );
      }
      expect(find.textContaining('Chosen room 09:15'), findsNothing);
      await tester.tap(find.text('Find school rooms'));
      await _until(
        tester,
        () => find
            .textContaining('Chosen room 09:15–10:35')
            .evaluate()
            .isNotEmpty,
      );
      final expected = {
        ...initial,
        'date': '2026-11-05',
        'room': 'Chosen room',
        'start': '09:15',
        'end': '10:35',
      };
      final cached = await tester.runAsync(
        () => session.cachedCapability('classroom.available', params: expected),
      );
      expect(cached?.params, expected);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('changing buildings survives restore and queries the selected building', (
    tester,
  ) async {
    rootBundle.clear();
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final oldParams = {
      'date': date,
      'buildingId': 'synthetic-a',
      'building': 'Synthetic hall A',
      'campus': 'Synthetic campus',
    };
    final session = (await tester.runAsync(() async {
      final session = SessionController();
      await session.bootstrap();
      final package = _school();
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
      await session.selectTrustedScriptSchool(package.manifest.schoolId);
      // Warm up QuickJS in the real async zone and seed both production caches.
      expect((await session.runCapability('classroom.buildings')).ok, isTrue);
      expect(
        (await session.runCapability(
          'classroom.available',
          params: oldParams,
        )).ok,
        isTrue,
      );
      expect(await session.cachedCapability('classroom.buildings'), isNotNull);
      expect(
        (await session.cachedCapability(
          'classroom.available',
          params: oldParams,
        ))?.params,
        oldParams,
      );
      return session;
    }))!;
    addTearDown(session.dispose);

    await tester.pumpWidget(
      SessionScope(
        controller: session,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SingleChildScrollView(
              child: HomeCardPresentation(
                size: HomeCardSize.expanded,
                isPage: true,
                child: ClassroomSection(),
              ),
            ),
          ),
        ),
      ),
    );
    final dropdown = find.byType(DropdownButton<ClassroomBuildingsItems>);
    await _until(
      tester,
      () =>
          dropdown.evaluate().isNotEmpty &&
          find
              .textContaining('Synthetic room synthetic-a')
              .evaluate()
              .isNotEmpty,
    );
    expect(
      tester
          .widget<DropdownButton<ClassroomBuildingsItems>>(dropdown)
          .value
          ?.buildingId,
      'synthetic-a',
    );
    final buildingB = tester
        .widget<DropdownButton<ClassroomBuildingsItems>>(dropdown)
        .items!
        .singleWhere((item) => item.value?.buildingId == 'synthetic-b')
        .value!;

    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synthetic hall B').last);
    // Each cache decode creates new directory objects. Wait for that replacement,
    // not merely the synchronous selection, to exercise the original regression.
    await _until(tester, () {
      final selected = tester
          .widget<DropdownButton<ClassroomBuildingsItems>>(dropdown)
          .value;
      return selected?.buildingId == 'synthetic-b' &&
          !identical(selected, buildingB);
    });
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButton<ClassroomBuildingsItems>>(dropdown)
          .value
          ?.buildingId,
      'synthetic-b',
    );
    expect(find.textContaining('Synthetic room synthetic-a'), findsNothing);

    await tester.ensureVisible(find.byTooltip('Refresh').first);
    await tester.tap(find.byTooltip('Refresh').first);
    await _until(
      tester,
      () => find
          .textContaining('Synthetic room synthetic-b')
          .evaluate()
          .isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButton<ClassroomBuildingsItems>>(dropdown)
          .value
          ?.buildingId,
      'synthetic-b',
    );
    final queried = await tester.runAsync(
      () => session.cachedCapability(
        'classroom.available',
        params: {
          ...oldParams,
          'buildingId': 'synthetic-b',
          'building': 'Synthetic hall B',
        },
      ),
    );
    expect(queried, isNotNull);
    expect(queried!.params['buildingId'], 'synthetic-b');
    expect(
      ((queried.data as Map)['items'] as List).single['buildingId'],
      'synthetic-b',
    );
    expect(tester.takeException(), isNull);
  });
}
