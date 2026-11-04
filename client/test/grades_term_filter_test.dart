// Synthetic terms and grades through the real runtime and source-bound cache.
import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/capability_source.dart';
import 'package:elecon/ui/home/grades_section.dart';
import 'package:elecon/ui/home/result_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage school({bool controls = false}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 4,
      'id': 'grade-term-synthetic',
      'schoolId': 'grade-term-synthetic',
      'version': '1.0.0',
      'name': 'Synthetic terms',
      'browser': false,
      'network': {'origins': []},
      'capabilities': [
        for (final capability in [
          'grades.list',
          'term.list',
          'gpa.summary',
          if (controls) 'query.controls',
        ])
          {
            'id': capability,
            'schema': 'elecon.$capability',
            'schemaVersion':
                ['term.list', 'query.controls'].contains(capability)
                ? '1.0'
                : '1.1',
          },
      ],
      'home': [
        for (final capability in ['grades.list', 'gpa.summary'])
          {'capability': capability, 'ttlSeconds': 3600, 'preload': false},
      ],
    },
    'source':
        '''
    export const capabilities = {
      ${controls ? "'query.controls': async () => ({target:'grades.list',title:'School filters',submitLabel:'Apply school term',controls:[{id:'term',kind:'select',parameter:'term',label:'School semester',initialValue:'term-now',options:[{value:'term-now',label:'School current semester'},{value:'term-before',label:'School previous semester'}]}]})," : ""}
      'term.list': async (_,params) => {
        if(params.includePast !== true) throw new Error('synthetic_history_not_requested');
        return {items:[
        {id:'term-now',name:'School current semester'},
        {id:'term-before',name:'School previous semester'}
      ]};},
      'grades.list': async (_,params) => ({term:params.term ?? 'term-now',items:[]}),
      'gpa.summary': async (_,params) => ({
        gpa:params.term === 'term-before' ? 2.5 : 3.5, gradePointScale:'4.0'
      })
    };
  ''',
  }),
);

Future<void> until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Synthetic grades query did not settle');
}

void main() {
  testWidgets(
    'school term labels select grades and GPA with the same source and cache parameters',
    (tester) async {
      final package = school();
      final session = (await tester.runAsync(() async {
        final session = SessionController();
        await session.bootstrap();
        await session.installTrustedScript(
          package,
          approvedDigest: package.digest,
        );
        await session.selectTrustedScriptSchool(package.manifest.schoolId);
        expect((await session.runCapability('grades.list')).ok, isTrue);
        return session;
      }))!;
      addTearDown(session.dispose);
      Widget app() => SessionScope(
        controller: session,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: CapabilitySourceScope(
                source: CapabilitySource(
                  packageId: package.manifest.id,
                  digest: package.digest,
                ),
                child: const GradesSection(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app());
      await until(tester, () => find.byType(GradesCard).evaluate().isNotEmpty);
      expect(find.text('No grades in this term'), findsOneWidget);
      await tester.tap(find.text('Filters'));
      await until(
        tester,
        () => find.text('School previous semester').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('School previous semester'));
      await until(
        tester,
        () =>
            find.textContaining('term-before · GPA 2.50').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<GradesCard>(find.byType(GradesCard)).data.term,
        'term-before',
      );
      final cached = await tester.runAsync(
        () => session.cachedCapability(
          'grades.list',
          params: {'term': 'term-before'},
          packageId: package.manifest.id,
          expectedDigest: package.digest,
        ),
      );
      expect(cached?.params, {'term': 'term-before'});
      final gpa = await tester.runAsync(
        () => session.cachedCapability(
          'gpa.summary',
          params: {'term': 'term-before'},
          packageId: package.manifest.id,
          expectedDigest: package.digest,
        ),
      );
      expect((gpa?.data as Map)['gpa'], 2.5);
      await tester.tap(find.byTooltip('Refresh'));
      var refreshed = false;
      for (var attempt = 0; attempt < 200 && !refreshed; attempt++) {
        await tester.pump(const Duration(milliseconds: 20));
        final next = await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return session.cachedCapability(
            'gpa.summary',
            params: {'term': 'term-before'},
            packageId: package.manifest.id,
            expectedDigest: package.digest,
          );
        });
        refreshed = next != null && next.fetchedAt.isAfter(gpa!.fetchedAt);
      }
      expect(refreshed, isTrue);
      await until(
        tester,
        () =>
            tester.widget<GradesCard>(find.byType(GradesCard)).summary?.gpa ==
            2.5,
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<GradesCard>(find.byType(GradesCard)).data.term,
        'term-before',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(app());
      await until(
        tester,
        () =>
            find.textContaining('term-before · GPA 2.50').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Filters'));
      await until(
        tester,
        () => find.text('School current semester').evaluate().isNotEmpty,
      );
      session.logout();
      await tester.pump();
      await tester.tap(find.text('School current semester'));
      await tester.pumpAndSettle();
      expect(find.byType(GradesCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'script controls drive grades, GPA and cache with the selected standard term',
    (tester) async {
      final p = school(controls: true);
      final session = (await tester.runAsync(() async {
        final s = SessionController();
        await s.bootstrap();
        await s.installTrustedScript(p, approvedDigest: p.digest);
        await s.selectTrustedScriptSchool(p.manifest.id);
        expect((await s.runCapability('grades.list')).ok, isTrue);
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
              body: SingleChildScrollView(child: GradesSection()),
            ),
          ),
        ),
      );
      await until(tester, () => find.byType(GradesCard).evaluate().isNotEmpty);
      await tester.tap(find.text('Filters'));
      await until(
        tester,
        () => find.text('School filters').evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('query-control-term')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('School previous semester').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<GradesCard>(find.byType(GradesCard)).data.term,
        'term-now',
      );
      await tester.tap(find.text('Apply school term'));
      await until(
        tester,
        () =>
            find.byType(GradesCard).evaluate().isNotEmpty &&
            tester.widget<GradesCard>(find.byType(GradesCard)).data.term ==
                'term-before' &&
            tester.widget<GradesCard>(find.byType(GradesCard)).summary?.gpa ==
                2.5,
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<GradesCard>(find.byType(GradesCard)).summary?.gpa,
        2.5,
      );
      final cached = await tester.runAsync(
        () => session.cachedCapability(
          'grades.list',
          params: {'term': 'term-before'},
        ),
      );
      expect(cached?.params, {'term': 'term-before'});
    },
  );
}
